// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, protection, files, network, company, activity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .protection: return "Protection"
        case .files: return "Protected files"
        case .network: return "Network"
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
            PageHeader(icon: "shield", title: "Protection", subtitle: "What Kai does when it finds something sensitive.")
            SwitchRow(key: "secrets", title: "Secrets found in text",
                      help: "API keys, tokens, private keys, passwords and database URLs.",
                      options: [("redact", "Redact", "Replace with a marker"), ("block", "Block", "Stop the request"),
                                ("warn", "Warn", "Log only"), ("off", "Off", "Don't look")])
            SwitchRow(key: "on_prompt_secret", title: "Secret typed into a prompt",
                      help: "Stop the prompt before it reaches the model.",
                      options: [("block", "Block", "Prompt never sent"), ("warn", "Warn", "Log only")])
            SwitchRow(key: "on_file_secret", title: "Agent reads a file full of secrets",
                      help: "For files that aren't on the protected list.",
                      options: [("block", "Block", "Read denied"), ("warn", "Warn", "Log only")])
            SwitchRow(key: "on_upload", title: "Command that looks like a data upload",
                      help: "For example curl -d @file, piping downloads into a shell, nc, scp.",
                      options: [("block", "Block", "Command denied"), ("ask", "Warn", "Log only")])
            SwitchRow(key: "injection", title: "Prompt injection in tool results",
                      help: "Tells the agent the text is untrusted. Never blocks.",
                      options: [("warn", "Warn agent", "Add a caution"), ("off", "Off", "Don't look")])
            if let p = model.policy, !p.ok {
                Text(p.error).font(.system(size: 12)).foregroundStyle(Theme.coral)
            }
        }
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
            EditableList(kind: "egress_allow", title: "Your allowed hosts",
                         help: "Each also covers its subdomains. Model APIs, GitHub and package registries are built in.",
                         items: model.policy?.egressAllow ?? [], placeholder: "artifacts.yourcompany.com")
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

private struct ActivityPage: View {
    @EnvironmentObject var model: AppModel
    @State private var verifyResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(icon: "waveform.path.ecg", title: "Activity",
                       subtitle: "Everything Kai blocked, cleaned or noticed. The log never stores secret values.")
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
            if model.events.isEmpty {
                Text("No blocks, warnings or noticed hosts yet.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ForEach(model.events.prefix(150)) { e in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: e.isBlock ? "hand.raised.fill" : (e.decision == "log" ? "eye" : "exclamationmark.triangle.fill"))
                        .foregroundStyle(e.isBlock ? Theme.coral : (e.decision == "log" ? Theme.muted : Theme.amber))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.summary).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            if let d = e.date { Text(d, style: .relative) + Text(" ago") }
                            if !e.rule.isEmpty { Text("· \(e.rule)") }
                        }
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
