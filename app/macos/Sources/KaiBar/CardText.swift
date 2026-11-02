// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Nov 2: card text. "Needs you" requests that would turn protection down, in
// plain words with the real requester (the raw rule behind Details), merged
// when identical; and the plain-text brief each card's copy icon puts on the
// clipboard, ready to paste into an agent. Never secret values or file
// contents: audit records hold only redacted excerpts, and the brief leaves
// even those out. Foundation only (tests/app/cardtext_main.swift).
import Foundation

enum PolicyWords {
    /// What a rule check does, for "stop <...>".
    private static let checks: [String: String] = [
        "file_contents": "checking file contents for secrets",
        "secret": "checking commands for secrets",
        "prompt": "checking your prompts for secrets",
        "prompt_secret": "checking your prompts for secrets",
        "upload": "stopping commands that upload files",
        "curl_upload": "stopping curl and wget uploads",
        "netcat": "stopping netcat connections",
        "remote_scp": "stopping scp copies to other machines",
        "pipe_to_shell": "stopping downloads piped into a shell",
        "protected_path": "protecting your keys and credentials",
    ]
    private static let losses: [String: String] = [
        "file_contents": "Agents could read files that hold secrets (keys, tokens, .env) without Kai checking them.",
        "secret": "Commands carrying secrets would run without Kai checking them.",
        "prompt": "Secrets typed into prompts would reach the model unchecked.",
        "prompt_secret": "Secrets typed into prompts would reach the model unchecked.",
    ]

    /// "add exempt file_contents" -> "Something wants Kai to stop checking file contents for secrets."
    static func plain(_ summary: String) -> String {
        let w = summary.split(separator: " ").map(String.init)
        if w.count >= 3, w[0] == "add", w[1] == "exempt" {
            return "Something wants Kai to stop \(checks[w[2]] ?? "applying one of its checks (\(w[2].replacingOccurrences(of: "_", with: " ")))")."
        }
        if summary.hasPrefix("set egress") { return "Something wants Kai to stop blocking unknown Internet destinations." }
        if summary.hasPrefix("set storage") { return "Something wants Kai to stop protecting files." }
        if w.count >= 3, w[0] == "remove", w[1] == "protect" {
            return "Something wants Kai to stop protecting \(w[2...].joined(separator: " "))."
        }
        if summary.hasPrefix("set on_") { return "Something wants Kai to warn instead of stopping an action." }
        return "Something wants to turn Kai's protection down."
    }

    /// One line: what turning protection down would lose.
    static func loses(_ summary: String) -> String {
        let w = summary.split(separator: " ").map(String.init)
        if w.count >= 3, w[0] == "add", w[1] == "exempt", let l = losses[w[2]] { return l }
        if summary.hasPrefix("set egress") { return "Agents could connect anywhere without Kai asking." }
        if w.count >= 3, w[0] == "remove", w[1] == "protect" { return "Agents could open \(w[2...].joined(separator: " ")) unchecked." }
        return "Kai would check less than it does now."
    }

    /// "kai(5012) <- zsh(5001) <- claude(4990)" -> "Claude Code, using the kai command".
    static func requester(_ chain: String) -> String {
        let names = chain.components(separatedBy: " <- ").compactMap { p -> String? in
            guard let i = p.firstIndex(of: "("), i > p.startIndex else { return nil }
            return String(p[..<i]).trimmingCharacters(in: .whitespaces)
        }
        guard let first = names.first else { return "Unknown requester" }
        let agents: [(String, String)] = [("claude", "Claude Code"), ("codex", "Codex"), ("cursor", "Cursor")]
        let agent = names.dropFirst().lazy.compactMap { n in agents.first { n.lowercased().hasPrefix($0.0) }?.1 }.first
        if first == "Kai" && agent == nil { return "You, in the Kai app" }
        if first == "kai" {
            return agent.map { "\($0), using the kai command" } ?? "You or a program, using the kai command in a terminal"
        }
        if let agent { return agent }
        return "Unknown requester"
    }

    /// Identical requests (same change) merge into one card.
    static func merge(_ items: [(id: String, summary: String)]) -> [(summary: String, ids: [String])] {
        var order: [String] = []
        var ids: [String: [String]] = [:]
        for it in items {
            if ids[it.summary] == nil { order.append(it.summary) }
            ids[it.summary, default: []].append(it.id)
        }
        return order.map { ($0, ids[$0] ?? []) }
    }
}

enum CardText {
    private static let when: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()

    /// The reason in plain words: what follows "...: " up to the advice to the agent.
    static func why(_ detail: String) -> String {
        var d = detail
        if let r = d.range(of: ": ") { d = String(d[r.upperBound...]) }
        for cut in [" Don't retry", " (Kai decision", " If this was intended"] {
            if let r = d.range(of: cut) { d = String(d[..<r.lowerBound]) }
        }
        d = d.trimmingCharacters(in: .whitespaces)
        if d.hasSuffix(".") { d.removeLast() }
        return d
    }

    /// The brief a card's copy icon copies. No secret values, no file contents.
    static func brief(_ e: AuditEvent, sessionName: String?) -> String {
        var happened = e.plainSentence
        for cut in [" Don't retry", " (Kai decision"] { if let r = happened.range(of: cut) { happened = String(happened[..<r.lowerBound]) } }
        let whereParts = [e.agentName, sessionName ?? "", e.cwd ?? ""].filter { !$0.isEmpty }
        let todo = e.isNetwork && e.isBlock ? "allow it for this task in Kai, or keep it blocked"
                 : e.isBlock || e.decision == "ask" ? "allow it in Kai if it was intended, or keep it blocked"
                 : "nothing is needed"
        var lines = ["What happened: \(happened)", "Where: \(whereParts.joined(separator: " · "))"]
        let w = why(e.detail)
        if !w.isEmpty { lines.append("Why: \(w)") }
        let t = e.date.map { when.string(from: $0) } ?? e.ts
        lines.append("Decision ID: \(e.decision_id ?? "none") · \(t)")
        lines.append("What you can do: \(todo)")
        // belt and braces: a redaction marker never leaves Kai
        return lines.filter { !$0.contains("REDACTED") }.joined(separator: "\n")
    }

    /// The brief for a protection-lowering request.
    static func policyBrief(summary: String, chain: String, team: String) -> String {
        ["What happened: \(PolicyWords.plain(summary))",
         "Requested by: \(PolicyWords.requester(chain))",
         "If you turn protection down: \(PolicyWords.loses(summary))",
         "Details: \(summary) (caller \(chain.isEmpty ? "unknown" : chain), signed \(team.isEmpty ? "unknown" : team))",
         "What you can do: keep protection (recommended), or turn it down in Kai"].joined(separator: "\n")
    }
}
