# KAI Skills System

## What are Skills?

Skills are instruction manuals for KAI that teach it how to use tools
for specific tasks. They don't add new tools; they guide the agent to
combine existing tools (especially `exec`) to accomplish workflows.

## Skill Locations

Skills can live in two places:

1. Bundled skills: `skills/` in the repo
2. User skills: `~/.kai/skills/`

User skills override bundled skills with the same name.

## Creating a Skill

1. Create a directory: `~/.kai/skills/my-skill/`
2. Create `SKILL.md` with frontmatter:

```markdown
---
name: my-skill
description: What this skill does
requires:
  bins: [required-binary]
  env: [REQUIRED_ENV_VAR]
---

# Skill Content

Instructions for the AI on how to use this skill...

## Examples

User: "example request"
→ exec: example command
```

3. Skills are discovered on next run.

## Best Practices

- Keep skills focused on one domain.
- Provide clear examples.
- Include prerequisites and error handling.
- Test commands before documenting them.
