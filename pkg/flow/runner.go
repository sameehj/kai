package flow

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/google/uuid"
	"github.com/sameehj/kai/pkg/agent"
	"github.com/sameehj/kai/pkg/backend/ebpf"
	"github.com/sameehj/kai/pkg/backend/hubble"
	"github.com/sameehj/kai/pkg/backend/system"
	"github.com/sameehj/kai/pkg/backend/tetragon"
	"github.com/sameehj/kai/pkg/config"
	"github.com/sameehj/kai/pkg/tool"
	"github.com/sameehj/kai/pkg/types"
)

// Runner executes flows sequentially (MVP implementation).
type Runner struct {
	registry        *tool.Registry
	systemBackend   *system.Backend
	hubbleBackend   *hubble.Backend
	tetragonBackend *tetragon.Backend
	ebpfBackend     *ebpf.Backend
	agent           agent.Agent
	cfg             *config.Config
	debug           bool
}

// NewRunner constructs a Runner backed by a registry.
func NewRunner(registry *tool.Registry, cfg *config.Config, debug bool) *Runner {
	if cfg == nil {
		cfg = &config.Config{}
	}

	agent.SetModelOverrides(agent.ModelOverrides{
		Claude: cfg.Agent.ClaudeModel,
		OpenAI: cfg.Agent.OpenAIModel,
		Gemini: cfg.Agent.GeminiModel,
		Ollama: cfg.Agent.OllamaModel,
	})

	ag, err := selectDefaultAgent(cfg)
	if err != nil {
		fmt.Printf("⚠️  Agent unavailable (%v), using mock\n", err)
		ag = agent.NewMockAgent()
	}

	r := &Runner{
		registry:        registry,
		systemBackend:   system.New(),
		tetragonBackend: tetragon.NewBackend(),
		ebpfBackend:     ebpf.NewBackend(),
		agent:           ag,
		cfg:             cfg,
		debug:           debug,
	}

	return r
}

// Run executes the specified flow with mock step handlers.
func (r *Runner) Run(ctx context.Context, flowID string, params map[string]interface{}) (*types.FlowRun, error) {
	flow, ok := r.registry.GetFlow(flowID)
	if !ok {
		return nil, fmt.Errorf("flow not found: %s", flowID)
	}

	run := &types.FlowRun{
		ID:        uuid.New().String(),
		FlowID:    flowID,
		State:     types.FlowStateRunning,
		StartedAt: time.Now(),
		Steps:     make([]types.StepStatus, len(flow.Spec.Steps)),
		Result: types.FlowResult{
			Data: make(map[string]interface{}),
		},
	}

	fmt.Printf("🚀 Starting flow run: %s (id: %s)\n", flow.Metadata.Name, run.ID)

	for i, step := range flow.Spec.Steps {
		stepStart := time.Now()
		run.Steps[i] = types.StepStatus{
			ID:        step.ID,
			State:     types.StepStateRunning,
			StartedAt: &stepStart,
		}

		fmt.Printf("  ⏳ Executing step %d/%d: %s (type: %s)\n", i+1, len(flow.Spec.Steps), step.ID, step.Type)

		output, err := r.executeStep(ctx, &step, run.Result.Data)
		stepEnd := time.Now()
		run.Steps[i].EndedAt = &stepEnd

		if err != nil {
			run.Steps[i].State = types.StepStateFailed
			run.Steps[i].Error = err.Error()
			run.State = types.FlowStateFailed
			run.Error = fmt.Sprintf("step %s failed: %v", step.ID, err)
			return run, err
		}

		run.Steps[i].State = types.StepStateCompleted
		run.Steps[i].Output = output

		run.Result.Data[step.ID] = output
		if step.Output.SaveAs != "" {
			run.Result.Data[step.Output.SaveAs] = output
		}

		fmt.Printf("  ✅ Step completed: %s (%.2fs)\n", step.ID, stepEnd.Sub(stepStart).Seconds())
	}

	endTime := time.Now()
	run.EndedAt = &endTime
	run.State = types.FlowStateCompleted
	totalDuration := endTime.Sub(run.StartedAt)
	run.Result.Summary = fmt.Sprintf("Flow completed successfully in %.2fs", totalDuration.Seconds())

	fmt.Printf("✅ Flow completed: %s (total: %.2fs)\n", flow.Metadata.Name, totalDuration.Seconds())
	r.printConclusion(run, totalDuration)

	return run, nil
}

