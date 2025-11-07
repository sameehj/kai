package types

import (
	"time"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
)

// LoadedPackage represents a package that has been brought into the runtime.
type LoadedPackage struct {
	Manifest *Package
	Programs map[string]*ebpf.Program
	Maps     map[string]*ebpf.Map
	Links    []link.Link
	ChainID  string
	LoadedAt time.Time
	Status   PackageStatus
}

type PackageStatus string

const (
	StatusLoaded   PackageStatus = "loaded"
	StatusAttached PackageStatus = "attached"
	StatusRunning  PackageStatus = "running"
	StatusStopped  PackageStatus = "stopped"
	StatusError    PackageStatus = "error"
)

// Chain represents a tail-call chain.
type Chain struct {
	ID         string
	Entry      *ebpf.Program
	ProgArray  *ebpf.Map
	Stages     []*ChainStage
	SharedMaps map[string]*ebpf.Map
}

// ChainStage tracks an individual stage within a chain.
type ChainStage struct {
	Index   uint32
	Program *ebpf.Program
	Next    *ChainStage
}
