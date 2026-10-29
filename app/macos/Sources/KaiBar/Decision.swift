// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Experience spec §5: one decision model, opened from a Recent row, an
// Activity row, or an entry on an agent's "What it can reach" page. Options
// follow what Kai knows (no session: no session option; no hostname: only an
// explanation; Kai's own files: always protected). After a choice the sheet
// shows the result in place, with Undo.
import SwiftUI
import KaiCore

struct DecisionSheet: View {
    @EnvironmentObject var model: AppModel
    let event: AuditEvent
    var count = 1
    var showHeader = true
    @ObservedObject var grants: GrantManager
    @ObservedObject private var agents = AgentsModel.shared
    @AppStorage("settingsPage") private var settingsPage = SettingsPage.agentControl.rawValue
    @State private var done: Choice?
    @State private var confirmRule = false
    @State private var showWhy = false

    enum Choice: Equatable { case hour(Date), session, kept, always }

    private var host: String { event.target ?? "" }
    private var sessionLive: Bool {
        guard let s = event.session, !s.isEmpty else { return false }
        return agents.sessions.contains { $0.id == s && $0.isActive }
    }
    private var sessionName: String {
        guard let s = event.session, let row = agents.sessions.first(where: { $0.id == s }) else { return "" }
        let t = row.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        return " · session \u{201C}\(t.isEmpty ? row.projectBase : t)\u{201D}"
    }
    private var whenLine: String {
        var parts = [event.isBlock ? "Blocked" : event.verb]
        if let d = event.date { parts.append(ago(d) == "now" ? "just now" : "\(ago(d)) ago") }
        if count > 1 { parts.append("\(count) attempts") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showHeader {
                Text(event.isNetwork && !event.isUnknownHost
                     ? "\(event.agentName)\(sessionName) tried to reach \(host)" : event.plainSentence)
                    .font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(whenLine).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            if event.isNetwork && event.isBlock && !event.isUnknownHost && !event.isSilent {
                Text(HostCatalog.line(host)).font(.system(size: 12)).foregroundStyle(Theme.soft)
                Text("If you allow it: \(event.agentName) can connect to this host for the time you choose. Kai can't "
                     + "see what is sent over the encrypted connection. Kai doesn't know why this was requested.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let d = done { result(d) } else { options }
            if showWhy {
                VStack(alignment: .leading, spacing: 2) {
                    if !event.rule.isEmpty { Text("Rule: \(event.rule)") }
                    if let i = event.identity { Text("Agent: \(i)") }
                    if let s = event.session, !s.isEmpty { Text("Session: \(String(s.prefix(8)))") }
                    if !event.detail.isEmpty { Text(event.detail) }
                }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
            }
        }
        .confirmationDialog("Always allow \(event.agentName) to reach \(host)?", isPresented: $confirmRule) {
            Button("Always allow") { grants.createRule(grants.request(from: event)); done = .always }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RuleText.covers(agent: event.agentName, identity: event.identity ?? "", host: host))
        }
    }

    @ViewBuilder private var options: some View {
        if event.isBuiltinRule && event.isBlock {
            note(AuditEvent.filesEnforcing
                 ? "Always protected: Kai's own files and the agents' Kai settings can't be allowed."
                 : "Kai's own files and the agents' Kai settings can't be allowed from here.")
        } else if event.isTelemetry {
            Button("Telemetry settings") { settingsPage = SettingsPage.internet.rawValue }.buttonStyle(GhostButtonStyle())
        } else if event.isKeptBlocked, let r = grants.keptBlockedRule(event) {
            Button("Unblock…") { grants.removeRule(r) }.buttonStyle(GhostButtonStyle())
                .help("Kai asks about \(r.dest) again next time instead of blocking it silently.")
        } else if event.isNetwork && event.isBlock && event.isUnknownHost {
            note("Nothing to allow afterwards: Kai never learned which site this was. "
                 + "If the agent needed it, its next try usually names the site.")
        } else if event.isNetwork && event.isBlock && !event.isSilent {
            let signed = event.identity != nil
            // Action-only labels (the title names the agent and the site);
            // stacked full width when they don't fit, never truncated.
            CardActions(actions: (sessionLive ? [CardAction(title: "Allow this session", info: InfoText.thisSession) {
                                      grants.allowForSession(event); done = .session }] : [])
                                 + (signed ? [CardAction(title: "Allow 1 hour", info: InfoText.oneHour) {
                                      grants.allowForHour(grants.request(from: event)); done = .hour(Date().addingTimeInterval(3600)) },
                                    CardAction(title: "Keep blocked") {
                                      grants.keepBlocked(grants.request(from: event)); done = .kept }] : []),
                        more: [CardAction(title: "Always allow (Touch ID)", enabled: signed,
                                          help: signed ? "" : "Kai didn't record which signed agent this was (an older record).") {
                                   confirmRule = true }],
                        moreInfo: InfoText.always,
                        why: (label: showWhy ? "Hide" : "Why?", toggle: { showWhy.toggle() }))
        } else if event.isStorage && event.isBlock, let req = grants.pendingFor(event) {
            ApprovalCard(req: req, manager: grants)
        } else if event.decision == "redact" || event.decision == "replace" {
            Menu("Not a secret") {
                if event.canExemptCommand { Button(event.exemptLabel) { model.exempt(event) } }
                Button("Report a false positive…") { Task { _ = await model.report(event) } }
            }
            .menuStyle(.borderlessButton).fixedSize()
        } else if event.isBlock && event.canExemptCommand {
            Button(event.exemptLabel) { model.exempt(event) }.buttonStyle(GhostButtonStyle())
        }
    }

    /// The result in place, with Undo.
    @ViewBuilder private func result(_ d: Choice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: d == .kept ? "hand.raised" : "checkmark.circle").foregroundStyle(Theme.lime)
            Text(resultText(d)).font(.system(size: 12))
            Spacer()
            Button("Undo") { undo(d) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.lime)
        }
    }

