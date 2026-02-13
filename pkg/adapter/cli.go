package adapter

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"strings"

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
			return err
		}
		var resp Response
		if err := readWSMessage(conn, &resp); err != nil {
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
