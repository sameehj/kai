# Skill Creation Guide

Skills are documented workflows stored as `skills/<name>/SKILL.md`.

## Format

```markdown
---
name: my-skill
description: One-line summary
---

# My Skill

## When to use
- When X happens

## How to use
```bash
exec {"command": "..."}
read {"path": "..."}
write {"path": "...", "content": "..."}
```
```

## Guidelines
- Keep steps explicit and safe
- Prefer primitives over complex scripts
- Document platform-specific differences
