package adapter

type Message struct {
	SessionID string `json:"session_id"`
	Content   string `json:"content"`
}

type Response struct {
	Content string `json:"content"`
	Error   string `json:"error,omitempty"`
}
