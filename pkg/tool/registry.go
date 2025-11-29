package tool

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/sameehj/kai/pkg/types"
	"gopkg.in/yaml.v3"
)

// Registry holds loaded sensors, actions, and flows.
type Registry struct {
	sensors map[string]*types.Sensor
	actions map[string]*types.Action
	flows   map[string]*types.Flow
}

// NewRegistry constructs an empty registry.
func NewRegistry() *Registry {
	return &Registry{
		sensors: make(map[string]*types.Sensor),
		actions: make(map[string]*types.Action),
		flows:   make(map[string]*types.Flow),
	}
}

// LoadFromPath loads all recipes under the provided folder.
func (r *Registry) LoadFromPath(recipesPath string) error {
	sensorsPath := filepath.Join(recipesPath, "sensors")
	if err := r.loadSensors(sensorsPath); err != nil {
		return fmt.Errorf("load sensors: %w", err)
	}

	actionsPath := filepath.Join(recipesPath, "actions")
	if err := r.loadActions(actionsPath); err != nil {
		return fmt.Errorf("load actions: %w", err)
	}

	flowsPath := filepath.Join(recipesPath, "flows")
	if err := r.loadFlows(flowsPath); err != nil {
		return fmt.Errorf("load flows: %w", err)
	}

	return nil
}

func (r *Registry) loadSensors(path string) error {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil
	}
	return filepath.Walk(path, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || !strings.HasSuffix(p, "sensor.yaml") {
			return nil
		}

		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}

		var sensor types.Sensor
		if err := yaml.Unmarshal(data, &sensor); err != nil {
			return fmt.Errorf("parse %s: %w", p, err)
		}

		r.sensors[sensor.Metadata.ID] = &sensor
		return nil
	})
}

func (r *Registry) loadActions(path string) error {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil
	}
	return filepath.Walk(path, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || !strings.HasSuffix(p, "action.yaml") {
			return nil
		}

		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}

		var action types.Action
		if err := yaml.Unmarshal(data, &action); err != nil {
			return fmt.Errorf("parse %s: %w", p, err)
		}

		r.actions[action.Metadata.ID] = &action
		return nil
	})
}

func (r *Registry) loadFlows(path string) error {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil
	}
	return filepath.Walk(path, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || !strings.HasSuffix(p, "flow.yaml") {
			return nil
		}

		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}

		var flow types.Flow
		if err := yaml.Unmarshal(data, &flow); err != nil {
			return fmt.Errorf("parse %s: %w", p, err)
		}

		r.flows[flow.Metadata.ID] = &flow
		return nil
	})
}

// GetSensor returns a sensor by id.
func (r *Registry) GetSensor(id string) (*types.Sensor, bool) {
	s, ok := r.sensors[id]
	return s, ok
}

// GetAction returns an action by id.
func (r *Registry) GetAction(id string) (*types.Action, bool) {
	a, ok := r.actions[id]
	return a, ok
}

// GetFlow returns a flow by id.
func (r *Registry) GetFlow(id string) (*types.Flow, bool) {
	f, ok := r.flows[id]
	return f, ok
}

// ListFlows returns all flows.
func (r *Registry) ListFlows() []*types.Flow {
	flows := make([]*types.Flow, 0, len(r.flows))
	for _, f := range r.flows {
		flows = append(flows, f)
	}
	return flows
}
