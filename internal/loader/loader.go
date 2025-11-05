package loader

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/cilium/ebpf"
	"github.com/yourusername/kai/pkg/types"
	"gopkg.in/yaml.v3"
)

// PolicyValidator describes the minimal contract the loader needs from the policy engine.
type PolicyValidator interface {
	ValidatePackage(*types.Package) error
}

// Loader encapsulates manifest parsing and eBPF resource creation.
type Loader struct {
	kcp    *KernelProfile
	policy PolicyValidator
}

// NewLoader creates a Loader with kernel capability detection performed up-front.
func NewLoader(policy PolicyValidator) (*Loader, error) {
	kcp, err := DetectKernelProfile()
	if err != nil {
		return nil, fmt.Errorf("detect kernel profile: %w", err)
	}

	return &Loader{
		kcp:    kcp,
		policy: policy,
	}, nil
}

// LoadPackage reads a manifest and materialises its programs and maps.
func (l *Loader) LoadPackage(packagePath string) (*types.LoadedPackage, error) {
	manifestPath := filepath.Join(packagePath, "manifest.yaml")
	manifest, err := l.parseManifest(manifestPath)
	if err != nil {
		return nil, fmt.Errorf("parse manifest: %w", err)
	}

	if err := l.kcp.Verify(manifest.Requirements); err != nil {
		return nil, fmt.Errorf("kernel compatibility: %w", err)
	}

	if l.policy != nil {
		if err := l.policy.ValidatePackage(manifest); err != nil {
			return nil, fmt.Errorf("policy validation: %w", err)
		}
	}

	loaded := &types.LoadedPackage{
		Manifest: manifest,
		Programs: make(map[string]*ebpf.Program),
		Maps:     make(map[string]*ebpf.Map),
		Status:   types.StatusLoaded,
	}

	for _, progDef := range manifest.Interface.Programs {
		prog, err := l.loadProgram(packagePath, progDef)
		if err != nil {
			l.cleanup(loaded)
			return nil, fmt.Errorf("load program %s: %w", progDef.ID, err)
		}
		loaded.Programs[progDef.ID] = prog
	}

	for _, mapDef := range manifest.Interface.Maps {
		m, err := l.loadMap(mapDef)
		if err != nil {
			l.cleanup(loaded)
			return nil, fmt.Errorf("initialise map %s: %w", mapDef.Name, err)
		}
		loaded.Maps[mapDef.Name] = m
	}

	loaded.LoadedAt = time.Now()
	return loaded, nil
}

func (l *Loader) parseManifest(path string) (*types.Package, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var pkg types.Package
	if err := yaml.Unmarshal(raw, &pkg); err != nil {
		return nil, err
	}

	return &pkg, nil
}

func (l *Loader) loadProgram(basePath string, def types.ProgramDef) (*ebpf.Program, error) {
	fullPath := filepath.Join(basePath, def.File)

	spec, err := ebpf.LoadCollectionSpec(fullPath)
	if err != nil {
		return nil, fmt.Errorf("load collection spec: %w", err)
	}

	var progSpec *ebpf.ProgramSpec
	if candidate, ok := spec.Programs[def.Section]; ok {
		progSpec = candidate
	} else {
		for name, candidate := range spec.Programs {
			if name == def.Section || candidate.Section == def.Section {
				progSpec = candidate
				break
			}
		}
	}

	if progSpec == nil {
		return nil, fmt.Errorf("section %s not found in %s", def.Section, fullPath)
	}

	prog, err := ebpf.NewProgram(progSpec)
	if err != nil {
		return nil, fmt.Errorf("create program: %w", err)
	}

	return prog, nil
}

