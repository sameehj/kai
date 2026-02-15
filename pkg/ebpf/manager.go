package ebpf

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"
)

var ErrNotSupported = errors.New("ebpf is not supported on this platform")

type Program struct {
	Name       string
	ObjectPath string
	LoadedAt   time.Time

	cancel  context.CancelFunc
	closeFn func() error
}

type Manager struct {
	mu        sync.RWMutex
	programs  map[string]*Program
	supported bool
}

func NewManager() (*Manager, error) {
	supported, err := platformInit()
	if err != nil {
		return nil, err
	}
	return &Manager{
		programs:  make(map[string]*Program),
		supported: supported,
	}, nil
}

func (m *Manager) Supported() bool {
	if m == nil {
		return false
	}
	return m.supported
}

func (m *Manager) CheckRequirements() error {
	if !m.supported {
		return ErrNotSupported
	}
	return platformCheckRequirements()
}

func (m *Manager) Load(name, objPath string) (*Program, error) {
	if !m.supported {
		return nil, ErrNotSupported
	}
	if name == "" {
		return nil, fmt.Errorf("name is required")
	}
	if objPath == "" {
		return nil, fmt.Errorf("objPath is required")
	}

	m.mu.Lock()
	if prog, exists := m.programs[name]; exists {
		m.mu.Unlock()
		return prog, nil
	}
	m.mu.Unlock()

	loaded, err := platformLoadProgram(objPath)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	_ = ctx

	prog := &Program{
		Name:       name,
		ObjectPath: objPath,
		LoadedAt:   time.Now(),
		cancel:     cancel,
		closeFn:    loaded.close,
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if existing, exists := m.programs[name]; exists {
		cancel()
		if prog.closeFn != nil {
			_ = prog.closeFn()
		}
		return existing, nil
	}
	m.programs[name] = prog
	return prog, nil
}

func (m *Manager) Unload(name string) error {
	m.mu.Lock()
	prog, exists := m.programs[name]
	if !exists {
		m.mu.Unlock()
		return fmt.Errorf("program %s not loaded", name)
	}
	delete(m.programs, name)
	m.mu.Unlock()

	if prog.cancel != nil {
		prog.cancel()
	}
	if prog.closeFn != nil {
		if err := prog.closeFn(); err != nil {
			return err
		}
	}
	return nil
}

func (m *Manager) List() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	names := make([]string, 0, len(m.programs))
	for name := range m.programs {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func (m *Manager) Get(name string) (*Program, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	prog, exists := m.programs[name]
	return prog, exists
}

func (m *Manager) Shutdown() error {
	names := m.List()
	var firstErr error
	for _, name := range names {
		if err := m.Unload(name); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

type loadedProgram struct {
	close func() error
}
