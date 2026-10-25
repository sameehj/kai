// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, protection, files, network, storage, permissions, company, activity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .protection: return "Agent hooks"
        case .files: return "Protected files"
        case .network: return "Network wall"
        case .storage: return "Storage wall"
        case .permissions: return "Permissions"
        case .company: return "Company data"
        case .activity: return "Activity"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .protection: return "shield"
        case .files: return "folder"
        case .network: return "globe"
        case .storage: return "externaldrive"
        case .permissions: return "key"
        case .company: return "doc.text"
        case .activity: return "waveform.path.ecg"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("settingsPage") private var pageRaw = SettingsPage.general.rawValue
    private var page: SettingsPage { SettingsPage(rawValue: pageRaw) ?? .general }

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
                    Text("Kai").font(Theme.display(16))
                    Text(model.health == .protecting ? "All protected" : model.headline)
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 18).padding(.top, 8)
            ForEach(SettingsPage.allCases) { p in
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
        case .general: GeneralPage()
        case .protection: ProtectionPage()
        case .files: FilesPage()
        case .network: NetworkPage()
        case .storage: StoragePage()
        case .permissions: PermissionsPage()
        case .company: CompanyPage()
        case .activity: ActivityPage()
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
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(icon: "gearshape", title: "General", subtitle: "Which agents Kai protects, and how the app behaves.")
            CapsLabel("Agents")
            ForEach(Agent.allCases) { AgentCard(agent: $0) }
            Text("Turning an agent on adds Kai's hooks to its settings file and keeps a backup. Restart open agent sessions to pick up the change.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            CapsLabel("App")
            Card(padding: 14) {
                VStack(spacing: 12) {
                    row("Notify me when Kai blocks something", isOn: $model.notifyOnBlock)
                    row("Open Kai at login", isOn: Binding(get: { model.launchAtLogin },
                                                           set: { model.launchAtLogin = $0 }))
                }
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
            PageHeader(icon: "shield", title: "Agent hooks",
                       subtitle: "What the agent hooks (Claude Code, Cursor, Codex) do when they find something sensitive in a tool call or prompt. These check the agents' own actions; the network and storage walls cover everything else.")
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
            PageHeader(icon: "folder", title: "Protected files",
                       subtitle: "Files and folders agents may never read.")
            EditableList(kind: "protect", title: "Agents may never read",
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(icon: "globe", title: "Network wall",
                       subtitle: "Where your agents can send data. Other apps are never touched.",
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
                ChoiceCards(options: [("log", "Log only", "See what agents reach. Nothing is blocked."),
                                      ("block", "Block", "Only hosts on your list are reachable."),
                                      ("off", "Off", "The wall is paused.")],
                            selected: model.policy?.switches["egress"] ?? "log") { model.setSwitch("egress", $0) }
                    .disabled(model.busy || model.policy == nil)
            }
            hosts
            EditableList(kind: "egress_allow", title: "Your allowed destinations",
                         help: "A host (also covers its subdomains), an IP address or range, optionally with :port: "
                             + "db.yourcompany.com:5432, 10.0.0.0/8, 203.0.113.5:22. This Mac, model APIs, GitHub "
                             + "and package registries are built in.",
                         items: model.policy?.egressAllow ?? [], placeholder: "artifacts.yourcompany.com or 10.0.0.0/8")
        }
        .onAppear { wall.refresh() }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle().fill(wall.isOn ? Theme.lime : Theme.muted).frame(width: 8, height: 8)
            Text(wall.isOn ? "On" : "Off")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(wall.isOn ? Theme.lime : Theme.muted)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background((wall.isOn ? Theme.lime : Theme.muted).opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(wall.isOn ? Color(hex: 0x3A4420) : Theme.border))
    }

    private var hosts: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Hosts your agents reached").font(Theme.display(16, .semibold))
                Spacer()
                Text("Allow the ones you trust before switching to Block")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            let hosts = model.reachedHosts
            VStack(spacing: 0) {
                HStack {
                    Text("HOST").frame(maxWidth: .infinity, alignment: .leading)
                    Text("AGENT").frame(width: 150, alignment: .leading)
                    Text("SEEN").frame(width: 80, alignment: .leading)
                    Spacer().frame(width: 90)
                }
                .font(Theme.label).tracking(1).foregroundStyle(Theme.muted)
                .padding(.horizontal, 14).padding(.vertical, 9)
                if hosts.isEmpty {
                    Text(wall.isOn ? "Nothing yet: every host your agents used is allowed."
                                   : "Turn the wall on to see where your agents connect.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                ForEach(hosts) { h in
                    Divider().overlay(Color(hex: 0x1E2024))
                    HStack {
                        Text(h.host).font(Theme.mono).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(h.agentList).font(.system(size: 13)).lineLimit(1).frame(width: 150, alignment: .leading)
                        Text("\(h.count) time\(h.count == 1 ? "" : "s")").font(.system(size: 13))
                            .foregroundStyle(h.blocked ? Theme.coral : Theme.muted)
                            .frame(width: 80, alignment: .leading)
                        Button("Allow") { model.allowHost(h.host) }
                            .buttonStyle(LimeButtonStyle(subtle: true))
                            .frame(width: 90)
                            .disabled(model.busy)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
            .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(hex: 0x23252B)))
        }
    }
}

/// The storage wall is implemented (its decision engine is tested) but needs
/// Apple's Endpoint Security entitlement to actually block file opens, so it
/// ships off. This card says so rather than pretending the control is live.
private struct StoragePage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var storage: StorageWall

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(icon: "externaldrive", title: "Storage wall",
                       subtitle: "Stops agents opening protected files at all — even from a script, which the agent hooks can't catch. Machine-wide (every agent). macOS Endpoint Security.")
            Card(padding: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Storage wall").font(.system(size: 14, weight: .semibold))
                        Text(storage.summary).font(.system(size: 12))
                            .foregroundStyle(storage.isOn ? Theme.lime : Theme.muted)
                    }
                    Spacer()
                    Toggle("Storage wall", isOn: Binding(get: { storage.isOn },
                                                         set: { $0 ? storage.turnOn() : storage.turnOff() }))
                        .toggleStyle(KaiToggleStyle()).labelsHidden()
                        .disabled(storage.state == .activating || storage.state == .checking)
                }
            }
            if storage.needsFullDiskAccess {
                Card(padding: 14, stroke: Theme.amber.opacity(0.5)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("One more step: Full Disk Access").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                        Text("macOS requires Full Disk Access for the storage wall. Turn on Kai in the list, "
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
                ChoiceCards(options: [("log", "Watch", "Log what it would block. Never blocks."),
                                      ("block", "Block", "Deny agents those files."),
                                      ("off", "Off", "The wall is paused.")],
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
            PageHeader(icon: "doc.text", title: "Company data",
                       subtitle: "Words and names that must not reach a model. Matched in prompts and tool arguments.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(icon: "key", title: "Permissions",
                       subtitle: "Every active grant across sessions and projects, and the recent history of grants, uses, expiries and revocations. Grants are created only from Kai — never by an agent.")
            CapsLabel("Active grants")
            if grants.grantGroups.isEmpty {
                Text("No active grants.").font(.system(size: 13)).foregroundStyle(Theme.muted)
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
                            }
                            Spacer()
                            Button(g.count > 1 ? "Revoke all" : "Revoke") { grants.revokeGroup(g) }
                                .buttonStyle(GhostButtonStyle())
                        }
                    }
                }
            }
            CapsLabel("Recent history").padding(.top, 4)
            Picker("", selection: $filter) {
                Text("All").tag("all")
                Text("Granted").tag("granted")
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
    @State private var verifyResult: String?
    @AppStorage("activityFilter") private var filter = "all"
    @State private var expanded: Set<String> = []

    private var shown: [AuditEvent] {
        model.events.filter { e in
            guard !e.isNote else { return false } // shown under their block
            switch filter {
            case "agents": return !e.isNetwork
            case "network": return e.isNetwork
            default: return true
            }
        }
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
                        Text(a.intact ? "Audit log intact · \(a.records) records" : a.error)
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
            ForEach(shown.prefix(150)) { e in
                ActivityRow(event: e, followUp: model.followUp(for: e), expanded: expanded.contains(e.id)) {
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
            if let t = event.excerpt { ExcerptView(text: t, match: event.match, expanded: expanded) }
            if !event.detail.isEmpty {
                Text(event.detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                if event.isBlock || event.decision == "warn" { notAThreat }
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
