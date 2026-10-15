# Kai Implementation Plan

## Phase 2 (Completed)
- [x] Onboarding wizard + first-run trigger
- [x] Policy danger classifier + exec safety hardening
- [x] Agent loop wiring with evidence and report notifications
- [x] Demo environment + integration tests
- [x] Repo cleanup to 5 primitive tools

## MVP Pass (In Progress)
- [x] Community skill directory support (`~/.kai/community-skills`)
- [x] `kai skill add|list|remove|update` CLI surface
- [x] Self-management prompt guidance for in-chat skill management
- [x] Hot-reload skills after community `SKILL.md`/`metadata.yaml` writes
- [x] Added built-in skills: env-setup, build-debug, watch, server-audit, ebpf-dev, kernel-dev
- [x] Target context prefix in responses
- [x] README/docs/config/contributing refresh
- [x] Packaging files refreshed (`Makefile`, `.goreleaser.yaml`, `install.sh`)

## MVP Remaining (Not Completed In Code Yet)
- [ ] Slack incoming Socket Mode listener and thread replies
- [ ] Telegram incoming listener with allowed-user enforcement
- [ ] Multi-target execution parameter in `exec` tool
- [ ] Demo recordings and launch collateral (HN/Reddit drafts, website updates)

## Verification State
- [x] `go test ./...`
- [x] `go build -o bin/kai ./cmd/kai`
