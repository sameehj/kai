package adapter

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/gorilla/websocket"
	"github.com/sameehj/kai/pkg/session"
)

type CLIAdapter struct {
	gatewayAddr string
	sessionID   session.SessionID
}

func NewCLIAdapter(gatewayAddr string) *CLIAdapter {
	return &CLIAdapter{gatewayAddr: gatewayAddr, sessionID: session.MainSession}
}

func (a *CLIAdapter) Start(ctx context.Context) error {
	conn, err := dialWebSocket(a.gatewayAddr)
	if err != nil {
		return err
	}
	defer conn.Close()

	reader := bufio.NewReader(os.Stdin)
	fmt.Println("KAI Assistant")
	fmt.Println("Type 'exit' to quit")

	for {
		fmt.Print("You: ")
		text, _ := reader.ReadString('\n')
		text = strings.TrimSpace(text)
		if text == "exit" {
			break
		}
		msg := Message{SessionID: string(a.sessionID), Content: text}
		if err := writeWSMessage(conn, msg); err != nil {
			if msg := policyViolationHint(err); msg != "" {
				return errors.New(msg)
			}
			if isNormalClose(err) {
				fmt.Println("\nGateway disconnected. Reconnect and try again.")
				return nil
			}
			return err
		}
		var resp Response
		if err := readWSMessage(conn, &resp); err != nil {
			if msg := policyViolationHint(err); msg != "" {
				return errors.New(msg)
			}
			if isNormalClose(err) {
				fmt.Println("\nGateway disconnected. Reconnect and try again.")
				return nil
			}
			return err
		}
		if resp.Error != "" {
			fmt.Printf("\nKAI Error: %s\n\n", resp.Error)
			continue
		}
		fmt.Printf("\nKAI: %s\n\n", resp.Content)
	}
	return nil
}

func isNormalClose(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, io.EOF) {
		return true
	}
	return websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway)
}

func policyViolationHint(err error) string {
	var closeErr *websocket.CloseError
	if !errors.As(err, &closeErr) {
		return ""
	}
	if closeErr.Code != websocket.ClosePolicyViolation {
		return ""
	}
	if strings.Contains(strings.ToLower(closeErr.Text), "invalid request frame") {
		return "gateway rejected request frame: this usually means ws://127.0.0.1:18790 is not a KAI gateway. Start `kai gateway` or set KAI_GATEWAY_ADDR."
	}
	return ""
}
