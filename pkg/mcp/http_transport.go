package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/sameehj/kai/pkg/version"
)

const httpShutdownTimeout = 5 * time.Second

// ServeHTTPMCP exposes the MCP server over HTTP using SSE for streaming responses.
func ServeHTTPMCP(ctx context.Context, server *Server, addr string) error {
	transport := &httpTransport{
		server: server,
		subs:   make(map[chan []byte]struct{}),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/mcp", transport.handleMCP)

	httpServer := &http.Server{
		Addr:    addr,
		Handler: mux,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), httpShutdownTimeout)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

type httpTransport struct {
	server *Server

	mu   sync.Mutex
	subs map[chan []byte]struct{}
}

func (h *httpTransport) handleMCP(w http.ResponseWriter, r *http.Request) {
	h.setCORSHeaders(w)

	switch r.Method {
	case http.MethodGet:
		h.handleSSE(w, r)
	case http.MethodPost:
		h.handleJSONRPC(w, r)
	case http.MethodOptions:
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (h *httpTransport) handleSSE(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	client := make(chan []byte, 16)
	h.subscribe(client)
	defer h.unsubscribe(client)

	w.WriteHeader(http.StatusOK)
	if _, err := w.Write([]byte(": connected\n\n")); err != nil {
		return
	}
	flusher.Flush()

	for {
		select {
		case <-r.Context().Done():
			return
		case msg, ok := <-client:
			if !ok {
				return
			}
			if _, err := fmt.Fprintf(w, "data: %s\n\n", msg); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

func (h *httpTransport) handleJSONRPC(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()

	var req jsonRPCRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.writeRPCError(w, req.ID, -32700, fmt.Sprintf("invalid JSON: %v", err))
		return
	}

	if req.JSONRPC == "" {
		req.JSONRPC = "2.0"
	}

	resp := jsonRPCResponse{
		JSONRPC: "2.0",
		ID:      req.ID,
	}

	switch req.Method {
	case "ping":
		resp.Result = map[string]string{"message": "pong"}
	case "initialize":
		resp.Result = map[string]interface{}{
			"serverInfo": map[string]string{
				"name":    "kaid",
				"version": version.String(),
			},
			"capabilities": map[string]interface{}{
				"experimental": map[string]interface{}{},
			},
		}
	case "tools/list":
		resp.Result = map[string]interface{}{
			"tools": toolDescriptors,
		}
	case "tools/call":
		result, err := h.handleToolCall(r.Context(), req.Params)
		if err != nil {
			h.writeRPCError(w, req.ID, -32602, err.Error())
			return
		}
		resp.Result = result
	default:
		h.writeRPCError(w, req.ID, -32601, fmt.Sprintf("unknown method %q", req.Method))
		return
	}

	h.writeRPCResponse(w, resp)
	h.publish(resp)
}

func (h *httpTransport) handleToolCall(ctx context.Context, params json.RawMessage) (map[string]interface{}, error) {
	var call toolCallParams
	if err := json.Unmarshal(params, &call); err != nil {
		return nil, fmt.Errorf("decode params: %w", err)
	}
	if call.Name == "" {
		return nil, fmt.Errorf("missing tool name")
	}

	arguments := call.Arguments
	if len(arguments) == 0 {
		arguments = json.RawMessage([]byte("{}"))
	}
	result, err := h.server.HandleToolCall(ctx, call.Name, arguments)
	if err != nil {
		return nil, err
	}

	content := map[string]interface{}{
		"type": "text",
		"text": string(result),
	}
	if len(result) == 0 || string(result) == "null" {
		content["text"] = "ok"
	}

	return map[string]interface{}{
		"content": []map[string]interface{}{content},
	}, nil
}

func (h *httpTransport) writeRPCResponse(w http.ResponseWriter, resp jsonRPCResponse) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)

	if err := json.NewEncoder(w).Encode(resp); err != nil {
		fmt.Printf("write response: %v\n", err)
		return
	}
}

func (h *httpTransport) writeRPCError(w http.ResponseWriter, id json.RawMessage, code int, msg string) {
	resp := jsonRPCResponse{
		JSONRPC: "2.0",
		ID:      id,
		Error: &jsonRPCError{
			Code:    code,
			Message: msg,
		},
	}
	h.writeRPCResponse(w, resp)
	h.publish(resp)
}

func (h *httpTransport) setCORSHeaders(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
}

func (h *httpTransport) subscribe(ch chan []byte) {
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	h.mu.Unlock()
}

func (h *httpTransport) unsubscribe(ch chan []byte) {
	h.mu.Lock()
	if _, ok := h.subs[ch]; ok {
		delete(h.subs, ch)
		close(ch)
	}
	h.mu.Unlock()
}

func (h *httpTransport) publish(resp jsonRPCResponse) {
	data, err := json.Marshal(resp)
	if err != nil {
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- data:
		default:
		}
	}
}

type jsonRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

type jsonRPCResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  interface{}     `json:"result,omitempty"`
	Error   *jsonRPCError   `json:"error,omitempty"`
}

type jsonRPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type toolCallParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

type ToolDescriptor struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"input_schema"`
}

var toolDescriptors = []ToolDescriptor{
	newToolDescriptor(
		"kai__list_remote",
		"List all remote packages from the configured index",
		map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"index": map[string]interface{}{
					"type":        "string",
					"description": "URL to the recipe index",
				},
			},
			"required": []string{"index"},
		},
	),
	newToolDescriptor(
		"kai__list_local",
		"List all packages installed locally",
		map[string]interface{}{
			"type":       "object",
			"properties": map[string]interface{}{},
		},
	),
	newToolDescriptor(
		"kai__install_package",
		"Install a package version from the remote index",
		map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"name": map[string]interface{}{"type": "string"},
				"version": map[string]interface{}{
					"type": "string",
				},
				"index": map[string]interface{}{
					"type": "string",
				},
			},
			"required": []string{"name", "version", "index"},
		},
	),
	newToolDescriptor(
		"kai__remove_package",
		"Remove a package from local storage",
		map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"package": map[string]interface{}{"type": "string"},
			},
			"required": []string{"package"},
		},
	),
	newToolDescriptor(
		"kai__load_program",
		"Load a package manifest into the runtime",
		map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"package": map[string]interface{}{"type": "string"},
			},
			"required": []string{"package"},
		},
	),
	newToolDescriptor(
		"kai__attach_program",
		"Attach a loaded package to a namespace",
		map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"package_id": map[string]interface{}{"type": "string"},
				"namespace": map[string]interface{}{
					"type": "object",
				},
			},
			"required": []string{"package_id"},
		},
	),
	newToolDescriptor(
		"kai__stream_events",
		"Stream events from a ring buffer",
		map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"package_id": map[string]interface{}{"type": "string"},
				"buffer":     map[string]interface{}{"type": "string"},
				"limit":      map[string]interface{}{"type": "integer"},
			},
			"required": []string{"package_id"},
		},
	),
	newToolDescriptor(
		"kai__inspect_state",
		"Inspect the runtime state",
		map[string]interface{}{
			"type":       "object",
			"properties": map[string]interface{}{},
		},
	),
	newToolDescriptor(
		"kai__inspect_kernel",
		"Inspect kernel support for KAI",
		map[string]interface{}{
			"type":       "object",
			"properties": map[string]interface{}{},
		},
	),
	newToolDescriptor(
		"kai__unload_program",
		"Unload a package from the runtime",
		map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"package_id": map[string]interface{}{"type": "string"},
			},
			"required": []string{"package_id"},
		},
	),
	newToolDescriptor(
		"kai__validate_package",
		"Validate a package manifest via policy",
		map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"manifest_path": map[string]interface{}{"type": "string"},
			},
			"required": []string{"manifest_path"},
		},
	),
}

func newToolDescriptor(name, description string, schema map[string]interface{}) ToolDescriptor {
	data, err := json.Marshal(schema)
	if err != nil {
		panic(err)
	}
	return ToolDescriptor{
		Name:        name,
		Description: description,
		InputSchema: data,
	}
}

// ToolDescriptors returns the list of tool descriptors advertised by the MCP server.
func ToolDescriptors() []ToolDescriptor {
	descriptors := make([]ToolDescriptor, len(toolDescriptors))
	copy(descriptors, toolDescriptors)
	return descriptors
}
