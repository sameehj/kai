// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import AppKit
import SwiftUI
import KaiCore

/// 0.4: the Settings page of the Kai window: General (activity recording, Ask
/// Kai's model), the pages named for what they protect - Files, Internet - and
/// Advanced for everything technical.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, files, internet, advanced, uninstall
    var id: String { rawValue }
    /// A page saved by an older Kai ("storage", "network", "agentControl", ...).
    init(stored raw: String) {
        switch raw {
        case "storage": self = .files
        case "network": self = .internet
        case "protection", "permissions", "company": self = .advanced
        default: self = SettingsPage(rawValue: raw) ?? .general
        }
    }
    var title: String {
        switch self {
        case .general: return "General"
        case .files: return "Files"
        case .internet: return "Internet"
        case .advanced: return "Advanced"
        case .uninstall: return "Uninstall"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .files: return "folder"
        case .internet: return "globe"
        case .advanced: return "slider.horizontal.3"
        case .uninstall: return "trash"
        }
    }
}

/// 0.4: Settings is a page of the Kai window (pinned at the bottom of its
/// sidebar), with its own sub-pages along the top.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wall: NetworkWall
    @EnvironmentObject var storage: StorageWall
    @AppStorage("settingsPage") private var pageRaw = SettingsPage.general.rawValue
    private var page: SettingsPage { SettingsPage(stored: pageRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: Binding(get: { page }, set: { pageRaw = $0.rawValue })) {
                ForEach(SettingsPage.allCases) { p in Text(p.title).tag(p) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)
            .padding(.horizontal, 28).padding(.top, 20)
            if let msg = model.errorMessage {
                ErrorBanner(message: msg) { model.errorMessage = nil }.padding([.horizontal, .top], 24)
            }
            ScrollView {
                content.padding(28).frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .task { await model.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .general: KaiGeneralSettings()
        case .files: VStack(alignment: .leading, spacing: 18) { StoragePage(); FilesPage() }
        case .internet: NetworkPage()
        case .advanced: AdvancedPage()
        case .uninstall: UninstallPage()
        }
    }
}

// MARK: - Shared page pieces

private struct PageHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 24))
                .foregroundStyle(Theme.lime)
                .frame(width: 52, height: 52)
                .background(Theme.lime.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(color: Theme.lime.opacity(0.22), radius: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.display(24))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if let trailing { trailing }
        }
        .padding(.bottom, 6)
    }
}

