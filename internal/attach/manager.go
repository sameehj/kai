package attach

import (
	"fmt"
	"net"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
)

// Manager handles attaching programs to kernel hooks.
type Manager struct{}

func NewManager() *Manager {
	return &Manager{}
}

type Options struct {
	Type      string
	AttachTo  string
	Interface string
	Cgroup    string
}

func (m *Manager) AttachProgram(prog *ebpf.Program, opts Options) (link.Link, error) {
	switch opts.Type {
	case "kprobe":
		return link.Kprobe(opts.AttachTo, prog, nil)
	case "kretprobe":
		return link.Kretprobe(opts.AttachTo, prog, nil)
	case "tracepoint":
		return link.Tracepoint(opts.AttachTo, prog, nil)
	case "raw_tracepoint":
		return link.AttachRawTracepoint(link.RawTracepointOptions{
			Name:    opts.AttachTo,
			Program: prog,
		})
	case "lsm":
		return link.AttachLSM(link.LSMOptions{Program: prog})
	case "xdp":
		return m.attachXDP(prog, opts.Interface)
	case "tc":
		return m.attachTC(prog, opts.Interface)
	case "cgroup":
		return m.attachCgroup(prog, opts.Cgroup)
	default:
		return nil, fmt.Errorf("unsupported attach type %q", opts.Type)
	}
}

func (m *Manager) attachXDP(prog *ebpf.Program, ifaceName string) (link.Link, error) {
	if ifaceName == "" {
		return nil, fmt.Errorf("interface required for XDP attach")
	}
	iface, err := net.InterfaceByName(ifaceName)
	if err != nil {
		return nil, fmt.Errorf("lookup interface %s: %w", ifaceName, err)
	}

	return link.AttachXDP(link.XDPOptions{
		Program:   prog,
		Interface: iface.Index,
	})
}

func (m *Manager) attachTC(prog *ebpf.Program, ifaceName string) (link.Link, error) {
	if ifaceName == "" {
		return nil, fmt.Errorf("interface required for TC attach")
	}
	iface, err := net.InterfaceByName(ifaceName)
	if err != nil {
		return nil, fmt.Errorf("lookup interface %s: %w", ifaceName, err)
	}

	return link.AttachTCX(link.TCXOptions{
		Program:   prog,
		Interface: iface.Index,
	})
}

func (m *Manager) attachCgroup(prog *ebpf.Program, path string) (link.Link, error) {
	if path == "" {
		return nil, fmt.Errorf("cgroup path required for cgroup attach")
	}
	return link.AttachCgroup(link.CgroupOptions{
		Path:    path,
		Attach:  ebpf.AttachCGroupInetEgress,
		Program: prog,
	})
}

func (m *Manager) Detach(link link.Link) error {
	return link.Close()
}
