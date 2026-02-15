//go:build linux

package ebpf

import (
	"fmt"
	"os"

	cebpf "github.com/cilium/ebpf"
	"github.com/cilium/ebpf/btf"
	"github.com/cilium/ebpf/rlimit"
)

func platformInit() (bool, error) {
	if err := rlimit.RemoveMemlock(); err != nil {
		return true, fmt.Errorf("removing memlock limit: %w", err)
	}
	return true, nil
}

func platformCheckRequirements() error {
	if _, err := btf.LoadKernelSpec(); err != nil {
		return fmt.Errorf("BTF not available: %w", err)
	}
	if _, err := os.Stat("/sys/fs/bpf"); err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("BPF filesystem not mounted at /sys/fs/bpf")
		}
		return fmt.Errorf("checking /sys/fs/bpf: %w", err)
	}
	return nil
}

func platformLoadProgram(objPath string) (*loadedProgram, error) {
	spec, err := cebpf.LoadCollectionSpec(objPath)
	if err != nil {
		return nil, fmt.Errorf("loading collection spec: %w", err)
	}
	coll, err := cebpf.NewCollection(spec)
	if err != nil {
		return nil, fmt.Errorf("creating collection: %w", err)
	}
	return &loadedProgram{close: coll.Close}, nil
}
