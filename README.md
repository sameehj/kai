# kai — see exactly what your AI agent did

Cursor refactored your auth module. Did it push to main?
Claude ran a script. What did it actually execute?

kai watches your AI agents at the OS level and gives you
a complete replay of every session.

$ kai replay last

  CURSOR SESSION  cs_a3f2  4m 32s

  Modified: src/auth/login.ts      +47 -12
  Deleted:  src/auth/old_login.ts
  Executed: git push origin main   ⚠
  Network:  api.anthropic.com      4 calls

Works with Cursor, Claude Desktop, Codex CLI, GitHub Copilot,
Ollama, LM Studio, and any browser-based AI tool — including Chrome.

No cloud. No account. No kernel modules. All local.

## Install

# macOS
brew install kai-ai/kai/kai

# Linux
curl -sSL https://kai.ai/install | bash

kai daemon start
kai watch
