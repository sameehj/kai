package ebpf

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	"github.com/cilium/ebpf/ringbuf"
	"github.com/sameehj/kai/pkg/types"
)

// Backend loads and runs custom eBPF programs defined by sensors.
type Backend struct{}

// NewBackend constructs an eBPF backend instance.
func NewBackend() *Backend {
	return &Backend{}
}

// RunSensor loads the configured bytecode and captures events through a ring buffer.
func (b *Backend) RunSensor(ctx context.Context, sensor *types.Sensor, params map[string]interface{}) (interface{}, error) {
	if sensor.Spec.Backend != "ebpf" {
		return nil, fmt.Errorf("sensor backend mismatch")
	}

	config := sensor.Spec.With
	if config == nil {
		return nil, fmt.Errorf("sensor spec missing ebpf configuration")
	}

	programPath, _ := config["bytecode"].(string)
	if programPath == "" {
		return nil, fmt.Errorf("bytecode path not specified")
	}

	spec, err := ebpf.LoadCollectionSpec(programPath)
	if err != nil {
		return nil, fmt.Errorf("load spec: %w", err)
	}

	coll, err := ebpf.NewCollection(spec)
	if err != nil {
		return nil, fmt.Errorf("create collection: %w", err)
	}
	defer coll.Close()

	section, _ := config["section"].(string)
	if section == "" {
		return nil, fmt.Errorf("program section not specified")
	}

	prog, ok := coll.Programs[section]
	if !ok {
		return nil, fmt.Errorf("program section %s not found", section)
	}

	var l link.Link
	if attachType, _ := config["attach_type"].(string); attachType != "" {
		switch attachType {
		case "kprobe":
			symbol, _ := config["symbol"].(string)
			if symbol == "" {
				return nil, fmt.Errorf("kprobe symbol required")
			}
			l, err = link.Kprobe(symbol, prog, nil)
		case "tracepoint":
			group, _ := config["group"].(string)
			name, _ := config["name"].(string)
			if group == "" || name == "" {
				return nil, fmt.Errorf("tracepoint group/name required")
			}
			l, err = link.Tracepoint(group, name, prog, nil)
		default:
			return nil, fmt.Errorf("unsupported attach type: %s", attachType)
		}

		if err != nil {
			return nil, fmt.Errorf("attach program: %w", err)
		}
		defer l.Close()
	}

	eventsMap, ok := coll.Maps["events"]
	if !ok {
		return nil, fmt.Errorf("ring buffer map 'events' not found")
	}

	rd, err := ringbuf.NewReader(eventsMap)
	if err != nil {
		return nil, fmt.Errorf("open ringbuf: %w", err)
	}
	var closeOnce sync.Once
	closeReader := func() {
		closeOnce.Do(func() {
			rd.Close()
		})
	}
	defer closeReader()

	duration := 10
	if d, ok := params["duration"].(int); ok && d > 0 {
		duration = d
	}

	timeoutCtx, cancel := context.WithTimeout(ctx, time.Duration(duration)*time.Second)
	defer cancel()

	go func() {
		<-timeoutCtx.Done()
		closeReader()
	}()

	samples := make(chan []byte)
	errCh := make(chan error, 1)

	go func() {
		defer close(samples)
		for {
			record, err := rd.Read()
			if err != nil {
				errCh <- err
				return
			}
			copyBuf := make([]byte, len(record.RawSample))
			copy(copyBuf, record.RawSample)
			samples <- copyBuf
		}
	}()

	var events []map[string]interface{}

readLoop:
	for {
		select {
		case <-timeoutCtx.Done():
			closeReader()
			break readLoop
		case sample, ok := <-samples:
			if !ok {
				samples = nil
				continue
			}
			events = append(events, parseEvent(sample))
		case err := <-errCh:
			if err != nil {
				if errors.Is(err, ringbuf.ErrClosed) && timeoutCtx.Err() != nil {
					break readLoop
				}
				return nil, fmt.Errorf("read ringbuf: %w", err)
			}
		}
	}

	select {
	case err := <-errCh:
		if err != nil && !errors.Is(err, ringbuf.ErrClosed) {
			return nil, fmt.Errorf("read ringbuf: %w", err)
		}
	default:
	}

	return map[string]interface{}{
		"sensor_id":   sensor.Metadata.ID,
		"sensor_name": sensor.Metadata.Name,
		"backend":     "ebpf",
		"timestamp":   time.Now().Unix(),
		"duration":    duration,
		"event_count": len(events),
		"events":      events,
		"success":     true,
	}, nil
}

func parseEvent(data []byte) map[string]interface{} {
	if len(data) < binary.Size(tcpEvent{}) {
		return map[string]interface{}{"raw": data}
	}

	var evt tcpEvent
	if err := binary.Read(bytes.NewReader(data), binary.LittleEndian, &evt); err != nil {
		return map[string]interface{}{
			"raw":   data,
			"error": err.Error(),
		}
	}

	event := map[string]interface{}{
		"timestamp_ns": evt.TimestampNS,
		"pid":          evt.PID,
		"sport":        evt.SourcePort,
		"dport":        evt.DestPort,
		"family":       evt.Family,
		"comm":         strings.TrimRight(string(evt.Comm[:]), "\x00"),
	}

	switch evt.Family {
	case 2: // AF_INET
		event["saddr"] = formatIPv4(evt.SourceAddr)
		event["daddr"] = formatIPv4(evt.DestAddr)
	default:
		event["saddr"] = evt.SourceAddr
		event["daddr"] = evt.DestAddr
	}

	return event
}

type tcpEvent struct {
	TimestampNS uint64
	PID         uint32
	SourceAddr  uint32
	DestAddr    uint32
	SourcePort  uint16
	DestPort    uint16
	Family      uint8
	_           [3]byte
	Comm        [16]byte
}

func formatIPv4(addr uint32) string {
	ip := make(net.IP, 4)
	binary.BigEndian.PutUint32(ip, addr)
	return ip.String()
}
