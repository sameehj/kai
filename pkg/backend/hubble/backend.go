package hubble

import (
	"context"
	"fmt"
	"io"
	"time"

	"github.com/cilium/cilium/api/v1/flow"
	"github.com/cilium/cilium/api/v1/observer"
	"github.com/sameehj/kai/pkg/types"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// Backend integrates with the Cilium Hubble API.
type Backend struct {
	client observer.ObserverClient
	conn   *grpc.ClientConn
}

// NewBackend creates a new Hubble backend connection.
func NewBackend(hubbleURL string) (*Backend, error) {
	if hubbleURL == "" {
		hubbleURL = "localhost:4245"
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := grpc.DialContext(ctx, hubbleURL,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithBlock(),
	)
	if err != nil {
		return nil, fmt.Errorf("connect to hubble: %w", err)
	}

	return &Backend{
		client: observer.NewObserverClient(conn),
		conn:   conn,
	}, nil
}

// Close releases the gRPC connection.
func (b *Backend) Close() error {
	if b.conn != nil {
		return b.conn.Close()
	}
	return nil
}

// RunSensor queries Hubble for flow data.
func (b *Backend) RunSensor(ctx context.Context, sensor *types.Sensor, params map[string]interface{}) (interface{}, error) {
	if sensor.Spec.Backend != "hubble" {
		return nil, fmt.Errorf("sensor backend mismatch")
	}

	req := &observer.GetFlowsRequest{
		Number: 1000,
	}

	if ns, ok := params["namespace"].(string); ok && ns != "" {
		req.Whitelist = append(req.Whitelist, &flow.FlowFilter{
			SourcePod: []string{fmt.Sprintf("%s/", ns)},
		})
	}

	if pod, ok := params["pod"].(string); ok && pod != "" {
		req.Whitelist = append(req.Whitelist, &flow.FlowFilter{
			SourcePod: []string{pod},
		})
	}

	duration := 10
	if d, ok := params["duration"].(int); ok && d > 0 {
		duration = d
	}

	ctx, cancel := context.WithTimeout(ctx, time.Duration(duration)*time.Second)
	defer cancel()

	stream, err := b.client.GetFlows(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("get flows: %w", err)
	}

	var (
		flows     []FlowSummary
		dropped   int
		forwarded int
		total     int
	)

	for {
		resp, err := stream.Recv()
		if err != nil {
			if err == io.EOF || ctx.Err() != nil {
				break
			}
			return nil, fmt.Errorf("receive flow: %w", err)
		}

		f := resp.GetFlow()
		if f == nil {
			continue
		}

		total++
		summary := summarizeFlow(f)

		switch f.GetVerdict() {
		case flow.Verdict_DROPPED:
			dropped++
		case flow.Verdict_FORWARDED:
			forwarded++
		}

		flows = append(flows, summary)
	}

	return map[string]interface{}{
		"sensor_id":       sensor.Metadata.ID,
		"sensor_name":     sensor.Metadata.Name,
		"backend":         "hubble",
		"timestamp":       time.Now().Unix(),
		"duration_sec":    duration,
		"total_flows":     total,
		"dropped_flows":   dropped,
		"forwarded_flows": forwarded,
		"flows":           flows,
		"success":         true,
	}, nil
}

func summarizeFlow(f *flow.Flow) FlowSummary {
	summary := FlowSummary{
		Timestamp: f.GetTime().AsTime(),
	}

	if ip := f.GetIP(); ip != nil {
		summary.SourceIP = ip.GetSource()
		summary.DestIP = ip.GetDestination()
	}

	if verdict := f.GetVerdict(); verdict != flow.Verdict(0) {
		summary.Verdict = verdict.String()
	}

	if desc := f.GetDropReasonDesc(); desc != flow.DropReason_DROP_REASON_UNKNOWN {
		summary.DropReason = desc.String()
	}

	if l4 := f.GetL4(); l4 != nil {
		switch {
		case l4.GetTCP() != nil:
			tcp := l4.GetTCP()
			summary.SourcePort = tcp.GetSourcePort()
			summary.DestPort = tcp.GetDestinationPort()
			summary.Protocol = "TCP"
		case l4.GetUDP() != nil:
			udp := l4.GetUDP()
			summary.SourcePort = udp.GetSourcePort()
			summary.DestPort = udp.GetDestinationPort()
			summary.Protocol = "UDP"
		case l4.GetICMPv4() != nil:
			summary.Protocol = "ICMPv4"
		case l4.GetICMPv6() != nil:
			summary.Protocol = "ICMPv6"
		default:
			if proto := l4.GetProtocol(); proto != nil {
				summary.Protocol = fmt.Sprintf("%T", proto)
			}
		}
	}

	return summary
}

// FlowSummary represents a single Hubble flow for downstream analysis.
type FlowSummary struct {
	Timestamp  time.Time `json:"timestamp"`
	SourceIP   string    `json:"source_ip"`
	DestIP     string    `json:"dest_ip"`
	SourcePort uint32    `json:"source_port"`
	DestPort   uint32    `json:"dest_port"`
	Protocol   string    `json:"protocol"`
	Verdict    string    `json:"verdict"`
	DropReason string    `json:"drop_reason,omitempty"`
}
