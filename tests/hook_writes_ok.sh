#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# Can this shell write an agent's hook settings in a throwaway HOME? Not when
# the suite runs inside an agent with Files protection on: Kai (correctly)
# blocks agents from writing any .claude/settings.json, even a temp one. Then
# the cases that need it are skipped ("needs a non-agent shell"), never
# failed; CI and a plain Terminal run everything. Exit 0 = writable.
T="$(mktemp -d)" || exit 1
mkdir -p "$T/.claude"
if ( : > "$T/.claude/settings.json" ) 2>/dev/null; then ok=0; else ok=1; fi
rm -rf "$T" 2>/dev/null
exit "$ok"
