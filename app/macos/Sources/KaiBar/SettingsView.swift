// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import AppKit
import SwiftUI
import KaiCore

/// Phase B item 10: Agent Control (the main page) and Activity, then four
/// settings pages named for what they protect - Files, Internet, Chats - and
/// Advanced for everything technical.
enum SettingsPage: String, CaseIterable, Identifiable {
    case agentControl, activity, files, internet, chats, advanced
    var id: String { rawValue }
    /// A page saved by an older Kai ("storage", "network", "general", ...).
    init(stored raw: String) {
        switch raw {
        case "storage": self = .files
        case "network": self = .internet
        case "general", "protection", "permissions", "company": self = .advanced
        default: self = SettingsPage(rawValue: raw) ?? .agentControl
        }
    }
    var title: String {
        switch self {
        case .agentControl: return "Agent Control"
        case .activity: return "Activity"
        case .files: return "Files"
        case .internet: return "Internet"
        case .chats: return "Chats"
        case .advanced: return "Advanced"
        }
    }
    var icon: String {
        switch self {
        case .agentControl: return "person.2.gobackward"
        case .activity: return "waveform.path.ecg"
        case .files: return "folder"
        case .internet: return "globe"
        case .chats: return "bubble.left.and.bubble.right"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wall: NetworkWall
    @EnvironmentObject var storage: StorageWall
    @AppStorage("settingsPage") private var pageRaw = SettingsPage.agentControl.rawValue
    private var page: SettingsPage { SettingsPage(stored: pageRaw) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                if let msg = model.errorMessage {
                    ErrorBanner(message: msg) { model.errorMessage = nil }.padding([.horizontal, .top], 24)
                }
                ScrollView {
                    content.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(
                ZStack {
                    Theme.ink
                    RadialGradient(colors: [Theme.lime.opacity(0.08), .clear], center: .topTrailing,
                                   startRadius: 0, endRadius: 420)
                }
            )
        }
        .frame(width: 980, height: 640)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Color.white)
        .preferredColorScheme(.dark)
        .task { await model.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image("KaiLogo").resizable().frame(width: 30, height: 30).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text("Kai").font(Theme.display(16))
                        if !KaiInstance.isRelease { DevBadge() }
                    }
                    // Item 4: observed enforcement only, never a blanket "All
                    // protected" from agent-hook state.
                    Text(model.health == .problem ? model.headline
                         : model.statusSentence(storageOn: storage.isOn, networkOn: wall.isOn))
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 18).padding(.top, 8)
            ForEach(SettingsPage.allCases) { p in
                if p == .files { CapsLabel("Settings").padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 2) }
                Button { pageRaw = p.rawValue } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.icon).frame(width: 18)
                        Text(p.title)
                        Spacer()
                    }
                    .font(.system(size: 13, weight: p == page ? .semibold : .regular))
                    .foregroundStyle(p == page ? Theme.ink : Theme.soft)
                    .padding(.horizontal, 10).frame(height: 34)
                    .background(p == page ? Theme.lime : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(p == page ? .isSelected : [])
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 220)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Color(hex: 0x23252B)).frame(width: 1) }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .agentControl: AgentControlPage()
        case .activity: ActivityPage()
        case .files: VStack(alignment: .leading, spacing: 18) { StoragePage(); FilesPage() }
        case .internet: NetworkPage()
        case .chats: ChatsPage()
        case .advanced: AdvancedPage()
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
                        Text(o.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
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
            if showAgents { agents } else { app }
        }
    }

    @ViewBuilder private var agents: some View {
        CapsLabel("Built into your agents")
        ForEach(Agent.allCases.filter { $0 != .chrome }) { AgentCard(agent: $0) }
        Text("Turning an agent on adds Kai's checks to its settings file (its hooks) and keeps a backup. Restart open agent sessions to pick up the change.")
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
    }

    @ViewBuilder private var app: some View {
        CapsLabel("App")
        Card(padding: 14) {
            VStack(spacing: 12) {
                row("Notify me when Kai blocks something", isOn: $model.notifyOnBlock)
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

    // Batch 2: telemetry is blocked silently; per agent, the state and (for
    // Claude Code) a button that turns it off in the agent itself.
    @ViewBuilder private var telemetry: some View {
        if !grants.telemetryHints.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Agent telemetry").font(Theme.display(16, .semibold))
                ForEach(grants.telemetryHints, id: \.self) { a in
                    Card(padding: 12) {
                        HStack {
                            Text(a == "claude" ? "Claude Code" : a.prefix(1).uppercased() + a.dropFirst())
                                .font(.system(size: 13, weight: .semibold))
                            Text("Telemetry: blocked by Kai").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            Spacer()
                            if a == "claude" {
                                if kai_claude_env_is("DISABLE_TELEMETRY", "1") == 1 {
                                    Text("Turned off in Claude Code").font(.system(size: 12)).foregroundStyle(Theme.lime)
                                } else {
                                    Button("Turn off in Claude Code") { turnOffClaudeTelemetry() }
                                        .buttonStyle(GhostButtonStyle())
                                }
                            }
                        }
                    }
                }
                if let n = telemetryNote {
                    Text(n).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
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

    private func turnOffClaudeTelemetry() {
        Task {
            guard await OwnerAuth.shared.confirm("change Claude Code's settings to turn off its telemetry") else { return }
            let rc = kai_claude_set_env("DISABLE_TELEMETRY", "1")
            await MainActor.run {
                telemetryNote = rc == 0
                    ? "Done. Restart your Claude Code sessions for it to apply. (Your previous settings are kept in ~/.claude/settings.json.kai-bak.)"
                    : rc == 3 ? "Claude Code's settings file isn't valid JSON, so Kai changed nothing."
                              : "Kai couldn't write Claude Code's settings."
                grants.refresh()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(icon: "globe", title: "Internet",
                       subtitle: "Agents can only reach sites you've allowed. Other apps are never touched.",
                       trailing: AnyView(statusPill))
            if !wall.isOn {
                Card(padding: 14, stroke: Color(hex: 0x3A4420)) {
                    HStack {
                        Text(wall.summary).font(.system(size: 13))
                            .foregroundStyle(wall.state == .off ? Theme.soft : Theme.amber)
                        Spacer()
                        Button("Turn on") { wall.turnOn() }.buttonStyle(LimeButtonStyle())
                            .disabled(wall.state == .activating)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("When an agent connects to a host that is not on your list")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                ChoiceCards(options: [("log", "Watch", "See where agents go. Nothing is blocked."),
                                      ("block", "Protect", "Only sites on your list are reachable."),
                                      ("off", "Off", "Agents reach anything.")],
                            selected: model.policy?.switches["egress"] ?? "log") { model.setSwitch("egress", $0) }
                    .disabled(model.busy || model.policy == nil)
                Text("Watch and Protect both turn off QUIC for agents, so Kai can see which sites they reach. "
                   + "Agents fall back to normal HTTPS; in Watch nothing else is blocked.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            EditableList(kind: "egress_allow", title: "Your allowed destinations",
                         help: "A host (also covers its subdomains), an IP address or range, optionally with :port: "
                             + "db.yourcompany.com:5432, 10.0.0.0/8, 203.0.113.5:22. This Mac, model APIs, GitHub "
                             + "and package registries are built in.",
                         items: model.policy?.egressAllow ?? [], placeholder: "artifacts.yourcompany.com or 10.0.0.0/8")
            telemetry
            profileHosts
            // B2 agent profiles: what the built-in model hosts allow, and the limit.
            Text("Built in for every agent: this Mac and the model and sign-in hosts (anthropic.com, openai.com, "
               + "cursor.sh and others). Kai can't tell the model connection from other data sent to the same host. "
               + "GitHub, package registries and Apple developer services are optional channels, off by default: "
               + "turn them on per agent in Agent Control.")
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
                        Text("Coming in a later release.").font(.system(size: 12)).foregroundStyle(Theme.muted)
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
            Text("Words and names that must not reach a model. Matched in prompts, tool arguments and AI chats.")
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

/// Phase B item 10: Chats - what Kai checks in AI chats in the browser.
private struct ChatsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(icon: "bubble.left.and.bubble.right", title: "Chats",
                       subtitle: "Kai checks what you paste into AI chats in Chrome.")
            AgentCard(agent: .chrome)
            Text("Chats use the same secret checks and company terms as your agents (Advanced → Company data). Files and Internet protection don't apply to the browser.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
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
private struct AgentControlPage: View {
    @ObservedObject private var model = AgentsModel.shared   // cached: renders at once
    @StateObject private var grants = GrantManager()
    @State private var selected: String?
    @State private var showEnded = false

    /// Working now, then idle; ended sessions live in their own collapsed group.
    private var sorted: [SessionRow] { model.workingNow + model.idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(icon: "person.2.gobackward", title: "Agent Control",
                       subtitle: "Every agent session Kai sees, with its permissions. Revoke or pause one session without touching the others.")
            // A plain HStack (not a nested split view, which collapsed inside the
            // Settings window's own split): a fixed-width list + a detail, both
            // filling the height.
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.loaded {
                        // cold start: placeholders until the first refresh lands
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(0..<3, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Claude Code · project").font(.system(size: 13))
                                    Text("ttys000 · active 1m ago").font(.caption)
                                }.redacted(reason: .placeholder)
                            }
                        }.padding(10)
                    } else if sorted.isEmpty && model.endedToday.isEmpty {
                        Text("No agent sessions right now.").font(.system(size: 13))
                            .foregroundStyle(Theme.muted).padding(10)
                    }
                    List(selection: $selected) {
                        Section("What each agent can reach") {
                            ForEach([("claude", "Claude Code"), ("codex", "Codex"), ("cursor", "Cursor")], id: \.0) { a in
                                Text(a.1).font(.system(size: 13)).tag("agent:" + a.0)
                            }
                            Text("Chats").font(.system(size: 13)).tag("chats")
                        }
                        if !model.workingNow.isEmpty {
                            Section("Working now") {
                                ForEach(model.workingNow) { s in SessionRowView(session: s, needsYou: false).tag(s.id) }
                            }
                        }
                        if !model.idle.isEmpty {
                            Section("Idle") {
                                ForEach(model.idle) { s in SessionRowView(session: s, needsYou: false).tag(s.id) }
                            }
                        }
                        if !model.endedToday.isEmpty {
                            DisclosureGroup("Ended today (\(model.endedToday.count))", isExpanded: $showEnded) {
                                ForEach(model.endedToday) { s in SessionRowView(session: s, needsYou: false).tag(s.id) }
                            }
                        }
                        if !model.backgroundServices.isEmpty {
                            Section("Background services") {
                                ForEach(model.backgroundServices) { b in
                                    Text("\(b.displayAgent) — \(b.projectName)")
                                        .font(.caption).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(width: 300)
                Divider()
                Group {
                    if let id = selected, id.hasPrefix("agent:") {
                        AgentReachView(agent: String(id.dropFirst(6)), grants: grants)
                    } else if selected == "chats" {
                        ChatsDetail()
                    } else if let id = selected, let s = model.sessions.first(where: { $0.id == id }) {
                        SessionDetail(session: s, grants: grants)
                    } else {
                        VStack { Spacer(); Text("Select a session or an agent").foregroundStyle(Theme.muted); Spacer() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The Settings window wraps pages in a ScrollView, where "fill the
            // height" collapses to the minimum: give the list + detail a real
            // height (the window is 640 tall).
            .frame(maxWidth: .infinity, minHeight: 470, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The data is cached (shared store), so it may not CHANGE when the page
        // opens: pick a session on appear too, not only on a change.
        .onAppear { selectDefault() }
        .task { await model.refresh(); selectDefault() }
        .onChange(of: model.sessions) { _ in selectDefault() }
        .onChange(of: model.loaded) { _ in selectDefault() }
    }

    /// Select the first session once data arrives, so the detail isn't empty.
    private func selectDefault() {
        if selected == nil || !model.sessions.contains(where: { $0.id == selected }) {
            selected = sorted.first?.id
        }
    }
}

// S7: every active grant across sessions/projects, plus the recent lifecycle
// history (granted / used / expired / revoked) from the audit log. Grants are
// created only from Kai; this page can revoke them.
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
            Text("Kai doesn't ask about these again; each attempt is still blocked and recorded.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            ForEach(kept) { r in ruleRow(r, line: "\(r.agentTitle) can't connect to \(r.dest)") }
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

private struct ActivityPage: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var grants = GrantManager()
    @State private var verifyResult: String?
    @AppStorage("activityFilter") private var filter = "all"
    @State private var expanded: Set<String> = []

    private var shown: [AuditEvent] {
        model.events.filter { e in
            guard !e.isNote else { return false } // shown under their block
            if e.isGrant && e.event == "requested" { return false } // one row per block, not two
            switch filter {
            case "agents": return !e.isNetwork
            case "network": return e.isNetwork
            default: return true
            }
        }
    }

    /// Identical decisions (same who, what, rule and target) collapse into ONE
    /// row with a count - a component retrying the same blocked open becomes
    /// "×956", not 956 rows. The newest one represents the group.
    private var grouped: [(event: AuditEvent, count: Int)] {
        var order: [String] = []
        var groups: [String: (event: AuditEvent, count: Int)] = [:]
        for e in shown {
            let k = "\(e.agentName)|\(e.decision)|\(e.rule)|\(e.excerpt ?? "")|\(e.detail)"
            if let g = groups[k] { groups[k] = (g.event, g.count + 1) }
            else { groups[k] = (e, 1); order.append(k) }
        }
        return order.compactMap { groups[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(icon: "waveform.path.ecg", title: "Activity",
                       subtitle: "What Kai blocked, cleaned or noticed, what it was, and what the agent did next. Secrets are never stored.")
            Card(padding: 14) {
                HStack(spacing: 10) {
                    if let a = model.status?.audit {
                        Image(systemName: a.intact ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(a.intact ? Theme.lime : Theme.coral)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.intact ? "Audit log intact · \(a.records) records" : a.error)
                            Text(model.weeklyLine).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                            .font(.system(size: 13))
                    }
                    Spacer()
                    Button("Verify") { Task { verifyResult = await model.verifyAuditLog() } }
                        .buttonStyle(GhostButtonStyle())
                    Button("Show in Finder") { model.revealAuditLog() }.buttonStyle(GhostButtonStyle())
                }
            }
            if let v = verifyResult { Text(v).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            if let n = model.notice {
                Card(padding: 12, stroke: Color(hex: 0x3A4420)) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.lime)
                        Text(n).font(.system(size: 13))
                        Spacer()
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(Theme.muted).accessibilityLabel("Dismiss")
                    }
                }
            }
            Picker("Show", selection: $filter) {
                Text("Everything").tag("all")
                Text("Agent actions").tag("agents")
                Text("Network").tag("network")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 360)
            if shown.isEmpty {
                Text(filter == "network" ? "No connections noticed yet." : "No blocks, warnings or noticed hosts yet.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ForEach(grouped.prefix(150), id: \.event.id) { g in
                let e = g.event
                ActivityRow(event: e, followUp: model.followUp(for: e), expanded: expanded.contains(e.id),
                            count: g.count, grants: grants) {
                    if expanded.contains(e.id) { expanded.remove(e.id) } else { expanded.insert(e.id) }
                }
            }
        }
    }
}

/// One decision: what it was about, why, and what the agent did next.
/// Click to open the details and "Not a threat".
private struct ActivityRow: View {
    @EnvironmentObject var model: AppModel
    let event: AuditEvent
    let followUp: AuditEvent?
    let expanded: Bool
    var count: Int = 1
    @ObservedObject var grants: GrantManager
    let toggle: () -> Void
    @State private var report: ReportInfo?

    private var color: Color {
        if event.isBlock { return Theme.coral }
        if event.isExempt || event.decision == "log" { return Theme.muted }
        if event.decision == "redact" || event.decision == "replace" { return Theme.lime }
        return Theme.amber
    }
    private var icon: String {
        if event.isBlock { return "hand.raised.fill" }
        if event.isExempt { return "checkmark.circle" }
        if event.decision == "log" { return "eye" }
        if event.decision == "redact" || event.decision == "replace" { return "wand.and.stars" }
        return "exclamationmark.triangle.fill"
    }

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
            Text(event.verb).font(.system(size: 13, weight: .semibold))
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
                Button("Allow this exact command (\(event.rule) only)") { model.exempt(event) }
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
        case "protecting": return Theme.lime
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