    private func resultText(_ d: Choice) -> String {
        switch d {
        case .hour(let end): return "Allowed for 1 hour · ends \(end.formatted(date: .omitted, time: .shortened))"
        case .session: return "Allowed for this session"
        case .kept: return "Kept blocked · Kai won't ask again"
        case .always:
            return ruleFor(allow: true, temporary: false) == nil ? "Waiting for Touch ID…" : "Always allowed"
        }
    }

    private func ruleFor(allow: Bool, temporary: Bool) -> DecisionRule? {
        grants.rules.last { $0.isAllow == allow && $0.isTemporary == temporary
                            && $0.dest.caseInsensitiveCompare(host) == .orderedSame
                            && (event.identity == nil || $0.identity == event.identity) }
    }

    private func undo(_ d: Choice) {
        switch d {
        case .hour: if let r = ruleFor(allow: true, temporary: true) { grants.removeRule(r) }
        case .always: if let r = ruleFor(allow: true, temporary: false) { grants.removeRule(r) }
        case .kept: if let r = ruleFor(allow: false, temporary: false) { grants.removeRule(r) }
        case .session:
            for g in grants.grants where g.resource == host && g.session_id == event.session { grants.revoke(g) }
        }
        done = nil
    }

    private func note(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Spec §5.2: one list per agent

struct AgentReachView: View {
    @EnvironmentObject var model: AppModel
    let agent: String                 // "claude", "codex", "cursor"
    @ObservedObject var grants: GrantManager
    @State private var open: String?

    private var title: String {
        switch agent { case "claude": "Claude Code"; case "codex": "Codex"; case "cursor": "Cursor"; default: agent }
    }
    private var allowedRules: [DecisionRule] { grants.rules.filter { $0.isAllow && $0.agent == agent } }
    private var keptBlocked: [DecisionRule] { grants.rules.filter { !$0.isAllow && $0.agent == agent } }
    private var sessionGrants: [ActiveGrant] { grants.grants.filter { $0.agent == agent && $0.op == 2 } }
    private var asked: [ReachedHost] {
        let dayAgo = Date().addingTimeInterval(-86400)
        let mine = model.events.filter { $0.isNetwork && $0.agentKey == agent && $0.isBlock && ($0.date ?? .distantPast) > dayAgo }
        return ReachedHost.group(mine, allowed: Set(allowedRules.map(\.dest)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("What \(title) can reach").font(.title3).fontWeight(.semibold)
                // Spec v2.1 B.4: no fixed category switches.
                DisclosureGroup("\(title)'s own model and sign-in connections are allowed so it can work. Everything else is asked about.") {
                    Text("Allowed by \(title)'s profile: this Mac (loopback only) and its model and sign-in hosts"
                         + (agent == "cursor" ? ", including Cursor's sign-in hosts" : "")
                         + ". Data sent to them isn't inspected by the Internet wall. Anything else, such as GitHub "
                         + "or a package registry, gets a card the first time, and you choose for that exact host.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))

                section("Allowed") {
                    if allowedRules.isEmpty && sessionGrants.isEmpty { empty("Nothing beyond the built-ins.") }
                    ForEach(allowedRules) { r in
                        row(r.dest, r.untilLabel) {
                            if (r.migrated ?? 0) == 1 {
                                Button("Keep (Touch ID)") { grants.confirmMigrated(r) }.buttonStyle(GhostButtonStyle())
                            }
                            Button("Remove") { grants.removeRule(r) }.buttonStyle(GhostButtonStyle())
                        }
                    }
                    ForEach(sessionGrants) { g in
                        row(g.resource, g.scopeLabel) { Button("Revoke") { grants.revoke(g) }.buttonStyle(GhostButtonStyle()) }
                    }
                }

                ScreenAppControlSection(agent: agent, title: title)

                section("Blocked (remembered)") {
                    if keptBlocked.isEmpty { empty("None.") }
                    ForEach(keptBlocked) { r in
                        row(r.dest, "kept blocked") { Button("Ask again") { grants.removeRule(r) }.buttonStyle(GhostButtonStyle()) }
                    }
                }

                section("Asked recently", info: InfoText.askedRecently) {
                    let mig = grants.migratedAsks.filter { $0.agent == agent }
                    if asked.isEmpty && mig.isEmpty { empty("Nothing in the last 24 hours.") }
                    ForEach(mig, id: \.self) { m in
                        row(m.host, "From the old \(m.from) switch. \(title) never reached it, so it has no permission; "
                                    + "Kai asks the first time it tries.") {
                            Button("Forget") { grants.forgetMigratedAsk(m) }.buttonStyle(GhostButtonStyle())
                        }
                    }
                    ForEach(asked) { h in
                        VStack(alignment: .leading, spacing: 6) {
                            Button { open = open == h.host ? nil : h.host } label: {
                                row(h.host, "\(h.count) attempt\(h.count == 1 ? "" : "s")\(h.last.map { " · " + ago($0) } ?? "")") {
                                    Image(systemName: open == h.host ? "chevron.up" : "chevron.down").foregroundStyle(Theme.muted)
                                }
                            }.buttonStyle(.plain)
                            if open == h.host, let e = h.latest {
                                DecisionSheet(event: e, count: h.count, showHeader: false, grants: grants)
                                    .padding(.leading, 8)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func section<C: View>(_ t: String, info: String? = nil, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let info { InfoHeading(title: t, info: info) } else { CapsLabel(t) }
            c()
        }
    }
    private func empty(_ t: String) -> some View { Text(t).font(.system(size: 12)).foregroundStyle(Theme.muted) }
    private func row<T: View>(_ main: String, _ sub: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(main).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { trailing() }.fixedSize()   // buttons keep their whole label; the text wraps
        }
        .padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Spec §6: chats

/// AI chat sites the browser extension reports (site only, never a URL).
struct ChatSite: Identifiable {
    let site: String
    let openTabs: Int
    let redactions: Int
    let overrides: Int
    let last: Date
    var id: String { site }
    var redactedToday: Int { Int(kai_daily_site(site)) }

    /// The extension Kai ships vs the version Chrome last reported.
    static var extensionOutdated: Bool {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "browser"),
              let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let want = o["version"] as? String else { return false }
        var buf = [CChar](repeating: 0, count: 32)
        let have = kai_chat_extension_version(&buf, buf.count, nil) == 1 ? String(cString: buf) : ""
        return have != want
    }

    static func load() -> [ChatSite] {
        var ptr: UnsafeMutablePointer<kai_chat>? = nil
        var n: Int32 = 0
        guard kai_chat_load(&ptr, &n) == 0, let ptr else { return [] }
        defer { free(ptr) }
        let halfDay = Date().addingTimeInterval(-12 * 3600)
        return (0..<Int(n)).map { i -> ChatSite in
            var c = ptr[i]
            let site = withUnsafePointer(to: &c.site) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
            return ChatSite(site: site, openTabs: Int(c.open_tabs), redactions: Int(c.redactions),
                            overrides: Int(c.overrides), last: Date(timeIntervalSince1970: TimeInterval(c.last_utc)))
        }
        .map { s in s.last < halfDay ? ChatSite(site: s.site, openTabs: 0, redactions: s.redactions,
                                                 overrides: s.overrides, last: s.last) : s }
        .sorted { $0.site < $1.site }
    }
    static var keptOutToday: Int { Int(kai_daily_count(nil, CChar(UInt8(ascii: "c")))) }
}

struct ChatsDetail: View {
    @EnvironmentObject var model: AppModel
    private var sites: [ChatSite] { ChatSite.load() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) { Text("Chats").font(.title3).fontWeight(.semibold); InfoButton(text: InfoText.chats) }
                if model.chromeNeedsExtension || !model.agentInfo(.chrome).installed || ChatSite.extensionOutdated {
                    Button("Chats: reload the Kai extension in Chrome") { model.openExtensionSetup() }
                        .buttonStyle(.plain).foregroundStyle(Theme.amber)
                }
                HStack(spacing: 4) {
                    Text("AI chat sites the Kai extension reports. No conversation titles are kept.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                if sites.isEmpty { Text("No chat sites seen yet.").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                ForEach(sites) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.site).font(.system(size: 13))
                            Text("\(s.openTabs > 0 ? "\(s.openTabs) tab\(s.openTabs == 1 ? "" : "s") open" : "closed") · "
                                 + "\(s.redactedToday) redacted before sending today")
                                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                    }
                    .padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                Button("Extension settings ›") { model.openExtensionSetup() }.buttonStyle(.plain).foregroundStyle(Theme.lime)
            }
            .padding(16)
        }
    }
}

/// Spec v2.1 B.3: explanation only. Describes the service, never the agent's
/// intent, and never allows anything.
enum HostCatalog {
    /// "GitHub" from "GitHub, where code is hosted…"; the host if unknown.
    static func shortName(_ host: String) -> String {
        var g: UnsafePointer<CChar>? = nil
        guard let d = kai_host_describe(host, &g) else { return host }
        return String(String(cString: d).split(separator: ",").first ?? Substring(host))
    }
    static func line(_ host: String) -> String {
        var g: UnsafePointer<CChar>? = nil
        if let d = kai_host_describe(host, &g) { return String(cString: d) + "." }
        return "An unfamiliar site: \(host)."
    }
}
