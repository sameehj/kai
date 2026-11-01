#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# make release builds only from a clean tree on the tag: a dirty tree is refused
# before anything is built, and src/kai_commit.h (generated at build time) is
# never tracked, so building can't dirty the tree.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
command -v git >/dev/null 2>&1 && [ -d "$ROOT/.git" ] || [ -f "$ROOT/.git" ] || { echo "release guard tests: skipped (no git checkout)"; exit 0; }

echo "release guard: clean tree on the tag"
git -C "$ROOT" ls-files --error-unmatch src/kai_commit.h >/dev/null 2>&1 \
    && fail "src/kai_commit.h is tracked (it changes with every commit and would dirty the tree)" \
    || pass "src/kai_commit.h is not tracked (generated at build time)"
git -C "$ROOT" check-ignore -q src/kai_commit.h && pass "...and ignored" || fail "src/kai_commit.h isn't ignored"

git clone -q "$ROOT" "$T/c" 2>/dev/null || { fail "clone"; exit 1; }
echo "// local edit" >> "$T/c/README.md"
out=$(cd "$T/c" && KAI_TEAM=X KAI_DEVID_APP=x KAI_DEVID_INSTALLER=x KAI_APP_PROFILE=x KAI_EXT_PROFILE=x \
      KAI_NOTARY_PROFILE=x sh scripts/release/build-preview-pkg.sh 0.0.0 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "clean tree" && pass "a dirty tree is refused before building (exit $rc)" \
    || fail "dirty tree not refused: exit $rc, $out"
[ ! -d "$T/c/build/release" ] && pass "...and nothing was built" || fail "a dirty tree still produced build output"
grep -qF 'commit $(git rev-parse --short=12 HEAD)$' "$ROOT/scripts/release/build-preview-pkg.sh" \
    && pass "the release kai must name the exact commit (no -dirty)" || fail "no exact-commit check on the release kai"
grep -q 'bundled kai in Kai.app' "$ROOT/scripts/release/build-preview-pkg.sh" \
    && pass "the kai inside Kai.app is checked the same way" || fail "the app's bundled kai isn't checked"
grep -q 'the tree is dirty after the build' "$ROOT/scripts/release/build-preview-pkg.sh" \
    && pass "the tree is checked again after the build" || fail "no clean-tree check after the build"

rm -rf "$T"
[ $fails -eq 0 ] && echo "release guard tests: all passed" || echo "release guard tests: $fails failed"
exit $fails
