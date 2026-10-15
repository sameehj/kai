package channels

func MarkdownToSlackBlocks(markdown string) []map[string]any {
	return []map[string]any{{
		"type": "section",
		"text": map[string]any{"type": "mrkdwn", "text": markdown},
	}}
}

func MarkdownToTelegramHTML(markdown string) string {
	return markdown
}

func MarkdownToEmailHTML(markdown string) string {
	return "<pre>" + markdown + "</pre>"
}
