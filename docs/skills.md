# Skills

Built-in skills live in `skills/<name>/`.

Community skills live in `~/.kai/community-skills/<name>/` and can be added with:

```bash
kai skill add <github-url>
```

Each skill includes:

- `metadata.yaml`
- `SKILL.md`

`metadata.yaml` declares requirements and command patterns.
`SKILL.md` holds the operational playbook used by the agent.
