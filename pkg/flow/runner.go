package flow

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/google/uuid"
	"github.com/sameehj/kai/pkg/agent"
	"github.com/sameehj/kai/pkg/backend/ebpf"
	"github.com/sameehj/kai/pkg/backend/hubble"
	"github.com/sameehj/kai/pkg/backend/system"
	"github.com/sameehj/kai/pkg/backend/tetragon"
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
	debug           bool
}

// NewRunner constructs a Runner backed by a registry.
func NewRunner(registry *tool.Registry, debug bool) *Runner {
	ag, err := agent.NewAgent("anthropic")
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
	run.Result.Summary = fmt.Sprintf("Flow completed successfully in %.2fs", endTime.Sub(run.StartedAt).Seconds())

	fmt.Printf("✅ Flow completed: %s (total: %.2fs)\n", flow.Metadata.Name, endTime.Sub(run.StartedAt).Seconds())

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
	var inputs []agent.StepOutput
	for _, input := range step.Input {
		if data, ok := previousOutputs[input.FromStep]; ok {
			inputs = append(inputs, agent.StepOutput{
				StepID: input.FromStep,
				Data:   data,
			})
		}
	}

	agentType := agent.AgentTypeAnalysis
	if step.AgentType != "" {
		agentType = agent.AgentType(step.AgentType)
	} else if step.With != nil {
		if t, ok := step.With["agentType"].(string); ok && t != "" {
			agentType = agent.AgentType(t)
		}
	}

	var prompt string
	if step.With != nil {
		if p, ok := step.With["prompt"].(string); ok {
			prompt = p
		}
	}

	resp, err := r.agent.Analyze(ctx, agent.AnalysisRequest{
		Type:   agentType,
		Inputs: inputs,
		Prompt: prompt,
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
