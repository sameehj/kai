// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import AppKit
import Foundation
import ServiceManagement
import UserNotifications

enum Agent: String, CaseIterable, Identifiable {
    case claude, cursor, codex, chrome
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .chrome: return "Chrome AI chats"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: KaiStatus?
    @Published private(set) var policy: PolicyInfo?
    @Published private(set) var events: [AuditEvent] = []
    @Published private(set) var busy = false
    @Published private(set) var lastBlockAt: Date?
    @Published var errorMessage: String?
    /// A short confirmation ("Exception added …"), shown on the Activity page.
    @Published var notice: String?
    @Published var notifyOnBlock: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnBlock, forKey: "notifyOnBlock")
            // Ask for notification permission when it's turned on, not at launch.
            if notifyOnBlock { Notifier.requestPermission() }
        }
    }

    let cliPath = KaiCLI.executable?.path
    private var tail: AuditTail?
    private var timer: Timer?
    private var ticks = 0
    /// When each agent+rule last notified: repeats within 10 minutes stay quiet.
    private var lastNotified: [String: Date] = [:]

    init() {
        notifyOnBlock = UserDefaults.standard.object(forKey: "notifyOnBlock") as? Bool ?? true
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    // MARK: derived state

    enum Health { case unknown, protecting, partial, off, problem }

    var health: Health {
        guard let s = status else { return cliPath == nil ? .problem : .unknown }
        if !s.policy.ok || !s.audit.intact { return .problem }
        let infos = Agent.allCases.map(agentInfo)
        if infos.contains(where: \.broken) { return .problem }
        if !infos.contains(where: \.installed) { return .off }
        // Only "partial" if an agent that is actually used here is unprotected.
        let missed = infos.contains { $0.detected && !$0.installed } || chromeNeedsExtension
        return missed ? .partial : .protecting
    }

    var menuBarSymbol: String {
        if let t = lastBlockAt, Date().timeIntervalSince(t) < 30 { return "xmark.shield.fill" }
        switch health {
        case .protecting: return "checkmark.shield"
        case .partial: return "shield.lefthalf.filled"
        case .off: return "shield.slash"
        case .problem: return "exclamationmark.shield"
        case .unknown: return "shield"
        }
    }

    var headline: String {
        switch health {
        case .protecting:
            let names = Agent.allCases.filter { installed($0) }.map(\.title)
            return "Protecting " + (ListFormatter.localizedString(byJoining: names))
        case .partial: return "Partly protected"
        case .off: return "Not protecting any agent"
        case .unknown: return "Checking…"
        case .problem:
            if cliPath == nil { return "kai command-line tool not found" }
            if let s = status, !s.policy.ok { return "Policy error: agents are blocked" }
            if let a = brokenAgents.first { return "\(a.title) isn't protected right now" }
            return "Audit log was modified"
        }
    }

    var detailLine: String? {
        guard let s = status else { return nil }
        if !s.policy.ok { return s.policy.error }
        if let a = brokenAgents.first { return agentInfo(a).problem }
        if !s.audit.intact { return s.audit.error }
        if health == .partial {
            let missed = Agent.allCases.filter { agentInfo($0).detected && !installed($0) }.map(\.title)
            return missed.joined(separator: ", ") + " is not protected"
        }
        return nil
    }

    func installed(_ a: Agent) -> Bool { agentInfo(a).installed }

    /// Integrations that are switched on but failed their live check.
    var brokenAgents: [Agent] { Agent.allCases.filter { agentInfo($0).broken } }

    /// Kai is registered with the browser but the extension isn't loaded yet.
    var chromeNeedsExtension: Bool {
        let c = agentInfo(.chrome)
        return c.installed && c.extensionLoaded == false
    }

    /// Finish the browser setup: copy the extension folder's path, show it in
    /// Finder and open the browser's extensions page ("Load unpacked").
    func openExtensionSetup() {
        let dir = agentInfo(.chrome).config
        guard !dir.isEmpty else {
            errorMessage = "Can't find Kai's browser extension folder."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dir, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Google Chrome", "chrome://extensions"]
        try? p.run()
    }

    func agentInfo(_ a: Agent) -> KaiStatus.Agent {
        let none = KaiStatus.Agent(installed: false, detected: false, config: "")
        guard let s = status else { return none }
        switch a {
        case .claude: return s.claude
        case .cursor: return s.cursor
        case .codex: return s.codex ?? none // older kai CLIs don't report Codex
        case .chrome: return s.chrome ?? none
        }
    }

    var todayCounts: (blocked: Int, warned: Int) {
        let cal = Calendar.current
        let today = events.filter { !$0.isNote && !$0.isExempt && ($0.date.map(cal.isDateInToday) ?? false) }
        let blocked = today.filter(\.isBlock).count
        return (blocked, today.count - blocked)
    }

    // MARK: refresh

    func refresh() async {
        async let s = KaiCLI.decode(KaiStatus.self, ["status", "--json"])
        async let p = KaiCLI.decode(PolicyInfo.self, ["policy", "show", "--json"])
        let (newStatus, newPolicy) = await (s, p)
        if newStatus != status { status = newStatus }
        if newPolicy != policy { policy = newPolicy }
        if let path = newStatus?.audit.path, tail == nil {
            tail = AuditTail(path: path)
            pollAudit()
        }
        if let s = newStatus { await reapplyIntegrationsIfUpdated(s) }
    }

    /// After Kai is updated, re-run setup for every agent that's turned on, so
    /// new protections (hook matchers, the browser extension copy) take effect
    /// without the user flipping switches. Setup is idempotent.
    private var reappliedThisLaunch = false
    private func reapplyIntegrationsIfUpdated(_ s: KaiStatus) async {
        guard !reappliedThisLaunch else { return }
        reappliedThisLaunch = true
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + "/" + s.version
        let key = "integrationsAppliedFor"
        guard UserDefaults.standard.string(forKey: key) != build else { return }
        for agent in Agent.allCases where agentInfo(agent).installed {
            _ = await KaiCLI.run(["install", agent.rawValue])
        }
        UserDefaults.standard.set(build, forKey: key)
    }

    private func tick() {
        pollAudit()
        ticks += 1
        // The CLI is cheap but not free: check full status every 10 seconds.
        if ticks % 5 == 0 { Task { await refresh() } }
        // Let the menu-bar icon fall back after a block.
        if let t = lastBlockAt, Date().timeIntervalSince(t) > 30 { lastBlockAt = nil }
    }

    private func pollAudit() {
        guard let tail else { return }
        let fresh = tail.poll()
        if tail.recent != events { events = tail.recent }
        let blocks = fresh.filter(\.isBlock)
        if !blocks.isEmpty {
            lastBlockAt = Date()
            if notifyOnBlock { notify(blocks) }
        }
    }

    /// One notification per agent and rule, however many blocks arrived, and
    /// none for a rule that already notified in the last 10 minutes: an agent
    /// retrying the same thing shouldn't turn into a stream of banners.
    private func notify(_ blocks: [AuditEvent]) {
        var groups: [String: [AuditEvent]] = [:]
        var order: [String] = []
        for e in blocks {
            let key = e.agentName + "|" + e.rule
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(e)
        }
        let now = Date()
        for key in order {
            if let t = lastNotified[key], now.timeIntervalSince(t) < 600 { continue }
            lastNotified[key] = now
            let g = groups[key]!
            Notifier.post(g.last!, count: g.count)
        }
    }

    // MARK: activity

    /// The "After the block, the agent ..." note for a block: the next
    /// record from the same session, if that is a note about the same rule.
    func followUp(for e: AuditEvent) -> AuditEvent? {
        guard e.isBlock, let s = e.session, !s.isEmpty, let i = events.firstIndex(of: e) else { return nil }
        // events are newest first, so what came after e is at lower indices
        for k in stride(from: i - 1, through: 0, by: -1) where events[k].session == s {
            let n = events[k]
            return n.isNote && n.rule == e.rule ? n : nil
        }
        return nil
    }

    /// "Not a threat": an exception for exactly this command and rule.
    func exempt(_ e: AuditEvent) {
        guard e.canExemptCommand, let pattern = e.exemptPattern else { return }
        Task {
            errorMessage = nil
            await perform(["policy", "add", "exempt", e.rule, pattern])
            if errorMessage == nil { notice = "Exception added: \(e.rule) won't block this command again." }
        }
    }

    /// "Not a threat": always let agents read this file.
    func allowFile(_ e: AuditEvent) {
        guard let path = e.allowablePath else { return }
        // A protected path is lifted with "allow"; a file stopped for what it
        // holds gets an exception for that check only, on its full path.
        let contents = e.rule == "file_contents"
        let args = contents
            ? ["policy", "add", "exempt", "file_contents", (path as NSString).expandingTildeInPath]
            : ["policy", "add", "allow", path]
        Task {
            errorMessage = nil
            await perform(args)
            if errorMessage == nil {
                notice = contents ? "Agents may now read \(path), whatever it holds." : "\(path) is now allowed."
            }
        }
    }

    func removeExempt(_ x: PolicyInfo.Exempt) {
        Task { await perform(["policy", "remove", "exempt", x.rule, x.pattern]) }
    }

    /// Write a false-positive report (nothing is sent). Returns where it is
    /// and a prefilled GitHub issue link the user can open and review.
    func report(_ e: AuditEvent) async -> ReportInfo? {
        let r = await KaiCLI.run(["report", e.id, "--json"])
        guard r.ok else { errorMessage = r.message; return nil }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try? d.decode(ReportInfo.self, from: Data(r.out.utf8))
    }

    func copyDetails(_ e: AuditEvent) {
        var lines = ["\(e.verb) \(e.agentName)\(e.actionLabel.map { " · \($0)" } ?? "")", "Reason: \(e.detail)"]
        if !e.rule.isEmpty { lines.append("Rule: \(e.rule)") }
        if let t = e.excerpt { lines.append("What: \(t)") }
        if let n = followUp(for: e) { lines.append("Then: \(n.detail)") }
        lines.append("When: \(e.ts) · id \(e.id.prefix(10))")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: actions

    private func perform(_ args: [String]) async {
        busy = true
        defer { busy = false }
        let r = await KaiCLI.run(args)
        if !r.ok { errorMessage = r.message }
        await refresh()
    }

    func setAgent(_ a: Agent, enabled: Bool) {
        Task { await perform([enabled ? "install" : "uninstall", a.rawValue]) }
    }

    func setSwitch(_ key: String, _ value: String) {
        guard policy?.switches[key] != value else { return }
        Task { await perform(["policy", "set", key, value]) }
    }

    func add(_ kind: String, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        Task { await perform(["policy", "add", kind, v]) }
    }

    func remove(_ kind: String, _ value: String) {
        Task { await perform(["policy", "remove", kind, value]) }
    }

    func addTerm(text: String, action: String, replacement: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let act = action == "replace" ? "replace:\"\(replacement)\"" : action
        Task { await perform(["policy", "add", "term", act, t]) }
    }

    func openPolicyFile() {
        Task {
            if status?.policy.fileExists != true { _ = await KaiCLI.run(["init"]) }
            await refresh()
            guard let file = status?.policy.file else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: file))
        }
    }

    func revealAuditLog() {
        guard let path = status?.audit.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func verifyAuditLog() async -> String {
        let r = await KaiCLI.run(["log", "verify"])
        await refresh()
        return r.out.isEmpty ? r.message : r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                errorMessage = "Launch at login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}

enum Notifier {
    /// Notifications need a real app bundle; running the bare binary skips them.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// count > 1: several blocks of the same rule arrived together.
    static func post(_ e: AuditEvent, count: Int = 1) {
        guard available else { return }
        let c = UNMutableNotificationContent()
        c.title = "Kai blocked \(e.agentName)" + (count > 1 ? " \(count) times" : "")
        var body = e.detail.isEmpty ? e.rule : e.detail
        if let t = e.excerpt { body += "\n" + (t.split(separator: "\n").first.map(String.init) ?? t) }
        c.body = body
        c.sound = .default
        let req = UNNotificationRequest(identifier: e.id, content: c, trigger: nil)
        // Asking is a no-op once the user has answered; the first block asks.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { UNUserNotificationCenter.current().add(req) }
        }
    }
}