/// A row of big radio choices (Log only / Block / Off).
private struct ChoiceCards: View {
    let options: [(value: String, title: String, help: String)]
    let selected: String
    let pick: (String) -> Void
    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.value) { o in
                let on = o.value == selected
                Button { pick(o.value) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(o.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(o.help).font(.system(size: 11)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(on ? Theme.lime : Theme.border, lineWidth: on ? 2 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// One policy switch: title, help and its choices.
private struct SwitchRow: View {
    @EnvironmentObject var model: AppModel
    let key: String
    let title: String
    let help: String
    let options: [(value: String, title: String, help: String)]
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(help).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                ChoiceCards(options: options, selected: model.policy?.switches[key] ?? options[0].value) {
                    model.setSwitch(key, $0)
                }
            }
        }
        .disabled(model.busy || model.policy == nil)
    }
}

/// A list of strings with remove buttons and an add field.
private struct EditableList: View {
    @EnvironmentObject var model: AppModel
    let kind: String
    let title: String
    let help: String
    let items: [String]
    let placeholder: String
    var canChoose = false
    @State private var newItem = ""

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(help).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                if items.isEmpty {
                    Text("None yet.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                ForEach(items, id: \.self) { item in
                    HStack {
                        Text(item).font(Theme.mono)
                        Spacer()
                        Button { model.remove(kind, item) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(Theme.muted)
                            .accessibilityLabel("Remove \(item)")
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 8) {
                    KaiField(placeholder: placeholder, text: $newItem, onSubmit: add)
                    Button("Add", action: add).buttonStyle(LimeButtonStyle())
                        .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                    if canChoose { Button("Choose…", action: choose).buttonStyle(GhostButtonStyle()) }
                }
            }
        }
        .disabled(model.busy || model.policy == nil)
    }

    private func add() {
        model.add(kind, newItem)
        newItem = ""
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var p = url.path
        if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        if p.contains(" ") {
            model.errorMessage = "Paths with spaces can't be added yet; protect the parent folder instead."
            return
        }
        model.add(kind, p)
    }
}

// MARK: - Pages

private struct GeneralPage: View {
    @EnvironmentObject var model: AppModel
    var showAgents = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showAgents { agents } else { app; logCheckCard }
        }
    }

    // Release batch 1: the log check lives here, with a one-sentence result.
    @State private var logCheck: String?
    private var logCheckCard: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Activity log").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button("Check activity log for edits") {
                        Task {
                            let r = await KaiCLI.run(["log", "verify"])
                            let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                            if out.hasPrefix("OK:"), let n = out.split(separator: " ").dropFirst().first {
                                logCheck = "No edits found in \(n) records. (A program with your permissions could still rewrite the whole log.)"
                            } else {
                                logCheck = "Kai found an edit: " + (out.isEmpty ? r.message : String(out.dropFirst(out.hasPrefix("FAIL: ") ? 6 : 0)))
                            }
                        }
                    }.buttonStyle(GhostButtonStyle())
                    Button("Show in Finder") { model.revealAuditLog() }.buttonStyle(GhostButtonStyle())
                }
                if let c = logCheck {
                    Text(c).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var agents: some View {
        CapsLabel("Agents")
        if let note = model.connectedNote { ConnectedNote(text: note) }
        CodexTrustRow()
        ForEach(Agent.allCases) { AgentCard(agent: $0) }
        Text("Kai connects every agent it finds on this Mac. On adds Kai's checks to the agent's settings file (its "
             + "hooks) and keeps a backup; Off removes them, and Kai won't connect that agent again on its own. "
             + "Restart open agent sessions to pick up a change.")
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
    }

    @ViewBuilder private var app: some View {
        CapsLabel("App")
        Card(padding: 14) {
            VStack(spacing: 12) {
                row("Notify me when Kai blocks something", isOn: $model.notifyOnBlock)
                row("Play Kai sounds", isOn: $model.playSounds)
                HStack(spacing: 12) {
                    ForEach(KaiSound.Cue.allCases, id: \.self) { cue in
                        Button(cue.title) { KaiSound.play(cue) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
                soundRow("Sound when Kai needs you", key: "soundApprovalNeeded", default: true)
                soundRow("Sound when a permission is granted", key: "soundPermissionGranted", default: true)
                soundRow("Sound when Kai blocks something", key: "soundBlocked", default: false)
                row("Open Kai at login", isOn: Binding(get: { model.launchAtLogin },
                                                       set: { model.launchAtLogin = $0 }))
            }
        }
        CapsLabel("AI gateway (optional)")
        Card(padding: 14) {
            Text("A local proxy that cleans requests to model APIs before they leave this Mac. Off unless you run it: kai gateway")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        CapsLabel("About")
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                info("Version", model.status?.version ?? "—")
                info("Command-line tool", model.cliPath ?? "not found")
                info("Policy file", model.status?.policy.source ?? "—")
                Button("Edit Policy File…") { model.openPolicyFile() }.buttonStyle(GhostButtonStyle())
            }
        }
    }

    private func soundRow(_ title: String, key: String, default on: Bool) -> some View {
        row(title, isOn: Binding(get: { UserDefaults.standard.object(forKey: key) as? Bool ?? on },
                                 set: { UserDefaults.standard.set($0, forKey: key) }))
    }

    private func row(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle(title, isOn: isOn).toggleStyle(KaiToggleStyle()).labelsHidden()
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 140, alignment: .leading)
            Text(v).font(Theme.mono).textSelection(.enabled)
        }
    }
}

