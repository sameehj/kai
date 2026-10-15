package skills

import (
	"fmt"
	"strings"
)

func AsPrompt(skills []Skill) string {
	if len(skills) == 0 {
		return "<available_skills></available_skills>"
	}
	var b strings.Builder
	b.WriteString("<available_skills>\n")
	for _, s := range skills {
		state := "full"
		if !s.Available {
			state = "unavailable"
		} else if s.Degraded {
			state = "degraded"
		}
		b.WriteString(fmt.Sprintf("  <skill name=\"%s\" state=\"%s\" path=\"%s\" description=\"%s\" />\n", xmlEscape(s.Name), xmlEscape(state), xmlEscape(s.Path), xmlEscape(s.Metadata.Description)))
	}
	b.WriteString("</available_skills>")
	return b.String()
}

func AsPromptWithContent(skills []Skill) string {
	if len(skills) == 0 {
		return "<available_skills></available_skills>"
	}
	var b strings.Builder
	b.WriteString("<available_skills>\n")
	for _, s := range skills {
		state := "full"
		if !s.Available {
			state = "unavailable"
		} else if s.Degraded {
			state = "degraded"
		}
		b.WriteString(fmt.Sprintf("  <skill name=\"%s\" state=\"%s\" description=\"%s\">\n", xmlEscape(s.Name), xmlEscape(state), xmlEscape(s.Metadata.Description)))
		content := strings.TrimSpace(s.Content)
		if content != "" {
			b.WriteString("    <playbook>\n")
			b.WriteString(xmlEscape(content))
			b.WriteString("\n    </playbook>\n")
		}
		b.WriteString("  </skill>\n")
	}
	b.WriteString("</available_skills>")
	return b.String()
}

func xmlEscape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, "\"", "&quot;")
	return s
}
