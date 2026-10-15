package agent

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/kai-agent/kai/internal/llm"
	"github.com/kai-agent/kai/internal/tools"
)

type ContextInput struct {
	Identity   string
	Soul       string
	SystemInfo string
	SkillsXML  string
	Memory     string
	Session    []llm.Message
	UserPrompt string
}

func BuildMessages(in ContextInput) []llm.Message {
	systemParts := []string{}
	if strings.TrimSpace(in.Identity) != "" {
		systemParts = append(systemParts, in.Identity)
	}
	if strings.TrimSpace(in.Soul) != "" {
		systemParts = append(systemParts, in.Soul)
	}
	if strings.TrimSpace(in.SystemInfo) != "" {
		systemParts = append(systemParts, "<system_orientation>\n"+in.SystemInfo+"\n</system_orientation>")
	}
	if strings.TrimSpace(in.SkillsXML) != "" {
		systemParts = append(systemParts, in.SkillsXML)
	}
	if strings.TrimSpace(in.Memory) != "" {
		systemParts = append(systemParts, "<memory>\n"+in.Memory+"\n</memory>")
	}
	systemParts = append(systemParts, selfManagementPrompt)

	messages := []llm.Message{{Role: llm.RoleSystem, Content: strings.Join(systemParts, "\n\n")}}
	messages = append(messages, in.Session...)
	messages = append(messages, llm.Message{Role: llm.RoleUser, Content: in.UserPrompt})
	return messages
}

const selfManagementPrompt = `
## Tool Use Requirements

You are Kai, a Linux systems agent. For system questions you MUST use tools.
Do not answer from memory when live system state is requested.

Examples:
- kernel version -> exec("uname -r")
- memory usage -> exec("free -h")
- disk usage -> exec("df -h")
- distro info -> read("/etc/os-release") or exec equivalent

If a user asks to run a command, attempt it through tools so policy can enforce safety.

## Self-Management

You can manage your own skills during conversation:

To add a GitHub repo as a skill:
1. exec: git clone <url> ~/.kai/community-skills/<name>/
2. read: the README.md from the cloned repo
3. write: metadata.yaml (requirements, description)
4. write: SKILL.md (operational playbook based on docs)
5. Report what you added and whether the target meets requirements.

To check installed skills:
1. search: scope=files, query="~/.kai/community-skills/*/metadata.yaml"
2. Read and summarize each.

To update a skill:
1. exec: cd ~/.kai/community-skills/<name> && git pull
2. Re-read docs and refresh SKILL.md if needed.

Skills you add should be actionable in future conversations.
`

func BuildToolDefs(reg *tools.Registry) []llm.ToolDef { return reg.LLMDefinitions() }

func FormatToolResults(results []tools.Result) string {
	rows := make([]map[string]any, 0, len(results))
	for _, r := range results {
		rows = append(rows, map[string]any{
			"tool":    r.Tool,
			"success": r.Success,
			"output":  r.Output,
			"error":   r.Error,
		})
	}
	b, _ := json.Marshal(rows)
	return string(b)
}

func ReadPromptFile(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func ToolBlockedMessage(tool, reason string) tools.Result {
	return tools.Result{Tool: tool, Success: false, Error: fmt.Sprintf("blocked by policy: %s", reason)}
}