private struct ProtectionPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What the checks built into Claude Code, Cursor and Codex do when they find something sensitive in a tool call or prompt. Files and Internet protection cover everything else.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            SwitchRow(key: "secrets", title: "Secrets found in text",
                      help: "API keys, tokens, private keys, passwords and database URLs.",
                      options: [("redact", "Redact", "Replace with a marker"), ("block", "Block", "Stop the request"),
                                ("warn", "Warn", "Log only"), ("off", "Off", "Don't look")])
            SwitchRow(key: "on_prompt_secret", title: "Secret typed into a prompt",
                      help: "Stop the prompt before it reaches the model.",
                      options: [("block", "Block", "Prompt never sent"), ("warn", "Warn", "Log only")])
            SwitchRow(key: "on_file_secret", title: "Agent reads a file with secrets or customer data",
                      help: "Secrets, and your blocked terms and rules, in files that aren't on the protected list. "
                          + "Ask: Claude Code asks you each time; Cursor asks for shell commands; otherwise it's blocked.",
                      options: [("ask", "Ask me", "You decide each time"), ("block", "Block", "Read denied"),
                                ("warn", "Warn", "Log only")])
            SwitchRow(key: "on_upload", title: "Command that looks like a data upload",
                      help: "For example curl -d @file, piping downloads into a shell, nc, scp. "
                          + "Ask: Claude Code and Cursor ask you; Codex blocks.",
                      options: [("block", "Block", "Command denied"), ("ask", "Ask me", "You decide each time"),
                                ("warn", "Warn", "Log only")])
            SwitchRow(key: "injection", title: "Prompt injection in tool results",
                      help: "Tells the agent the text is untrusted. Never blocks.",
                      options: [("warn", "Warn agent", "Add a caution"), ("off", "Off", "Don't look")])
            SwitchRow(key: "audit_context", title: "Show what was blocked",
                      help: "Keep the command, file or part of the prompt in the activity log so you can see why. Secrets in it are hidden first.",
                      options: [("on", "Keep an excerpt", "Command, path or prompt, redacted"),
                                ("off", "Rule only", "Just the rule and reason")])
            ExceptionsCard()
            if let p = model.policy, !p.ok {
                Text(p.error).font(.system(size: 12)).foregroundStyle(Theme.coral)
            }
        }
    }
}

/// Exceptions made with "Not a threat" on the Activity page.
private struct ExceptionsCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your exceptions").font(.system(size: 14, weight: .semibold))
                    Text("Commands you marked “Not a threat”. Each one skips only the rule named, and every use is still logged.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                let items = model.policy?.exempt ?? []
                if items.isEmpty {
                    Text("None yet. Add one from a blocked command on the Activity page.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                ForEach(items, id: \.self) { x in
                    HStack(spacing: 10) {
                        Text(x.rule).font(.system(size: 12, weight: .semibold)).frame(width: 110, alignment: .leading)
                        Text(x.pattern).font(Theme.mono).foregroundStyle(Theme.soft)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { model.removeExempt(x) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(Theme.muted)
                            .accessibilityLabel("Remove exception for \(x.rule)")
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .disabled(model.busy || model.policy == nil)
    }
}

private struct FilesPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditableList(kind: "protect", title: "Your protected items",
                         help: "Folders, files or patterns like *.pem and .env.*",
                         items: model.policy?.protect ?? [], placeholder: "~/path or pattern", canChoose: true)
            EditableList(kind: "allow", title: "Exceptions",
                         help: "Always allowed, even inside a protected folder, e.g. .env.example",
                         items: model.policy?.allow ?? [], placeholder: "~/path or pattern", canChoose: true)
        }
    }
}

