package system

import (
	"context"
	"fmt"
	"time"

	"github.com/sameehj/kai/pkg/types"
)

// Backend implements the system CLI backend.
type Backend struct {
	executor *Executor
}

// New creates a system backend.
func New() *Backend {
	return &Backend{
		executor: NewExecutor(),
	}
}

// RunSensor executes a CLI-based sensor.
func (b *Backend) RunSensor(ctx context.Context, sensor *types.Sensor, params map[string]interface{}) (interface{}, error) {
	if sensor.Spec.Backend != "system" {
		return nil, fmt.Errorf("sensor backend mismatch: expected system, got %s", sensor.Spec.Backend)
	}

	if sensor.Spec.Type != "cli" {
		return nil, fmt.Errorf("unsupported sensor type: %s", sensor.Spec.Type)
	}

	// Merge params with defaults.
	finalParams := make(map[string]interface{})
	if sensor.Spec.Params != nil {
		for key, schema := range sensor.Spec.Params {
			if val, ok := params[key]; ok {
				finalParams[key] = val
			} else if schema.Default != nil {
				finalParams[key] = schema.Default
			}
		}
	}
	for key, val := range params {
		if _, exists := finalParams[key]; !exists {
			finalParams[key] = val
		}
	}

	// Template command.
	cmd := TemplateCommand(sensor.Spec.Command, finalParams)

	// Execute.
	timeout := time.Duration(sensor.Spec.TimeoutSeconds) * time.Second
	resp, err := b.executor.Execute(ctx, ExecuteRequest{
		Command: cmd,
		Timeout: timeout,
	})

	if err != nil {
		return nil, fmt.Errorf("execute sensor: %w", err)
	}

	// Return structured output.
	return map[string]interface{}{
		"sensor_id":   sensor.Metadata.ID,
		"sensor_name": sensor.Metadata.Name,
		"backend":     sensor.Spec.Backend,
		"timestamp":   time.Now().Unix(),
		"command":     cmd,
		"exit_code":   resp.ExitCode,
		"duration_ms": resp.Duration.Milliseconds(),
		"stdout":      resp.Stdout,
		"stderr":      resp.Stderr,
		"success":     resp.ExitCode == 0,
	}, nil
}

// RunAction executes a CLI-based action (not implemented yet).
func (b *Backend) RunAction(ctx context.Context, action *types.Action, params map[string]interface{}) (interface{}, error) {
	return nil, fmt.Errorf("system backend actions not implemented yet")
}
