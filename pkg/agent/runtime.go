package agent

import (
	"context"
	"errors"
	"os"
	"strconv"
	"time"

	"github.com/sameehj/kai/pkg/policy"
	"github.com/sameehj/kai/pkg/session"
	"github.com/sameehj/kai/pkg/skill"
	"github.com/sameehj/kai/pkg/tool"
	"github.com/sameehj/kai/pkg/workspace"
)

type Config struct {
	Workspace string
	LLM       LLMClient
}

type Runtime struct {
	tools     *tool.Registry
	skills    *skill.Registry
	sessions  *session.Store
	workspace string
	policy    *policy.Policy
	llm       LLMClient
}

func NewRuntime(cfg *Config) *Runtime {
	ws := cfg.Workspace
	if ws == "" {
		ws = workspace.Resolve()
	}
	return &Runtime{
		tools:     tool.NewRegistry(),
		skills:    skill.NewRegistry(ws),
		sessions:  session.NewStore(workspace.HomeDir()),
		workspace: ws,
		policy:    policy.Default(),
		llm:       cfg.LLM,
	}
}

func (r *Runtime) HandleMessage(ctx context.Context, sessionID session.SessionID, userMsg string) (string, error) {
	sess, err := r.sessions.Load(sessionID)
	if err != nil {
		return "", err
	}
	sess.Messages = append(sess.Messages, session.Message{Role: "user", Content: userMsg, Timestamp: time.Now()})

	resp, err := r.executeLoop(ctx, sess)
	if err != nil {
		return "", err
	}
	if err := r.sessions.Save(sess); err != nil {
		return "", err
	}
	return resp, nil
}

func (r *Runtime) executeLoop(ctx context.Context, sess *session.Session) (string, error) {
	if r.llm == nil {
		return "LLM not configured", nil
	}
	prompt, err := r.assemblePrompt(sess)
	if err != nil {
		return "", err
	}
	messages := convertSessionMessages(sess.Messages)
	tools := convertDefinitions(r.tools.Definitions())
	for {
		callCtx, cancel := context.WithTimeout(ctx, llmTimeout())
		resp, err := r.llm.Complete(callCtx, CompletionRequest{
			Prompt:    prompt,
			Messages:  messages,
			Tools:     tools,
			MaxTokens: 1024,
		})
		cancel()
		if err != nil {
			return "", err
		}
		if resp.StopReason == "end_turn" || len(resp.ToolCalls) == 0 {
			sess.Messages = append(sess.Messages, session.Message{Role: "assistant", Content: resp.Content, Timestamp: time.Now()})
			return resp.Content, nil
		}
		if len(resp.Blocks) > 0 {
			messages = append(messages, CompletionMessage{Role: "assistant", Content: resp.Blocks})
		}
		var results []ContentBlock
		for _, call := range resp.ToolCalls {
			result, err := r.executeTool(ctx, sess, call)
			// Anthropic requires a non-empty text field for text blocks.
			if result == "" {
				result = "(no output)"
			}
			block := ContentBlock{
				Type:      "tool_result",
				ToolUseID: call.ID,
				Content:   []ContentBlock{{Type: "text", Text: result}},
			}
			if err != nil {
				block.IsError = true
				errText := err.Error()
				if errText == "" {
					errText = "(error with no message)"
				}
				block.Content = []ContentBlock{{Type: "text", Text: errText}}
			}
			results = append(results, block)
			sess.Messages = append(sess.Messages, session.Message{
				Role:      "tool",
				Content:   result,
				Timestamp: time.Now(),
				ToolCalls: []session.ToolCall{{Name: call.Name, Input: call.Input, Result: result}},
			})
		}
		if len(results) > 0 {
			messages = append(messages, CompletionMessage{Role: "user", Content: results})
		}
	}
}

func (r *Runtime) assemblePrompt(sess *session.Session) (string, error) {
	var msgs []string
	for _, m := range sess.Messages {
		if m.Content != "" {
			msgs = append(msgs, m.Content)
		}
	}
	relevant := r.skills.SelectRelevant(msgs)
	pc, err := workspace.LoadPromptComponents(r.workspace, relevant)
	if err != nil {
		return "", err
	}
	pc.Defs = r.tools.Schema()
	return pc.Compose(), nil
}

func (r *Runtime) executeTool(ctx context.Context, sess *session.Session, call ToolCall) (string, error) {
	if !r.policy.IsAllowed(string(sess.Type), call.Name) {
		return "", errors.New("tool not allowed")
	}
	t := r.tools.Get(call.Name)
	if t == nil {
		return "", errors.New("unknown tool")
	}
	return t.Execute(ctx, call.Input)
}

func convertSessionMessages(msgs []session.Message) []CompletionMessage {
	out := make([]CompletionMessage, 0, len(msgs))
	for _, m := range msgs {
		role := m.Role
		if role != "user" && role != "assistant" {
			role = "user"
		}
		out = append(out, CompletionMessage{Role: role, Content: []ContentBlock{{Type: "text", Text: m.Content}}})
	}
	return out
}

func convertDefinitions(defs []tool.Definition) []ToolDefinition {
	out := make([]ToolDefinition, 0, len(defs))
	for _, d := range defs {
		out = append(out, ToolDefinition{
			Name:        d.Name,
			Description: d.Description,
			InputSchema: d.InputSchema,
		})
	}
	return out
}

func llmTimeout() time.Duration {
	if v := os.Getenv("KAI_LLM_TIMEOUT_SECONDS"); v != "" {
		if sec, err := strconv.Atoi(v); err == nil && sec > 0 {
			return time.Duration(sec) * time.Second
		}
	}
	return 90 * time.Second
}