private struct NetworkPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wall: NetworkWall
    @StateObject private var grants = GrantManager()
    @State private var telemetryNote: String?

    // Release batch 11: one row per agent. Kai blocks known telemetry hosts
    // silently; the documented switch, where the vendor has one.
    //   Claude Code: DISABLE_TELEMETRY / DISABLE_ERROR_REPORTING (code.claude.com/docs/en/data-usage)
    //   Codex: analytics.enabled = false (learn.chatgpt.com/docs/config-file/config-reference)
    //   Cursor: no documented off switch; Privacy Mode reduces it (docs.cursor.com/account/privacy)
    private var telemetry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent telemetry").font(Theme.display(16, .semibold))
            telemetryRow("Claude Code", blocks: "usage metrics and error reports (Statsig, Datadog, Sentry)") {
                if kai_claude_env_is("DISABLE_TELEMETRY", "1") == 1 {
                    Text("Turned off in Claude Code").font(.system(size: 12)).foregroundStyle(Theme.lime)
                } else {
                    Button("Turn off in Claude Code") { turnOffClaudeTelemetry() }.buttonStyle(GhostButtonStyle())
                        .help("Sets DISABLE_TELEMETRY and DISABLE_ERROR_REPORTING in Claude Code's settings. Claude Code also turns off its feature flags then, which can make Remote Control unavailable.")
                }
            }
            telemetryRow("Codex", blocks: "usage metrics (Statsig)") {
                if kai_codex_analytics_off(0) == 1 {
                    Text("Turned off in Codex").font(.system(size: 12)).foregroundStyle(Theme.lime)
                } else {
                    Button("Turn off in Codex") { turnOffCodexTelemetry() }.buttonStyle(GhostButtonStyle())
                        .help("Sets analytics.enabled = false in Codex's config.toml (a backup is kept).")
                }
            }
            telemetryRow("Cursor", blocks: "crash and usage counters (metrics.cursor.sh)") {
                Text("No setting from Cursor; Kai keeps blocking it.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .help("Cursor's Privacy Mode (Cursor Settings → General) reduces it to crash counters.")
            }
            if let n = telemetryNote {
                Text(n).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func telemetryRow<T: View>(_ agent: String, blocks: String, @ViewBuilder trailing: () -> T) -> some View {
        Card(padding: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent).font(.system(size: 13, weight: .semibold))
                    Text("Kai blocks its \(blocks) silently.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                trailing()
            }
        }
    }

    private func turnOffCodexTelemetry() {
        Task {
            let rc = kai_codex_analytics_off(1)
            await MainActor.run {
                telemetryNote = rc == 1 ? "Done. Restart Codex for it to apply. (Kai kept a backup of config.toml.)"
                    : rc == -2 ? "Codex's config.toml sets analytics in a form Kai doesn't edit; set analytics.enabled = false yourself."
                    : "Kai couldn't write Codex's config.toml."
                grants.refresh()
            }
        }
    }

    private func turnOffClaudeTelemetry() {
        Task {
            let rc = kai_claude_set_env("DISABLE_TELEMETRY", "1")
            let rc2 = rc == 0 ? kai_claude_set_env("DISABLE_ERROR_REPORTING", "1") : rc
            await MainActor.run {
                telemetryNote = rc2 == 0
                    ? "Done. Restart your Claude Code sessions for it to apply. (Your previous settings are kept in ~/.claude/settings.json.kai-bak.)"
                    : rc2 == 3 ? "Claude Code's settings file isn't valid JSON, so Kai changed nothing."
                               : "Kai couldn't write Claude Code's settings."
                grants.refresh()
            }
        }
    }

    // Fix 5: hosts in one agent's profile; ones Kai added from observed traffic
    // (not the vendor's docs) are marked for review.
    private var profileHosts: some View {
        var rows: [(agent: String, host: String, documented: Bool)] = []
        var i: Int32 = 0
        var a: UnsafePointer<CChar>? = nil, h: UnsafePointer<CChar>? = nil
        var d: Int32 = 0
        while kai_agent_profile_host(i, &a, &h, &d) == 1, let a, let h {
            rows.append((String(cString: a), String(cString: h), d == 1)); i += 1
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Agent profile hosts").font(Theme.display(16, .semibold))
            Text("Allowed for that agent only.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            ForEach(rows, id: \.host) { r in
                HStack(spacing: 8) {
                    Text(r.host).font(Theme.mono)
                    Text(r.agent == "cursor" ? "Cursor" : r.agent).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    if !r.documented {
                        Text("observed, not documented").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                            .help("Kai added this from traffic it saw, not from the vendor's documentation. Review it.")
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(icon: "globe", title: "Internet",
                       subtitle: "Off unless you turn it on. When on, Kai records where agents connect; nothing is blocked.",
                       trailing: AnyView(statusPill))
            // 0.3: opt-in. Off by default; Kai never turns the extension on by itself.
            Card(padding: 14, stroke: Color(hex: 0x3A4420)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Internet (preview): Watching — nothing is blocked").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Toggle("Internet (preview): Watching — nothing is blocked",
                               isOn: Binding(get: { wall.isOn || wall.state == .activating },
                                             set: { $0 ? wall.turnOn() : wall.turnOff() }))
                            .toggleStyle(KaiToggleStyle()).labelsHidden()
                            .disabled(wall.state == .activating || wall.state == .checking)
                    }
                    if wall.isOn {
                        Text("On: Kai records the connections agents make. Turning it off removes the filter from this Mac.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        // 0.4.1: where macOS asks, step by step; turns On by itself once approved.
                        InternetSetupStep()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("When an agent connects to a host that is not on your list")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                // Nov 1 corrective change: Watch only in this release (Protect behind a developer flag).
                let protect = DevFlags.internetProtect
                let raw = model.policy?.switches["egress"] ?? "log"
                ChoiceCards(options: [("log", "Watch", "Records the connections Kai observes; blocks nothing in this release.")]
                                     + (protect ? [("block", "Protect", "Only sites on your list are reachable.")] : [])
                                     + [("off", "Off", "Kai doesn't record agent connections.")],
                            selected: !protect && raw == "block" ? "log" : raw) { model.setSwitch("egress", $0) }
                    .disabled(model.busy || model.policy == nil)
                if !protect {
                    Text("Internet: Kai records the connections it observes.")
                        .font(.system(size: 12)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    HStack(spacing: 3) { Text("Watch").font(.system(size: 11)).foregroundStyle(Theme.muted); InfoButton(text: InfoText.watch) }
                    if protect {
                        HStack(spacing: 3) { Text("Protect").font(.system(size: 11)).foregroundStyle(Theme.muted); InfoButton(text: InfoText.protect) }
                    }
                }
                Text("Watch and Protect both turn off QUIC for agents, so Kai can see which sites they reach. "
                   + "Agents fall back to normal HTTPS; in Watch nothing else is blocked.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            EditableList(kind: "egress_allow", title: "Your allowed destinations",
                         help: "A host (also covers its subdomains), an IP address or range, optionally with :port: "
                             + "db.yourcompany.com:5432, 10.0.0.0/8, 203.0.113.5:22. Built in: this Mac and each agent's model and sign-in hosts.",
                         items: model.policy?.egressAllow ?? [], placeholder: "artifacts.yourcompany.com or 10.0.0.0/8")
            telemetry
            profileHosts
            // B2 agent profiles: what the built-in model hosts allow, and the limit.
            Text("Built in for every agent: this Mac and the model and sign-in hosts (anthropic.com, openai.com, "
               + "cursor.sh and others). Kai can't tell the model connection from other data sent to the same host. "
               + "Everything else is recorded, not blocked.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { wall.refresh() }
    }

    private var statusPill: some View { WallPill(word: wall.stateWord) }

}

/// The storage wall is implemented (its decision engine is tested) but needs
/// Apple's Endpoint Security entitlement to actually block file opens, so it
/// ships off. This card says so rather than pretending the control is live.
private struct StoragePage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var storage: StorageWall

    // Batch 2: an edition without the Files extension shows a greyed page,
    // never a toggle that seems to work.
    var body: some View {
        if StorageWall.included { content } else { unavailable }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(icon: "folder", title: "Files",
                       subtitle: "Stops agents opening your keys and passwords, even from a script they wrote.")
            Card(padding: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Files protection").font(.system(size: 14, weight: .semibold))
                        Text(ProtectionText.filesNotIncluded).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
            }
            .opacity(0.5)
            Text("Until then, Kai's checks inside each agent still stop agents reading protected files "
               + "with their own tools; a program an agent writes and runs can get around them.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(icon: "folder", title: "Files",
                       subtitle: "Agents can't open your keys, passwords and Kai's settings — even from a script. Every agent on this Mac; their own working files stay usable.",
                       trailing: AnyView(WallPill(word: storage.stateWord)))
            Card(padding: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Files protection").font(.system(size: 14, weight: .semibold))
                        Text(storage.summary).font(.system(size: 12))
                            .foregroundStyle(storage.isOn ? Theme.lime : Theme.muted)
                    }
                    Spacer()
                    Toggle("Files protection", isOn: Binding(get: { storage.isOn },
                                                         set: { on in
                                                             if on { storage.turnOn(); return }
                                                             Task { if await OwnerAuth.shared.confirm("turn off Files protection") { storage.turnOff() } }
                                                         }))
                        .toggleStyle(KaiToggleStyle()).labelsHidden()
                        .disabled(storage.state == .activating || storage.state == .checking)
                }
            }
            if storage.needsFullDiskAccess {
                Card(padding: 14, stroke: Theme.amber.opacity(0.5)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("One more step: Full Disk Access").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                        Text("macOS requires Full Disk Access for Files protection. Turn on Kai in the list, "
                           + "then it starts on its own within a few seconds — no need to come back here.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Full Disk Access settings") { storage.openFullDiskAccessSettings() }
                            .buttonStyle(LimeButtonStyle())
                    }
                }
            } else if case .needsApproval = storage.state {
                Card(padding: 14, stroke: Theme.amber.opacity(0.5)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Approve the Kai system extension").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                        Button("Open extension settings") { storage.openExtensionApprovalSettings() }
                            .buttonStyle(LimeButtonStyle())
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("When an agent opens a file your policy protects")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                ChoiceCards(options: [("log", "Watch", "See what would be blocked."),
                                      ("block", "Protect", "Block it."),
                                      ("off", "Off", "Agents open anything.")],
                            selected: model.policy?.switches["storage"] ?? "off") { model.setSwitch("storage", $0) }
                    .disabled(model.busy || model.policy == nil)
            }
            Text("Needs Apple's Endpoint Security entitlement for distribution — until then it runs only in "
               + "development builds. Preview the decisions without loading it: sudo kai storaged --run")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { storage.refreshRuntime() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in storage.refreshRuntime() }
    }
}

private struct CompanyPage: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var action = "replace"
    @State private var replacement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Words and names that must not reach a model. Matched in prompts and tool arguments.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    let terms = model.policy?.terms ?? []
                    if terms.isEmpty {
                        Text("No company terms yet. Add a codename below.").font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                    ForEach(terms, id: \.self) { t in
                        HStack {
                            Text(t.text).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(t.action == "replace" ? "Replace with “\(t.replacement ?? "")”" : t.action.capitalized)
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            Button { model.remove("term", t.text) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(Theme.muted)
                                .accessibilityLabel("Remove \(t.text)")
                        }
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
                    }
                    HStack(spacing: 8) {
                        KaiField(placeholder: "e.g. Project Falcon", text: $text)
                        Picker("Action", selection: $action) {
                            Text("Replace").tag("replace")
                            Text("Redact").tag("redact")
                            Text("Block").tag("block")
                            Text("Warn").tag("warn")
                        }
                        .labelsHidden().frame(width: 100)
                        if action == "replace" {
                            KaiField(placeholder: "with, e.g. Project X", text: $replacement).frame(width: 170)
                        }
                        Button("Add") {
                            model.addTerm(text: text, action: action, replacement: replacement)
                            text = ""; replacement = ""
                        }
                        .buttonStyle(LimeButtonStyle())
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (action == "replace" && replacement.isEmpty))
                    }
                }
            }
            .disabled(model.busy || model.policy == nil)
            if let rules = model.policy?.rules, !rules.isEmpty {
                CapsLabel("Pattern rules (edit in the policy file)")
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rules, id: \.self) { r in
                            HStack {
                                Text(r.name).font(.system(size: 13, weight: .semibold))
                                Text(r.pattern).font(Theme.mono).foregroundStyle(Theme.muted).lineLimit(1)
                                Spacer()
                                Text(r.action).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Phase B item 10: everything technical, one page with sections.
private struct AdvancedPage: View {
    @AppStorage("advancedSection") private var section = "agents"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(icon: "slider.horizontal.3", title: "Advanced",
                       subtitle: "How Kai is built into your agents, their checks, company terms, permissions and the app.")
            Picker("", selection: $section) {
                Text("Agents").tag("agents")
                Text("Checks").tag("checks")
                Text("Company data").tag("company")
                Text("Permissions").tag("permissions")
                Text("App").tag("app")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 520)
            switch section {
            case "checks": ProtectionPage()
            case "company": CompanyPage()
            case "permissions": PermissionsPage()
            case "app": GeneralPage(showAgents: false)
            default: GeneralPage(showAgents: true)
            }
        }
    }
}

// Item 3: Agent Control — the sessions list + per-session detail (grant, revoke,
// pause), as the first Settings page. Reuses the session views from the Agents
// window; data from `kai sessions`/`kai agents` (works with the storage wall off).
private struct PermissionsPage: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var grants = GrantManager()
    @AppStorage("permFilter") private var filter = "all"

    private var history: [AuditEvent] {
        model.events.filter { $0.source == "grant" }.filter { e in
            switch filter {
            case "granted": return e.event == "approved" || e.event == "requested"
            case "used": return e.event == "used"
            case "ended": return e.event == "revoked" || e.event == "expired"
            default: return true
            }
        }
    }

    // B2: rules (every future session) and Keep blocked, by verified agent
    // identity and exact host. Removing one never lowers protection.
    @ViewBuilder private var rulesSection: some View {
        let allow = grants.rules.filter(\.isAllow)
        let kept = grants.rules.filter { !$0.isAllow }
        CapsLabel("Rules").padding(.top, 4)
        if allow.isEmpty {
            Text("No rules. Make one from a card: More… → Create a rule.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        ForEach(allow) { r in ruleRow(r, line: "\(r.agentTitle) may connect to \(r.dest) \(r.untilLabel)") }
        if !kept.isEmpty {
            CapsLabel("Kept blocked").padding(.top, 4)
            Text("Kai doesn't ask about these again while they last; each attempt is still blocked and recorded. "
                 + "Keep blocked lasts for the session it was chosen in; Block always makes it permanent.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(kept) { r in ruleRow(r, line: "\(r.agentTitle) can't connect to \(r.dest) \(r.untilLabel)") }
        }
    }

    private func ruleRow(_ r: DecisionRule, line: String) -> some View {
        Card(padding: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(line).font(.system(size: 13))
                    Text("Signed as \(r.identity)").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.muted).lineLimit(1).textSelection(.enabled)
                    Text(r.isAllow ? "Kai can't tell what is sent over this encrypted connection."
                                   : "Only this host, only this agent.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if !r.isAllow && (r.isSessionOnly || r.isTemporary) {
                    Button("Block always") { grants.blockAlways(r) }.buttonStyle(GhostButtonStyle())
                        .help("Block \(r.dest) for \(r.agentTitle) in every session, until you remove it.")
                }
                Button(r.isAllow ? "Remove" : "Ask again") { grants.removeRule(r) }
                    .buttonStyle(GhostButtonStyle())
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Every permission you gave, across sessions and projects, and their recent history. Permissions are given only in Kai — never by an agent.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            CapsLabel("Active permissions")
            if grants.grantGroups.isEmpty {
                Text("No active permissions.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            } else {
                ForEach(grants.grantGroups) { g in
                    Card(padding: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(g.agent) · \(g.opLabel) · \(g.scopeLabel)"
                                     + (g.count > 1 ? " ×\(g.count)" : "")
                                     + (g.signed ? "" : " (unsigned)"))
                                    .font(.system(size: 13))
                                Text(g.resource).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.muted).lineLimit(1)
                                Text(g.status).font(.system(size: 11))
                                    .foregroundStyle(g.status == "expired" ? Theme.muted : Theme.lime)
                                if let m = g.members.first {
                                    Text(m.authorityLabel).font(.system(size: 11)).foregroundStyle(Theme.muted)
                                }
                            }
                            Spacer()
                            Button(g.count > 1 ? "Revoke all" : "Revoke") { grants.revokeGroup(g) }
                                .buttonStyle(GhostButtonStyle())
                        }
                    }
                }
            }
            rulesSection
            CapsLabel("Recent history").padding(.top, 4)
            Picker("", selection: $filter) {
                Text("All").tag("all")
                Text("Given").tag("granted")
                Text("Used").tag("used")
                Text("Ended").tag("ended")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 320)
            if history.isEmpty {
                Text("No permission history yet.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            } else {
                ForEach(history.prefix(60)) { e in
                    HStack(spacing: 10) {
                        Text(e.event.capitalized).font(.system(size: 12))
                            .frame(width: 78, alignment: .leading)
                        Text(e.target ?? e.detail).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.soft).lineLimit(1)
                        Spacer()
                        if let d = e.date { Text(ago(d)).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                    }
                }
            }
            Spacer()
        }
    }
}

private struct ActivityRow: View {
    @EnvironmentObject var model: AppModel
    let event: AuditEvent
    let followUp: AuditEvent?
    let expanded: Bool
    var count: Int = 1
    @ObservedObject var grants: GrantManager
    let toggle: () -> Void
    @State private var report: ReportInfo?

    private var color: Color { Theme.tone(event.tone) }
    private var icon: String { event.iconName }   // step 5: an allow is never ⚠

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) { header }.buttonStyle(.plain)
                .accessibilityHint(expanded ? "Hide details" : "Show details")
            if let t = event.excerpt, !event.isNetwork, !event.isGrant {
                ExcerptView(text: t, match: event.match, expanded: expanded)
            }
            if event.isNetwork || event.isGrant || event.isStorage {
                Text(event.plainSentence).font(.system(size: 12)).foregroundStyle(Theme.soft)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !event.detail.isEmpty {
                Text(event.detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let d = event.decision_id {   // the ID the agent quoted, to find this row
                Text("Decision \(d)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
            }
            DecisionSheet(event: event, count: count, showHeader: false, grants: grants)
            if let n = followUp {
                Label(n.detail, systemImage: "arrow.turn.down.right")
                    .font(.system(size: 12)).foregroundStyle(Theme.soft)
            }
            if expanded { details }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(expanded ? Theme.border : .clear))
        .alert("False-positive report written", isPresented: Binding(get: { report != nil },
                                                                    set: { if !$0 { report = nil } })) {
            Button("Open GitHub issue") { if let r = report, let u = URL(string: r.issueUrl) { NSWorkspace.shared.open(u) } }
            Button("Show report") { if let r = report { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) } }
            Button("Done", role: .cancel) {}
        } message: {
            Text("It holds the rule, the reason and the excerpt above, with secrets hidden. Nothing has been sent: review it, then open the issue page to file it if you want to.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            Text(event.verbLabel).font(.system(size: 13, weight: .semibold))
            + Text(" · \(event.agentName)").font(.system(size: 13))
            + Text(event.actionLabel.map { " · \($0)" } ?? "").font(.system(size: 13)).foregroundColor(Theme.muted)
            if count > 1 {
                Text("×\(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.muted, in: Capsule())
                    .help("\(count) identical records; the latest is shown")
            }
            Spacer()
            if let d = event.date { Text(ago(d)).font(.system(size: 11)).foregroundStyle(Theme.muted) }
            CopyButton(text: CardText.brief(event, sessionName: AgentsModel.shared.sessions.first { $0.id == event.session }?.name))
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
        }
        .contentShape(Rectangle())
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 4) {
                if !event.rule.isEmpty { fact("Rule", event.rule) }
                if let c = event.cwd, !c.isEmpty { fact("Folder", c) }
                if let s = event.session, !s.isEmpty { fact("Session", String(s.prefix(12))) }
                fact("Record", String(event.id.prefix(10)))
            }
            if event.excerpt == nil && !event.isNetwork {
                Text("No excerpt was kept for this record (older record, or “Show what was blocked” is off).")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 8) {
                if (event.isBlock || event.decision == "warn") && !event.isNetwork && !event.isGrant { notAThreat }
                Button("Copy details") { model.copyDetails(event) }.buttonStyle(GhostButtonStyle())
            }
        }
    }

    @ViewBuilder private var notAThreat: some View {
        Menu("Not a threat") {
            if event.isBuiltinRule {
                Text("Kai's own protection can't be switched off from here")
            }
            if event.canExemptCommand {
                Button(event.exemptIsTimed ? event.exemptLabel : "Allow this exact command (\(event.rule) only)") { model.exempt(event) }
            }
            if let p = event.allowablePath {
                Button("Always allow \(p)") { model.allowFile(event) }
            }
            Divider()
            Button("Report a false positive…") {
                Task { report = await model.report(event) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 12).frame(minHeight: 32)
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.border))
        .disabled(model.busy)
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 64, alignment: .leading)
            Text(v).font(Theme.mono).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }
}

/// The recorded command, path or prompt excerpt, with the part a rule
/// matched highlighted and hidden secrets dimmed.
private struct ExcerptView: View {
    let text: String
    let match: String?
    let expanded: Bool

    private var styled: AttributedString {
        var a = AttributedString(text)
        a.foregroundColor = Theme.soft
        let ns = text as NSString
        if let re = try? NSRegularExpression(pattern: #"\[REDACTED by Kai: [^\]]*\]"#) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let r = Range(m.range, in: a) { a[r].foregroundColor = Theme.muted }
            }
        }
        if let m = match, !m.isEmpty, let r = a.range(of: m) ?? a.range(of: String(m.split(separator: " ").first ?? "")) {
            a[r].foregroundColor = Color(hex: 0xFFB4AC)
            a[r].backgroundColor = Theme.coral.opacity(0.18)
        }
        return a
    }

    var body: some View {
        Text(styled)
            .font(Theme.mono)
            .lineLimit(expanded ? nil : 3)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// B3: a wall's state in one word (not installed · off · starting · watching ·
/// protecting · unhealthy), from macOS and the measured heartbeat.
struct WallPill: View {
    let word: String
    private var color: Color {
        switch word {
        case "blocking": return Theme.lime
        case "watching", "starting": return Theme.amber
        case "unhealthy": return Theme.coral
        default: return Theme.muted
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(word.prefix(1).uppercased() + word.dropFirst())
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(color.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.4)))
    }
}

