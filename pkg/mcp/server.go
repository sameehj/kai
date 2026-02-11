package mcp

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/sameehj/kai/pkg/exec"
	"github.com/sameehj/kai/pkg/system"
	"github.com/sameehj/kai/pkg/tool"
	"log/slog"
)

type Server struct {
	executor *exec.SafeExecutor
	registry *tool.Registry
	profile  *system.Profile
	logger   *slog.Logger
}

func NewServer(executor *exec.SafeExecutor, registry *tool.Registry, profile *system.Profile) *Server {
	return &Server{executor: executor, registry: registry, profile: profile}
}

func (s *Server) SetLogger(logger *slog.Logger) {
	s.logger = logger
}

func (s *Server) Serve(reader io.Reader, writer io.Writer) error {
	bufReader := bufio.NewReader(reader)
	bufWriter := bufio.NewWriter(writer)

	for {
		payload, err := readMessage(bufReader)
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			s.logError("mcp_read_failed", "error", err)
			return err
		}

		var req rpcRequest
		if err := json.Unmarshal(payload, &req); err != nil {
			s.logWarn("mcp_parse_error", "error", err)
			_ = writeError(bufWriter, req.ID, -32700, "parse error", err.Error())
			continue
		}

		if req.Method == "" {
			_ = writeError(bufWriter, req.ID, -32600, "invalid request", "missing method")
			continue
		}

		switch req.Method {
		case "initialize":
			_ = writeResult(bufWriter, req.ID, map[string]any{
				"protocolVersion": "2024-11-05",
				"capabilities": map[string]any{
					"tools": map[string]any{},
				},
				"serverInfo": map[string]any{
					"name":    "kai",
					"version": "dev",
				},
			})
		case "kai.tools.list":
			_ = writeResult(bufWriter, req.ID, map[string]any{
				"tools": s.listTools(),
			})
		case "kai.tools.get":
			_ = s.handleToolsGet(req.ID, req.Params, bufWriter)
		case "kai.tools.create":
			_ = s.handleToolsCreate(req.ID, req.Params, bufWriter)
		case "kai.system.info":
			_ = writeResult(bufWriter, req.ID, s.profile)
		case "kai.exec":
			_ = s.handleExec(req.ID, req.Params, bufWriter)
		default:
			_ = writeError(bufWriter, req.ID, -32601, "method not found", req.Method)
		}
	}
}

