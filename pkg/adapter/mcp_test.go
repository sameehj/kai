package adapter

import (
	"bufio"
	"bytes"
	"encoding/json"
	"strconv"
	"strings"
	"testing"
)

func TestReadRPCMessageContentLength(t *testing.T) {
	t.Logf("content-length framed message")
	payload := `{"jsonrpc":"2.0","id":1,"method":"initialize"}`
	input := "Content-Length: " + strconv.Itoa(len(payload)) + "\r\n\r\n" + payload
	r := bufio.NewReader(strings.NewReader(input))
	out, err := readRPCMessage(r)
	if err != nil {
		t.Fatalf("readRPCMessage: %v", err)
	}
	if string(out) != payload {
		t.Fatalf("expected %q, got %q", payload, string(out))
	}
}

func TestReadRPCMessageInlineJSON(t *testing.T) {
	t.Logf("inline JSON message")
	payload := `{"jsonrpc":"2.0","id":1}`
	r := bufio.NewReader(strings.NewReader(payload + "\n"))
	out, err := readRPCMessage(r)
	if err != nil {
		t.Fatalf("readRPCMessage: %v", err)
	}
	if string(out) != payload+"\n" && string(out) != payload {
		t.Fatalf("unexpected output: %q", string(out))
	}
}

func TestWriteRPCResponse(t *testing.T) {
	t.Logf("writeRPCResponse adds headers and valid JSON")
	var buf bytes.Buffer
	w := bufio.NewWriter(&buf)
	if err := writeRPCResponse(w, 1, map[string]string{"ok": "true"}, nil); err != nil {
		t.Fatalf("writeRPCResponse: %v", err)
	}
	out := buf.String()
	if !strings.HasPrefix(out, "Content-Length:") {
		t.Fatalf("expected content-length header, got %q", out)
	}
	parts := strings.SplitN(out, "\r\n\r\n", 2)
	if len(parts) != 2 {
		t.Fatalf("expected header/body split")
	}
	var resp rpcResponse
	if err := json.Unmarshal([]byte(parts[1]), &resp); err != nil {
		t.Fatalf("invalid json body: %v", err)
	}
	if resp.JSONRPC != "2.0" {
		t.Fatalf("expected jsonrpc 2.0, got %q", resp.JSONRPC)
	}
}
