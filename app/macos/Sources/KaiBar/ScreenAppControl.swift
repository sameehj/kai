// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Release batch 16: "Screen and app control" on each agent's page. With the
// app installed, the app is the one writer of these allows (`kai
// allow-capture` answers "Change this in Kai"). Per app: allowing Safari
// doesn't allow Terminal or screencapture. Stored with Kai's other per-agent
// allows (agent-rules.json, op "capture"), which the hooks read.
import SwiftUI
import KaiCore

struct CaptureGrant: Identifiable, Equatable {
    let app: String       // as stored: lowercased
    let until: Date?
    var id: String { app }
    var untilLabel: String { until.map { "until " + $0.formatted(date: .omitted, time: .shortened) } ?? "until removed" }

    /// This agent's live capture allows.
    static func load(agent: String) -> [CaptureGrant] {
        let path = String(cString: kai_home()) + "/agent-rules.json"
        guard let d = FileManager.default.contents(atPath: path),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        let now = Date().timeIntervalSince1970
        return arr.compactMap { r in
            guard r["kind"] as? String == "allow", r["op"] as? String == "capture", r["agent"] as? String == agent,
                  let t = r["target"] as? String else { return nil }
            let u = (r["until"] as? Double) ?? 0
            if u > 0 && u <= now { return nil }
            return CaptureGrant(app: t, until: u > 0 ? Date(timeIntervalSince1970: u) : nil)
        }.sorted { $0.app < $1.app }
    }
}

struct ScreenAppControlSection: View {
    @EnvironmentObject var model: AppModel
    let agent: String, title: String
    @State private var allowed: [CaptureGrant] = []

    private static let rules: Set<String> = ["screen_app_control", "terminal_control"]
    private static let durations: [(String, TimeInterval)] = [("15 minutes", 900), ("1 hour", 3600), ("1 day", 86400)]

    /// Apps this agent was stopped from using in the last day, not allowed since.
    private var asked: [(app: String, count: Int, last: Date?)] {
        let dayAgo = Date().addingTimeInterval(-86400)
        let have = Set(allowed.map(\.app))
        var byApp: [String: (app: String, count: Int, last: Date?)] = [:]
        for e in model.events where e.agentKey == agent && e.isBlock && Self.rules.contains(e.rule)
                                   && (e.date ?? .distantPast) > dayAgo {
            guard let app = e.match, !app.isEmpty, !have.contains(app.lowercased()) else { continue }
            let k = app.lowercased()
            let prev = byApp[k]
            byApp[k] = (prev?.app ?? app, (prev?.count ?? 0) + 1, max(prev?.last ?? .distantPast, e.date ?? .distantPast))
        }
        return byApp.values.sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InfoHeading(title: "Screen and app control", info: InfoText.screenAppControl)
            if allowed.isEmpty && asked.isEmpty { muted("Nothing asked recently. Kai asks per app the first time \(title) tries.") }
            ForEach(allowed) { g in
                row(g.app, "allowed · \(g.untilLabel)") {
                    Button("Remove") { remove(g.app) }.buttonStyle(GhostButtonStyle())
                }
            }
            ForEach(asked, id: \.app) { a in
                row(a.app, "\(a.count) attempt\(a.count == 1 ? "" : "s")\(a.last.map { " · " + ago($0) } ?? "")") {
                    // Terminals and System Events run anything outside Kai's
                    // checks: 15 minutes at most, owner authentication every time.
                    let terminal = kai_capture_app_is_terminal(a.app) != 0
                    Menu {
                        ForEach(terminal ? [("15 minutes (Touch ID)", 900.0)] : Self.durations, id: \.0) { d in
                            Button("Allow \(d.0)") { allow(a.app, for: d.1, authenticate: terminal) }
                        }
                    } label: { Text("Allow ▾").font(.system(size: 13, weight: .medium)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .padding(.horizontal, 12).frame(minHeight: 32)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.border))
                }
            }
        }
        .onAppear { allowed = CaptureGrant.load(agent: agent) }
    }

    private func allow(_ app: String, for secs: TimeInterval, authenticate: Bool) {
        guard authenticate else { grant(app, for: secs); return }
        Task {
            let ok = await OwnerAuth.shared.confirm("allow \(title) to control \(app) for 15 minutes. Commands it runs "
                                                    + "there aren't checked by Kai", everyTime: true)
            if ok { await MainActor.run { grant(app, for: min(secs, TimeInterval(KAI_TERMINAL_ALLOW_MAX))) } }
        }
    }

    private func grant(_ app: String, for secs: TimeInterval) {
        let until = Int64(Date().timeIntervalSince1970 + secs)
        if kai_cli_grant_add(1, "capture", agent, app, nil, until, nil, nil, 0) == 0 {
            kai_audit("app", "allow-capture", "note", "screen_app_control",
                      "allowed \(agent) to use or control \(app) until \(until) (Kai app)")
        }
        allowed = CaptureGrant.load(agent: agent)
    }

    private func remove(_ app: String) {
        if kai_cli_grant_remove("capture", agent, app) == 0 {
            kai_audit("app", "revoke-capture", "note", "screen_app_control", "removed \(agent)'s allow for \(app) (Kai app)")
        }
        allowed = CaptureGrant.load(agent: agent)
    }

    private func muted(_ t: String) -> some View {
        Text(t).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
    }
    private func row<T: View>(_ main: String, _ sub: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(main).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { trailing() }.fixedSize()
        }
        .padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}
