package adapter

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	"github.com/sameehj/kai/pkg/session"
)

const mcpInstructions = `You are connected to KAI, a local AI assistant gateway.

How to work with KAI:
1. Start by asking for context about the machine.
2. Use available skills as documentation and follow them step-by-step.
3. When you need to execute, use the tool loop via the gateway.
4. Keep each command focused, read results, then decide the next step.
`

type MCPAdapter struct {
	gatewayAddr string
	sessionID   session.SessionID
	conn        *websocket.Conn
}

func NewMCPAdapter(gatewayAddr string) *MCPAdapter {
	return &MCPAdapter{
		gatewayAddr: gatewayAddr,
		sessionID:   session.MainSession,
	}
}

func (a *MCPAdapter) Start(ctx context.Context) error {
	reader := bufio.NewReader(os.Stdin)
	writer := bufio.NewWriter(os.Stdout)
	defer writer.Flush()
	defer func() {
		if a.conn != nil {
			_ = a.conn.Close()
		}
	}()

	for {
		reqBytes, err := readRPCMessage(reader)
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		func() {
			var req rpcRequest
			defer func() {
				if r := recover(); r != nil {
					_ = writeRPCResponse(writer, req.ID, nil, &rpcError{-32000, fmt.Sprintf("panic: %v", r)})
				}
			}()
			if err := json.Unmarshal(reqBytes, &req); err != nil {
				_ = writeRPCResponse(writer, req.ID, nil, &rpcError{-32700, "Parse error"})
				return
			}
			switch req.Method {
			case "initialize":
				result := map[string]interface{}{
					"server": map[string]interface{}{
						"name":    "kai",
						"version": "0.1.0",
					},
					"instructions": mcpInstructions,
				}
				_ = writeRPCResponse(writer, req.ID, result, nil)
			case "message":
				var params mcpMessageParams
				if err := json.Unmarshal(req.Params, &params); err != nil {
					_ = writeRPCResponse(writer, req.ID, nil, &rpcError{-32700, "Invalid params"})
					return
				}
				sid := a.sessionID
				if params.SessionID != "" {
					sid = session.SessionID(params.SessionID)
				}
				msg := Message{SessionID: string(sid), Content: params.Content}
				conn, err := a.ensureConn()
				if err != nil {
					_ = writeRPCResponse(writer, req.ID, nil, &rpcError{-32000, err.Error()})
					return
				}
				_ = conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
				if err := writeWSMessage(conn, msg); err != nil {
					_ = writeRPCResponse(writer, req.ID, nil, &rpcError{-32000, err.Error()})
					return
				}
				var resp Response
				_ = conn.SetReadDeadline(time.Now().Add(90 * time.Second))
				if err := readWSMessage(conn, &resp); err != nil {
					_ = writeRPCResponse(writer, req.ID, nil, &rpcError{-32000, err.Error()})
					return
				}
				if resp.Error != "" {
					_ = writeRPCResponse(writer, req.ID, nil, &rpcError{-32000, resp.Error})
					return
				}
				_ = writeRPCResponse(writer, req.ID, map[string]interface{}{"content": resp.Content}, nil)
			default:
				_ = writeRPCResponse(writer, req.ID, nil, &rpcError{-32601, "Method not found"})
			}
		}()
	}
}

func (a *MCPAdapter) ensureConn() (*websocket.Conn, error) {
	if a.conn != nil {
		return a.conn, nil
	}
	conn, err := dialWebSocket(a.gatewayAddr)
	if err != nil {
		return nil, err
	}
	a.conn = conn
	return conn, nil
}

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      interface{}     `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      interface{} `json:"id"`
	Result  interface{} `json:"result,omitempty"`
	Error   *rpcError   `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type mcpMessageParams struct {
	Content   string `json:"content"`
	SessionID string `json:"session_id,omitempty"`
}

func readRPCMessage(r *bufio.Reader) ([]byte, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		return nil, err
	}
	if strings.HasPrefix(line, "Content-Length:") {
		lengthStr := strings.TrimSpace(strings.TrimPrefix(line, "Content-Length:"))
		length, err := strconv.Atoi(lengthStr)
		if err != nil {
			return nil, err
		}
		for {
			h, err := r.ReadString('\n')
			if err != nil {
				return nil, err
			}
			if h == "\r\n" || h == "\n" {
				break
			}
		}
		buf := make([]byte, length)
		if _, err := io.ReadFull(r, buf); err != nil {
			return nil, err
		}
		return buf, nil
	}
	if strings.HasPrefix(strings.TrimSpace(line), "{") {
		return []byte(line), nil
	}
	return nil, fmt.Errorf("unknown framing")
}

func writeRPCResponse(w *bufio.Writer, id interface{}, result interface{}, rpcErr *rpcError) error {
	resp := rpcResponse{JSONRPC: "2.0", ID: id, Result: result, Error: rpcErr}
	b, err := json.Marshal(resp)
	if err != nil {
		return err
	}
	if mcpPlainJSON() {
		if _, err := w.Write(append(b, '\n')); err != nil {
			return err
		}
		return w.Flush()
	}
	header := fmt.Sprintf("Content-Length: %d\r\n\r\n", len(b))
	if _, err := w.WriteString(header); err != nil {
		return err
	}
	if _, err := w.Write(b); err != nil {
		return err
	}
	return w.Flush()
}

func mcpPlainJSON() bool {
	return os.Getenv("KAI_MCP_PLAIN_JSON") != ""
}