func (r *Runner) executeStep(ctx context.Context, step *types.FlowStep, previousOutputs map[string]interface{}) (interface{}, error) {
	switch step.Type {
	case "sensor":
		return r.executeSensor(ctx, step)
	case "agent":
		return r.executeAgent(ctx, step, previousOutputs)
	case "action":
		return r.executeAction(ctx, step)
	default:
		return nil, fmt.Errorf("unknown step type: %s", step.Type)
	}
}

func (r *Runner) executeSensor(ctx context.Context, step *types.FlowStep) (interface{}, error) {
	sensor, ok := r.registry.GetSensor(step.Ref)
	if !ok {
		return nil, fmt.Errorf("sensor not found: %s", step.Ref)
	}

	// Extract params from step.With
	params := step.With
	if params == nil {
		params = make(map[string]interface{})
	}

	r.logDebug("sensor %s backend=%s params=%v", step.Ref, sensor.Spec.Backend, params)

	// Route to appropriate backend
	switch sensor.Spec.Backend {
	case "system":
		return r.systemBackend.RunSensor(ctx, sensor, params)
	case "hubble":
		hb, err := r.getHubbleBackend()
		if err != nil {
			return nil, fmt.Errorf("hubble backend unavailable: %w", err)
		}
		return hb.RunSensor(ctx, sensor, params)
	case "tetragon":
		if r.tetragonBackend == nil {
			return nil, fmt.Errorf("tetragon backend not configured")
		}
		return r.tetragonBackend.RunSensor(ctx, sensor, params)
	case "ebpf":
		if r.ebpfBackend == nil {
			return nil, fmt.Errorf("ebpf backend not configured")
		}
		return r.ebpfBackend.RunSensor(ctx, sensor, params)
	case "kernel":
		// TODO: Add kernel backend
		return nil, fmt.Errorf("kernel backend not implemented yet")
	default:
		return nil, fmt.Errorf("unknown backend: %s", sensor.Spec.Backend)
	}
}

func (r *Runner) executeAgent(ctx context.Context, step *types.FlowStep, previousOutputs map[string]interface{}) (interface{}, error) {
	contextInputs := r.collectContext(step, previousOutputs)

	var prompt string
	if step.With != nil {
		if p, ok := step.With["prompt"].(string); ok {
			prompt = p
		}
	}

	analysisType, backendOverride := r.resolveAgentStepSettings(step)

	agentInstance := r.agent
	cleanup := func() {}
	if backendOverride != "" {
		override, err := agent.NewAgentByType(agent.AgentType(backendOverride))
		if err != nil {
			return nil, fmt.Errorf("create agent backend %s: %w", backendOverride, err)
		}
		agentInstance = override
		cleanup = func() {
			_ = override.Close()
		}
	}
	defer cleanup()

	resp, err := agentInstance.Analyze(ctx, agent.AnalysisRequest{
		Type:    analysisType,
		Context: contextInputs,
		Prompt:  prompt,
	})
	if err != nil {
		return nil, fmt.Errorf("agent analysis failed: %w", err)
	}

	return resp, nil
}

func (r *Runner) executeAction(ctx context.Context, step *types.FlowStep) (interface{}, error) {
	action, ok := r.registry.GetAction(step.Ref)
	if !ok {
		return nil, fmt.Errorf("action not found: %s", step.Ref)
	}

	fmt.Printf("    [ACTION] Would execute: %s\n", action.Metadata.Name)
	fmt.Printf("    [ACTION] Backend: %s, Operation: %s\n", action.Spec.Backend, action.Spec.Operation)
	fmt.Printf("    [ACTION] Params: %+v\n", step.With)

	return map[string]interface{}{
		"action_id": action.Metadata.ID,
		"status":    "simulated",
		"mock":      true,
	}, nil
}

func (r *Runner) logDebug(format string, args ...interface{}) {
	if !r.debug {
		return
	}
	fmt.Printf("    [debug] "+format+"\n", args...)
}

