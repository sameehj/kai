package tools

import (
	"encoding/json"
	"fmt"
	"strings"
)

func decodeArgs(raw json.RawMessage, out any) error {
	if len(raw) == 0 {
		raw = json.RawMessage("{}")
	}
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(out); err != nil {
		return fmt.Errorf("invalid args: %w", err)
	}
	return nil
}

func strSchema(desc string) map[string]any {
	return map[string]any{
		"type":        "string",
		"description": desc,
	}
}

func req(name string, schema map[string]any) map[string]any {
	return map[string]any{name: schema, "$required": true}
}

func opt(name string, schema map[string]any) map[string]any {
	return map[string]any{name: schema}
}

func objSchema(fields ...map[string]any) map[string]any {
	props := map[string]any{}
	required := []string{}
	for _, f := range fields {
		for k, v := range f {
			if k == "$required" {
				continue
			}
			props[k] = v
			if fv, ok := f["$required"].(bool); ok && fv {
				required = append(required, k)
			}
		}
	}
	s := map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"properties":           props,
	}
	if len(required) > 0 {
		s["required"] = required
	}
	return s
}

func splitLines(s string) []string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	rows := strings.Split(s, "\n")
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		v := strings.TrimSpace(r)
		if v == "" {
			continue
		}
		out = append(out, v)
	}
	return out
}
