# Configuration

Kai reads `~/.kai/config.yaml`.

## Top-level sections

- `llm`: provider/model/key
- `targets`: named local/ssh/docker targets
- `channels`: slack/telegram/email settings
- `skills`: enabled/disabled/extra skill directories
- `policy`: allow/confirm/block/default mode
- `evidence`: run directory and retention
- `gateway`: bind address
- `heartbeat`: config parsing interval

## Minimal Example

```yaml
llm:
  provider: anthropic
  model: claude-3-5-sonnet-latest
  api_key: ${ANTHROPIC_API_KEY}

targets:
  local:
    type: local
    default: true

policy:
  default_mode: confirm

evidence:
  dir: ~/.kai/runs
  retention: 30d
```

## Skills

Built-in skills are loaded from:
- bundled `skills/` next to binary
- `~/.kai/skills`

Community skills are loaded from:
- `~/.kai/community-skills`

## Notes

- Environment variables inside `${...}` are expanded.
- If config is missing and you run in an interactive terminal, Kai launches onboarding.
