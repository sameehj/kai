package chain

import (
	"fmt"
	"time"

	"github.com/cilium/ebpf"
	"github.com/sameehj/kai/pkg/types"
)

// Manager wires tail-call chains between programs.
type Manager struct {
	chains map[string]*types.Chain
}

func NewManager() *Manager {
	return &Manager{
		chains: make(map[string]*types.Chain),
	}
}

// WireChain prepares a program array and records the chain metadata.
func (m *Manager) WireChain(pkg *types.LoadedPackage, chainDef types.ChainDef) (*types.Chain, error) {
	if chainDef.Entry == "" {
		return nil, fmt.Errorf("chain entry program not defined")
	}

	progArray, err := ebpf.NewMap(&ebpf.MapSpec{
		Type:       ebpf.ProgramArray,
		KeySize:    4,
		ValueSize:  4,
		MaxEntries: uint32(len(chainDef.Stages) + 1),
		Name:       chainDef.ProgArray,
	})
	if err != nil {
		return nil, fmt.Errorf("create program array: %w", err)
	}

	entry, ok := pkg.Programs[chainDef.Entry]
	if !ok {
		progArray.Close()
		return nil, fmt.Errorf("entry program %s not present", chainDef.Entry)
	}

	chain := &types.Chain{
		ID:         generateChainID(pkg.Manifest.Metadata.Name),
		Entry:      entry,
		ProgArray:  progArray,
		Stages:     make([]*types.ChainStage, 0, len(chainDef.Stages)),
		SharedMaps: pkg.Maps,
	}

	for _, stageDef := range chainDef.Stages {
		stageProg, ok := pkg.Programs[stageDef.ID]
		if !ok {
			m.cleanupChain(chain)
			return nil, fmt.Errorf("stage %s not present", stageDef.ID)
		}

		if err := progArray.Put(stageDef.Index, uint32(stageProg.FD())); err != nil {
			m.cleanupChain(chain)
			return nil, fmt.Errorf("wire stage %d: %w", stageDef.Index, err)
		}

		stage := &types.ChainStage{
			Index:   stageDef.Index,
			Program: stageProg,
		}
		chain.Stages = append(chain.Stages, stage)
	}

	m.chains[chain.ID] = chain
	pkg.ChainID = chain.ID
	return chain, nil
}

// HotSwapStage replaces a stage entry with a new program.
func (m *Manager) HotSwapStage(chainID string, index uint32, program *ebpf.Program) error {
	chain, ok := m.chains[chainID]
	if !ok {
		return fmt.Errorf("chain %s not found", chainID)
	}

	if err := chain.ProgArray.Put(index, uint32(program.FD())); err != nil {
		return fmt.Errorf("update program array: %w", err)
	}

	for _, stage := range chain.Stages {
		if stage.Index == index {
			stage.Program = program
			break
		}
	}
	return nil
}

func (m *Manager) GetChain(id string) (*types.Chain, error) {
	chain, ok := m.chains[id]
	if !ok {
		return nil, fmt.Errorf("chain %s not found", id)
	}
	return chain, nil
}

func (m *Manager) DeleteChain(id string) {
	if chain, ok := m.chains[id]; ok {
		m.cleanupChain(chain)
		delete(m.chains, id)
	}
}

func (m *Manager) cleanupChain(chain *types.Chain) {
	if chain.ProgArray != nil {
		chain.ProgArray.Close()
	}
}

func generateChainID(packageName string) string {
	return fmt.Sprintf("chain-%s-%d", packageName, time.Now().UnixNano())
}
