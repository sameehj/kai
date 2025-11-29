package flow

import "github.com/sameehj/kai/pkg/types"

// StateStore persists flow run state snapshots.
type StateStore interface {
	Save(types.FlowRun) error
	Load(id string) (types.FlowRun, error)
}

// MemoryStateStore is a no-op placeholder store.
type MemoryStateStore struct{}

func (MemoryStateStore) Save(run types.FlowRun) error {
	return nil
}

func (MemoryStateStore) Load(id string) (types.FlowRun, error) {
	return types.FlowRun{}, nil
}
