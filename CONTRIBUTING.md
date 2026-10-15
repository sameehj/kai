# Contributing

## Setup

```bash
git clone <repo>
cd kai
make build
make test
```

## Development Guidelines

- Keep the tool model at 5 primitives: `exec`, `read`, `write`, `search`, `report`.
- Add domain behavior through `skills/*/SKILL.md` and `metadata.yaml`.
- Preserve policy and evidence logging behavior for every operation.

## Tests

```bash
make test
make test-integration
```

Integration tests require environment setup (API keys/demo stack).

## Pull Requests

- Keep changes focused.
- Include tests for behavior changes.
- Update docs when command/config/skill behavior changes.
