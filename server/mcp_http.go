package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/sameehj/kai/pkg/mcp"
	"github.com/sameehj/kai/pkg/runtime"
)

const httpShutdownTimeout = 5 * time.Second

// JSONRPCRequest represents an incoming MCP JSON-RPC request.
type JSONRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

// JSONRPCResponse represents an MCP JSON-RPC response.
type JSONRPCResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  interface{}     `json:"result,omitempty"`
	Error   interface{}     `json:"error,omitempty"`
}

type toolCallParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

// MCPHTTPServer exposes the MCP server over Cursor's HTTP/SSE protocol.
const mcpProtocolVersion = "2024-11-05"

type MCPHTTPServer struct {
	rt         *runtime.Runtime
	mcpServer  *mcp.Server
	sseMu      sync.Mutex
	sseClients map[chan []byte]struct{}
}

func NewMCPHTTPServer(rt *runtime.Runtime, srv *mcp.Server) *MCPHTTPServer {
	return &MCPHTTPServer{
		rt:         rt,
		mcpServer:  srv,
		sseClients: make(map[chan []byte]struct{}),
	}
}

// ServeHTTP routes MCP HTTP traffic to SSE or JSON-RPC handlers.
func (s *MCPHTTPServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.handleSSE(w, r)
	case http.MethodPost:
		s.handleJSONRPC(w, r)
	case http.MethodOptions:
		s.writeCORSHeaders(w)
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *MCPHTTPServer) handleSSE(w http.ResponseWriter, r *http.Request) {
	log.Println("[MCP] SSE connection established")

	s.writeCORSHeaders(w)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming not supported", http.StatusInternalServerError)
		return
	}

	fmt.Fprintf(w, "event: mcp_ready\n")
	fmt.Fprintf(w, "data: {}\n\n")
	flusher.Flush()

	clientChan := make(chan []byte, 16)
	s.addSSEClient(clientChan)
	defer s.removeSSEClient(clientChan)

	for {
		select {
		case <-r.Context().Done():
			log.Println("[MCP] SSE client disconnected")
			return
		case msg := <-clientChan:
			fmt.Fprintf(w, "event: message\n")
			fmt.Fprintf(w, "data: %s\n\n", msg)
			flusher.Flush()
		}
	}
}

func (s *MCPHTTPServer) handleJSONRPC(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()

	s.writeCORSHeaders(w)

	var req JSONRPCRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON-RPC request", http.StatusBadRequest)
		return
	}

	switch req.Method {
	case "initialize":
		s.writeJSONRPC(w, req.ID, map[string]interface{}{
			"protocolVersion": mcpProtocolVersion,
			"serverInfo": map[string]string{
				"name":    "kaid",
				"version": "dev",
			},
			"capabilities": map[string]interface{}{
				"tools":       map[string]interface{}{},
				"resources":   map[string]interface{}{},
				"prompts":     map[string]interface{}{},
				"roots":       map[string]interface{}{},
				"elicitation": true,
			},
		})
	case "tools/list":
		s.writeJSONRPC(w, req.ID, map[string]interface{}{
			"tools": s.listTools(),
		})
	case "prompts/list":
		s.writeJSONRPC(w, req.ID, map[string]interface{}{
			"prompts": []interface{}{},
		})
	case "resources/list":
		s.writeJSONRPC(w, req.ID, map[string]interface{}{
			"resources": []interface{}{},
		})
	case "roots/list":
		s.writeJSONRPC(w, req.ID, map[string]interface{}{
			"roots": []interface{}{},
		})
	case "tools/call":
		result, err := s.handleToolCall(r.Context(), req.Params)
		if err != nil {
			s.writeJSONError(w, req.ID, err)
			return
		}
		s.writeJSONRPC(w, req.ID, result)
	default:
		s.writeJSONError(w, req.ID, fmt.Errorf("unknown method %s", req.Method))
	}
}

func (s *MCPHTTPServer) handleToolCall(ctx context.Context, params json.RawMessage) (interface{}, error) {
	var call toolCallParams
	if err := json.Unmarshal(params, &call); err != nil {
		return nil, fmt.Errorf("decode params: %w", err)
	}
	if call.Name == "" {
		return nil, fmt.Errorf("missing tool name")
	}

	if len(call.Arguments) == 0 {
		call.Arguments = json.RawMessage([]byte("{}"))
	}

	result, err := s.mcpServer.HandleToolCall(ctx, call.Name, call.Arguments)
	if err != nil {
		return nil, err
	}

	text := string(result)
	if len(result) == 0 || text == "null" {
		text = "ok"
	}

	return map[string]interface{}{
		"content": []map[string]interface{}{
			{
				"type": "text",
				"text": text,
			},
		},
	}, nil
}

func (s *MCPHTTPServer) listTools() []mcp.ToolDescriptor {
	return mcp.ToolDescriptors()
}

func (s *MCPHTTPServer) writeJSONRPC(w http.ResponseWriter, id json.RawMessage, result interface{}) {
	resp := JSONRPCResponse{
		JSONRPC: "2.0",
		ID:      id,
		Result:  result,
	}
	s.writeJSONResponse(w, resp)
}

func (s *MCPHTTPServer) writeJSONError(w http.ResponseWriter, id json.RawMessage, err error) {
	resp := JSONRPCResponse{
		JSONRPC: "2.0",
		ID:      id,
		Error: map[string]interface{}{
			"message": err.Error(),
		},
	}
	s.writeJSONResponse(w, resp)
}

func (s *MCPHTTPServer) writeCORSHeaders(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
}

func (s *MCPHTTPServer) writeJSONResponse(w http.ResponseWriter, resp JSONRPCResponse) {
	w.Header().Set("Content-Type", "application/json")

	data, err := json.Marshal(resp)
	if err != nil {
		http.Error(w, "failed to encode JSON-RPC response", http.StatusInternalServerError)
		return
	}

	if _, err := w.Write(append(data, '\n')); err != nil {
		log.Printf("[MCP] failed to write response: %v", err)
		return
	}

	s.broadcastSSE(data)
}

func (s *MCPHTTPServer) addSSEClient(ch chan []byte) {
	s.sseMu.Lock()
	defer s.sseMu.Unlock()
	s.sseClients[ch] = struct{}{}
}

func (s *MCPHTTPServer) removeSSEClient(ch chan []byte) {
	s.sseMu.Lock()
	defer s.sseMu.Unlock()
	delete(s.sseClients, ch)
}

func (s *MCPHTTPServer) broadcastSSE(msg []byte) {
	s.sseMu.Lock()
	defer s.sseMu.Unlock()

	for ch := range s.sseClients {
		select {
		case ch <- msg:
		default:
			// drop message if client is lagging
		}
	}
}

// StartMCPHTTP launches the HTTP+SSE MCP server until the context is cancelled.
func StartMCPHTTP(ctx context.Context, rt *runtime.Runtime, srv *mcp.Server, addr string) error {
	handler := NewMCPHTTPServer(rt, srv)
	httpServer := &http.Server{
		Addr:    addr,
		Handler: handler,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), httpShutdownTimeout)
		defer cancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			log.Printf("[MCP] HTTP shutdown error: %v\n", err)
		}
	}()

	log.Println("[MCP] Listening on", addr)
	if err := httpServer.ListenAndServe(); err != nil {
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
	return nil
}
