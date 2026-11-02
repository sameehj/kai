// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// Nov 2: "Needs you" cards in plain words, with the real requester, merged;
// and the plain-text brief every card's copy icon puts on the clipboard.
// Compiled with AuditLog.swift and CardText.swift.
import Foundation

var fails = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { fails += 1 }
}
func ev(_ json: String) -> AuditEvent { try! JSONDecoder().decode(AuditEvent.self, from: Data(json.utf8)) }

print("protection-lowering requests in plain words")
check(PolicyWords.plain("add exempt file_contents") == "Something wants Kai to stop checking file contents for secrets.",
      "add exempt file_contents: '\(PolicyWords.plain("add exempt file_contents"))'")
check(PolicyWords.plain("set egress block->log").contains("stop blocking"), "set egress block->log in words")
check(PolicyWords.plain("remove protect ~/.ssh").contains("~/.ssh"), "remove protect names what it stops protecting")
check(!PolicyWords.plain("add exempt file_contents").contains("exempt"), "the raw rule isn't in the plain sentence")
check(PolicyWords.loses("add exempt file_contents").contains("secrets"), "one line says what turning protection down loses")
check(PolicyWords.requester("Kai(42029) <- launchd(1)") == "You, in the Kai app",
      "the app itself: 'You, in the Kai app' (\(PolicyWords.requester("Kai(42029) <- launchd(1)")))")
check(PolicyWords.requester("kai(5012) <- zsh(5001) <- claude(4990) <- iTerm2(300)") == "Claude Code, using the kai command",
      "an agent running kai: 'Claude Code, using the kai command'")
check(PolicyWords.requester("kai(77) <- zsh(70) <- launchd(1)") == "You or a program, using the kai command in a terminal",
      "kai from a terminal with no agent above it")
check(PolicyWords.requester("") == "Unknown requester" && PolicyWords.requester("???") == "Unknown requester", "unknown: 'Unknown requester'")
let groups = PolicyWords.merge([("a", "add exempt file_contents"), ("b", "add exempt file_contents"), ("c", "set egress block->log")])
check(groups.count == 2 && groups[0].ids == ["a", "b"], "identical requests merge into one card with a count")

print("copy brief")
let deny = ev(#"{"ts":"2026-11-02T12:39:23Z","source":"claude","event":"PreToolUse","decision":"block","rule":".env","detail":"Kai stopped reading `/p/proj/.env`: it usually holds passwords and keys. Don't retry another way; ask the user.","h":"x1","tool":"Read","target":"/p/proj/.env","cwd":"/p/proj","decision_id":"k-58f44b0b"}"#)
let b = CardText.brief(deny, sessionName: "proj · Terminal tab 1")
check(b.contains("What happened: "), "has What happened")
check(b.contains("Where: Claude Code · proj · Terminal tab 1 · /p/proj"), "Where: agent, session, project folder (\(b.split(separator: "\n").dropFirst().first ?? ""))")
check(b.contains("Why: it usually holds passwords and keys"), "Why: in plain words")
check(b.contains("Decision ID: k-58f44b0b · "), "Decision ID and time")
check(b.contains("What you can do: "), "What you can do")
let secretish = ev(#"{"ts":"2026-11-02T12:40:52Z","source":"claude","event":"PreToolUse","decision":"block","rule":"file_contents","detail":"Kai stopped sending tests/x.sh to the model: it holds secret:github_token x1 (redact).","h":"x2","tool":"Read","target":"[REDACTED by Kai: github_token]","cwd":"/p","decision_id":"k-e480d44d"}"#)
let b2 = CardText.brief(secretish, sessionName: nil)
check(!b2.contains("ghp_") && !b2.contains("REDACTED"), "never secret values (nor redaction markers) in the brief")

print("plain words for older records (Nov 2)")
let oldPrompt = ev(#"{"ts":"2026-11-02T19:16:25Z","source":"claude","event":"UserPromptSubmit","decision":"block","rule":"prompt_secret","detail":"secret:generic_secret_assign x1 (redact)","h":"x3","target":"(prompt, 300 characters - not kept)","decision_id":"k-94b07c6f"}"#)
check(oldPrompt.detail == "Prompt blocked: it contained a password-like secret. Claude Code can't redact prompts, so Kai blocked it.",
      "an old blocked prompt reads what happened: '\(oldPrompt.detail)'")
let oldCursor = ev(#"{"ts":"2026-11-02T19:16:25Z","source":"cursor","event":"beforeSubmitPrompt","decision":"block","rule":"prompt","detail":"secret:aws_access_key x1 (redact), secret:password_assign x2 (redact)","h":"x4"}"#)
check(oldCursor.detail == "Prompt blocked: it contained an AWS access key and a password. Cursor can't redact prompts, so Kai blocked it.",
      "two findings, Cursor: '\(oldCursor.detail)'")
check(secretish.detail == "Kai stopped sending tests/x.sh to the model: it holds a GitHub token.",
      "rule ids inside a sentence become words: '\(secretish.detail)'")
let custom = ev(#"{"ts":"2026-11-02T19:16:25Z","source":"claude","event":"PreToolUse","decision":"block","rule":"mcp_arguments","detail":"secret:acme_badge x1 (block)","h":"x5"}"#)
check(!custom.detail.contains("(block)") && !custom.detail.contains("secret:") && custom.detail.contains("acme_badge"),
      "a user's own rule is named, without the id syntax: '\(custom.detail)'")
for e in [oldPrompt, oldCursor, secretish, custom] {
    check(!e.detail.contains("(redact)") && !e.detail.contains("_assign"), "no '(redact)' or rule id shown (\(e.h))")
    check(!CardText.brief(e, sessionName: nil).contains("(redact)"), "nor in the copied brief (\(e.h))")
}
let plainNet = ev(#"{"ts":"2026-11-02T19:16:25Z","source":"network","event":"claude","decision":"log","rule":"","detail":"connection to example.org is not on the allowlist","h":"x6"}"#)
check(plainNet.detail == "connection to example.org is not on the allowlist", "other details are unchanged")

print(fails == 0 ? "card text tests: all passed" : "card text tests: \(fails) failed")
exit(fails == 0 ? 0 : 1)
