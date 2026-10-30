#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
#
# S8 acceptance fixtures (synthetic only — NEVER real secrets). Run this
# YOURSELF, not through an agent: the storage wall blocks agent writes to
# key-class and secret paths, which is the point.
#
#   sh scripts/s8-setup.sh ~/kai-s8
#
# Creates: project A (website, with an .mcp.json for the Oct-22 MCP server),
# project B, a Codex sandbox C, a confirm-tier file, and a break-glass fixture
# with FAKE content.
set -eu
ROOT="${1:?usage: s8-setup.sh <workdir>}"
mkdir -p "$ROOT"

# Project A — website, with the MCP server whose declared host is the Oct-22 one.
mkdir -p "$ROOT/projectA"
cat > "$ROOT/projectA/.mcp.json" <<'JSON'
{ "mcpServers": { "site": { "url": "https://innermonkeylabs.com/mcp" } } }
JSON
printf '# Website project (S8 session A)\n' > "$ROOT/projectA/README.md"
( cd "$ROOT/projectA" && git init -q 2>/dev/null || true )

# Project B — any second repo (S8 session B).
mkdir -p "$ROOT/projectB"
printf '# Second repo (S8 session B)\n' > "$ROOT/projectB/README.md"
( cd "$ROOT/projectB" && git init -q 2>/dev/null || true )

# Sandbox C — Codex, isolated KAI_HOME so it can't touch the real one.
mkdir -p "$ROOT/sandboxC/home"
printf 'Run Codex here with: KAI_HOME="%s/sandboxC/home"\n' "$ROOT" > "$ROOT/sandboxC/HOWTO.txt"

# Confirm-tier file (project secret class) — FAKE value.
cat > "$ROOT/projectA/.env" <<'ENV'
# SYNTHETIC — not a real secret. Confirm-tier in S8 step 5.
API_TOKEN=fake-token-do-not-use-0000000000000000
ENV

# Break-glass fixture — key-class name, FAKE content. (If the wall blocks even
# you from writing this, you are inside an agent tree; open a plain Terminal.)
# assembled here so this script holds no key-shaped text (Kai scans its own tree)
K5="-----"; KT="OPENSSH PRIVATE KEY"
printf '%sBEGIN %s%s\nTHIS IS A SYNTHETIC TEST FIXTURE. NOT A REAL KEY. DO NOT USE.\n%sEND %s%s\n' "$K5" "$KT" "$K5" "$K5" "$KT" "$K5" > "$ROOT/id_test"
chmod 600 "$ROOT/id_test" 2>/dev/null || true

echo "S8 fixtures ready under $ROOT"
echo "  A: $ROOT/projectA (.mcp.json -> innermonkeylabs.com, .env confirm-tier)"
echo "  B: $ROOT/projectB"
echo "  C: $ROOT/sandboxC (KAI_HOME=$ROOT/sandboxC/home)"
echo "  break-glass fixture: $ROOT/id_test (synthetic)"
