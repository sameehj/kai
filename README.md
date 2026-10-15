# Kai - The Linux Systems Agent

Open-source systems agent in Go. Runs on your machine, operates Linux targets via SSH/Docker/local, reports to Slack/Telegram/Email, and logs full evidence.

One binary. 5 tools. Expanding skills.

## Install

```bash
curl -fsSL https://usekai.dev/install | sh
```

## First Run

```bash
kai
```

Kai walks you through provider, target, skills, notifications, safety, and a first health check.

## Example Prompts

```bash
kai "my server is slow, figure out why"
kai "audit this machine"
kai "check network health"
kai "what kernel am I running?"
```

## Skill Management

```bash
kai skill add https://github.com/iovisor/bcc
kai skill list
kai skill update bcc
kai skill remove bcc
```

Community skills live under `~/.kai/community-skills/`.

## Built-in Skills

- `env-setup`
- `build-debug`
- `watch`
- `server-audit`
- `perf-diagnosis`
- `ebpf-dev`
- `kernel-dev`

## Works With

- Targets: local, SSH, Docker
- Channels: stdout, Slack webhook, Telegram, Email (outgoing)
- LLM: Anthropic, OpenAI, Ollama, OpenRouter

## Evidence and Replay

```bash
kai runs list
kai replay last
```

Every tool call is recorded with inputs, outputs, timings, and policy decisions.

## Core Commands

```bash
kai                         # REPL
kai -c "..."               # Single-shot
kai probe --target local
kai --notify slack:#ops -c "check system health"
kai gateway start|stop|status
```

## Build and Test

```bash
make build
make test
make test-integration
```

## Docs

- [`docs/quickstart.md`](docs/quickstart.md)
- [`docs/skills.md`](docs/skills.md)
- [`docs/targets.md`](docs/targets.md)
- [`docs/channels.md`](docs/channels.md)
- [`docs/config.md`](docs/config.md)
- [`CONTRIBUTING.md`](CONTRIBUTING.md)