func (s *Server) ServeStdio() error {
	return s.Serve(os.Stdin, os.Stdout)
}

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      interface{}     `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      interface{} `json:"id,omitempty"`
	Result  interface{} `json:"result,omitempty"`
	Error   *rpcError   `json:"error,omitempty"`
}

type rpcError struct {
	Code    int         `json:"code"`
	Message string      `json:"message"`
	Data    interface{} `json:"data,omitempty"`
}

type execParams struct {
	Cmd       string   `json:"cmd"`
	Args      []string `json:"args"`
	TimeoutMS int      `json:"timeout_ms"`
	MaxOutput int      `json:"max_output"`
	Blocklist []string `json:"blocklist"`
}

type toolsGetParams struct {
	Name string `json:"name"`
}

type toolsCreateParams struct {
	Name    string `json:"name"`
	Content string `json:"content"`
}

func (s *Server) listTools() []Tool {
	tools := s.registry.List()
	out := make([]Tool, 0, len(tools))
	for _, t := range tools {
		if t == nil {
			continue
		}
		meta := map[string]any{
			"path":      t.Path,
			"available": t.Metadata.Available,
			"reason":    t.Metadata.Reason,
			"emoji":     t.Metadata.Metadata.Kai.Emoji,
		}
		out = append(out, Tool{
			Name:        t.Name,
			Description: t.Description,
			Metadata:    meta,
		})
	}
	return out
}

func (s *Server) handleToolsGet(id interface{}, params json.RawMessage, writer *bufio.Writer) error {
	var req toolsGetParams
	if err := json.Unmarshal(params, &req); err != nil {
		return writeError(writer, id, -32602, "invalid params", err.Error())
	}
	toolItem, ok := s.registry.Get(req.Name)
	if !ok {
		return writeError(writer, id, -32004, "tool not found", req.Name)
	}
	return writeResult(writer, id, map[string]any{
		"name":        toolItem.Name,
		"description": toolItem.Description,
		"content":     toolItem.Content,
		"metadata":    toolItem.Metadata,
	})
}

func (s *Server) handleToolsCreate(id interface{}, params json.RawMessage, writer *bufio.Writer) error {
	var req toolsCreateParams
	if err := json.Unmarshal(params, &req); err != nil {
		return writeError(writer, id, -32602, "invalid params", err.Error())
	}
	toolItem, err := s.registry.Create(req.Name, req.Content)
	if err != nil {
		s.logError("tool_create_failed", "error", err)
		return writeError(writer, id, -32002, "create failed", err.Error())
	}
	return writeResult(writer, id, map[string]any{
		"name": toolItem.Name,
		"path": toolItem.Path,
	})
}

func (s *Server) handleExec(id interface{}, params json.RawMessage, writer *bufio.Writer) error {
	var req execParams
	if err := json.Unmarshal(params, &req); err != nil {
		return writeError(writer, id, -32602, "invalid params", err.Error())
	}

	executor := *s.executor
	if req.TimeoutMS > 0 {
		executor.Timeout = time.Millisecond * time.Duration(req.TimeoutMS)
	}
	if req.MaxOutput > 0 {
		executor.MaxOutput = req.MaxOutput
	}
	if len(req.Blocklist) > 0 {
		executor.Blocklist = req.Blocklist
	}

	res, err := executor.Run(req.Cmd, req.Args)
	if err != nil {
		return writeError(writer, id, -32010, "exec failed", err.Error())
	}
	return writeResult(writer, id, res)
}

func writeResult(w *bufio.Writer, id interface{}, result interface{}) error {
	if id == nil {
		return nil
	}
	resp := rpcResponse{JSONRPC: "2.0", ID: id, Result: result}
	payload, err := json.Marshal(resp)
	if err != nil {
		return err
	}
	return writeMessage(w, payload)
}

func writeError(w *bufio.Writer, id interface{}, code int, message string, data interface{}) error {
	if id == nil {
		return nil
	}
	resp := rpcResponse{JSONRPC: "2.0", ID: id, Error: &rpcError{Code: code, Message: message, Data: data}}
	payload, err := json.Marshal(resp)
	if err != nil {
		return err
	}
	return writeMessage(w, payload)
}

func writeMessage(w *bufio.Writer, payload []byte) error {
	if _, err := fmt.Fprintf(w, "Content-Length: %d\r\n\r\n", len(payload)); err != nil {
		return err
	}
	if _, err := w.Write(payload); err != nil {
		return err
	}
	return w.Flush()
}

func readMessage(r *bufio.Reader) ([]byte, error) {
	for {
		line, err := r.ReadString('\n')
		if err != nil && len(line) == 0 {
			return nil, err
		}
		trimmed := strings.TrimRight(line, "\r\n")
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "{") {
			return []byte(trimmed), nil
		}

		contentLength := 0
		if strings.HasPrefix(strings.ToLower(trimmed), "content-length:") {
			value := strings.TrimSpace(strings.SplitN(trimmed, ":", 2)[1])
			length, parseErr := strconv.Atoi(value)
			if parseErr != nil {
				return nil, parseErr
			}
			contentLength = length
		}

		for {
			headerLine, readErr := r.ReadString('\n')
			if readErr != nil && len(headerLine) == 0 {
				return nil, readErr
			}
			header := strings.TrimRight(headerLine, "\r\n")
			if header == "" {
				break
			}
			if strings.HasPrefix(strings.ToLower(header), "content-length:") {
				value := strings.TrimSpace(strings.SplitN(header, ":", 2)[1])
				length, parseErr := strconv.Atoi(value)
				if parseErr != nil {
					return nil, parseErr
				}
				contentLength = length
			}
		}

		if contentLength <= 0 {
			return nil, fmt.Errorf("missing Content-Length")
		}

		payload := make([]byte, contentLength)
		if _, err := io.ReadFull(r, payload); err != nil {
			return nil, err
		}
		return payload, nil
	}
}

func (s *Server) logInfo(msg string, args ...any) {
	if s.logger != nil {
		s.logger.Info(msg, args...)
	}
}

func (s *Server) logWarn(msg string, args ...any) {
	if s.logger != nil {
		s.logger.Warn(msg, args...)
	}
}

func (s *Server) logError(msg string, args ...any) {
	if s.logger != nil {
		s.logger.Error(msg, args...)
	}
}