func (r *Runner) getHubbleBackend() (*hubble.Backend, error) {
	if r.hubbleBackend != nil {
		return r.hubbleBackend, nil
	}

	hb, err := hubble.NewBackend(os.Getenv("KAI_HUBBLE_ADDR"))
	if err != nil {
		return nil, err
	}

	r.hubbleBackend = hb
	return hb, nil
}

func (r *Runner) printConclusion(run *types.FlowRun, totalDuration time.Duration) {
	fmt.Println()
	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	fmt.Println("       INVESTIGATION COMPLETE")
	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	fmt.Println()

	if diag := r.extractDiagnosis(run.Result.Data["network_diagnosis"]); diag != nil {
		fmt.Printf("Root Cause: %s\n", diag.RootCause)
		fmt.Printf("Confidence: %.0f%%\n", diag.Confidence*100)
		if diag.RecommendedAction != "" {
			fmt.Printf("Recommendation: %s\n", diag.RecommendedAction)
		}
		fmt.Println()
	}

	fmt.Printf("⏱️  Total time: %.2fs\n", totalDuration.Seconds())
	fmt.Println()
	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
}

func (r *Runner) extractDiagnosis(raw interface{}) *agent.AnalysisResponse {
	switch v := raw.(type) {
	case *agent.AnalysisResponse:
		return v
	case agent.AnalysisResponse:
		return &v
	case map[string]interface{}:
		resp := &agent.AnalysisResponse{}
		if root, ok := v["root_cause"].(string); ok {
			resp.RootCause = root
		}
		if comp, ok := v["affected_component"].(string); ok {
			resp.AffectedComponent = comp
		}
		if action, ok := v["recommended_action"].(string); ok {
			resp.RecommendedAction = action
		}
		if conf, ok := v["confidence"].(float64); ok {
			resp.Confidence = conf
		}
		if resp.RootCause == "" && resp.RecommendedAction == "" {
			return nil
		}
		return resp
	default:
		return nil
	}
}

func (r *Runner) collectContext(step *types.FlowStep, previousOutputs map[string]interface{}) []agent.StepOutput {
	var inputs []agent.StepOutput
	for _, input := range step.Input {
		if data, ok := previousOutputs[input.FromStep]; ok {
			inputs = append(inputs, agent.StepOutput{
				StepID: input.FromStep,
				Data:   normalizeStepData(data),
			})
		}
	}
	return inputs
}

func normalizeStepData(data interface{}) map[string]interface{} {
	if data == nil {
		return map[string]interface{}{}
	}

	if m, ok := data.(map[string]interface{}); ok {
		return m
	}

	var asMap map[string]interface{}
	if bytes, err := json.Marshal(data); err == nil {
		if err := json.Unmarshal(bytes, &asMap); err == nil {
			return asMap
		}
	}

	return map[string]interface{}{
		"value": data,
	}
}

func (r *Runner) resolveAgentStepSettings(step *types.FlowStep) (string, string) {
	analysisType := "analysis"
	backend := ""

	assignValue := func(value string) {
		if value == "" {
			return
		}
		if isBackendType(value) {
			backend = value
		} else {
			analysisType = value
		}
	}

	assignValue(step.AgentType)

	if step.With != nil {
		if v, ok := step.With["agentType"].(string); ok {
			assignValue(v)
		}
		if v, ok := step.With["analysisType"].(string); ok {
			analysisType = v
		}
		if v, ok := step.With["backend"].(string); ok {
			backend = v
		}
	}

	return analysisType, backend
}

func isBackendType(value string) bool {
	switch agent.AgentType(value) {
	case agent.AgentTypeClaude, agent.AgentTypeOpenAI, agent.AgentTypeGemini, agent.AgentTypeLlama, agent.AgentTypeMock:
		return true
	default:
		return false
	}
}

func selectDefaultAgent(cfg *config.Config) (agent.Agent, error) {
	if cfg != nil {
		if cfg.Agent.Type != "" {
			ag, err := agent.NewAgentByType(agent.AgentType(cfg.Agent.Type))
			if err == nil {
				return ag, nil
			}
			fmt.Printf("⚠️  Failed to initialize %s agent (%v), falling back to auto-detect\n", cfg.Agent.Type, err)
			if !cfg.Agent.Auto {
				return nil, err
			}
		}
		if !cfg.Agent.Auto {
			return nil, fmt.Errorf("agent auto-detect disabled and type not configured")
		}
	}

	return agent.NewAgent()
}
