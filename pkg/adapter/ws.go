package adapter

import (
	"net/http"

	"github.com/gorilla/websocket"
)

func dialWebSocket(addr string) (*websocket.Conn, error) {
	conn, _, err := websocket.DefaultDialer.Dial(addr, http.Header{})
	if err != nil {
		return nil, err
	}
	return conn, nil
}

func writeWSMessage(conn *websocket.Conn, payload interface{}) error {
	return conn.WriteJSON(payload)
}

func readWSMessage(conn *websocket.Conn, out interface{}) error {
	return conn.ReadJSON(out)
}