func (l *Loader) loadMap(def types.MapDef) (*ebpf.Map, error) {
	if def.Pin != "" {
		if m, err := ebpf.LoadPinnedMap(def.Pin, nil); err == nil {
			return m, nil
		}
	}

	spec := &ebpf.MapSpec{
		Name:       sanitizeMapName(def.Name),
		Type:       parseMapType(def.Type),
		KeySize:    getKeySize(def.Schema),
		ValueSize:  getValueSize(def.Schema),
		MaxEntries: def.MaxEntries,
	}

	// Ring buffers ignore key/value sizing.
	if spec.Type == ebpf.RingBuf {
		spec.KeySize = 0
		spec.ValueSize = 0
	}

	m, err := ebpf.NewMap(spec)
	if err != nil {
		return nil, fmt.Errorf("create map: %w", err)
	}

	if def.Pin != "" {
		if err := os.MkdirAll(filepath.Dir(def.Pin), 0o755); err != nil {
			m.Close()
			return nil, fmt.Errorf("prepare pin directory: %w", err)
		}
		if err := m.Pin(def.Pin); err != nil {
			m.Close()
			return nil, fmt.Errorf("pin map: %w", err)
		}
	}

	// Defaults are currently best-effort; we only handle scalar keys and byte slice values.
	if len(def.Defaults) > 0 && spec.Type != ebpf.RingBuf {
		for keyStr, value := range def.Defaults {
			key, err := parseMapKey(keyStr, def.Schema.KeyType)
			if err != nil {
				m.Close()
				return nil, fmt.Errorf("parse default key %q: %w", keyStr, err)
			}

			valBytes, err := encodeMapValue(value)
			if err != nil {
				m.Close()
				return nil, fmt.Errorf("encode default value for %q: %w", keyStr, err)
			}

			if err := m.Put(key, valBytes); err != nil {
				m.Close()
				return nil, fmt.Errorf("set default value for %q: %w", keyStr, err)
			}
		}
	}

	return m, nil
}

func (l *Loader) cleanup(pkg *types.LoadedPackage) {
	for _, prog := range pkg.Programs {
		prog.Close()
	}
	for _, m := range pkg.Maps {
		m.Close()
	}
}

func sanitizeMapName(name string) string {
	if len(name) <= 15 {
		return name
	}
	return name[:15]
}

func parseMapType(kind string) ebpf.MapType {
	switch kind {
	case "ringbuf":
		return ebpf.RingBuf
	case "hash":
		return ebpf.Hash
	case "array":
		return ebpf.Array
	case "percpu_array":
		return ebpf.PerCPUArray
	case "perf_event_array":
		return ebpf.PerfEventArray
	case "prog_array":
		return ebpf.ProgramArray
	default:
		return ebpf.Hash
	}
}

func getKeySize(schema types.SchemaDef) uint32 {
	if schema.KeyType != "" {
		return getSizeForType(schema.KeyType)
	}
	return 4
}

func getValueSize(schema types.SchemaDef) uint32 {
	if schema.ValueType != "" {
		return getSizeForType(schema.ValueType)
	}
	if len(schema.Fields) == 0 {
		return 4
	}

	var size uint32
	for _, field := range schema.Fields {
		size += getSizeForType(field.Type)
	}
	return size
}

func getSizeForType(t string) uint32 {
	switch {
	case t == "u8":
		return 1
	case t == "u16":
		return 2
	case t == "u32":
		return 4
	case t == "u64":
		return 8
	case strings.HasPrefix(t, "char["):
		var length int
		if _, err := fmt.Sscanf(t, "char[%d]", &length); err == nil && length > 0 {
			return uint32(length)
		}
		return 1
	default:
		return 4
	}
}

func parseMapKey(keyStr, keyType string) (interface{}, error) {
	switch keyType {
	case "u32":
		var v uint32
		if _, err := fmt.Sscanf(keyStr, "%d", &v); err != nil {
			return nil, err
		}
		return v, nil
	case "u64":
		var v uint64
		if _, err := fmt.Sscanf(keyStr, "%d", &v); err != nil {
			return nil, err
		}
		return v, nil
	default:
		return keyStr, nil
	}
}

func encodeMapValue(val interface{}) ([]byte, error) {
	switch v := val.(type) {
	case []byte:
		return v, nil
	case string:
		return []byte(v), nil
	case uint8:
		return []byte{v}, nil
	case uint16:
		buf := bytes.NewBuffer(make([]byte, 0, 2))
		if err := binary.Write(buf, binary.LittleEndian, v); err != nil {
			return nil, err
		}
		return buf.Bytes(), nil
	case uint32:
		buf := bytes.NewBuffer(make([]byte, 0, 4))
		if err := binary.Write(buf, binary.LittleEndian, v); err != nil {
			return nil, err
		}
		return buf.Bytes(), nil
	case uint64:
		buf := bytes.NewBuffer(make([]byte, 0, 8))
		if err := binary.Write(buf, binary.LittleEndian, v); err != nil {
			return nil, err
		}
		return buf.Bytes(), nil
	default:
		return nil, fmt.Errorf("unsupported default value type %T", val)
	}
}
