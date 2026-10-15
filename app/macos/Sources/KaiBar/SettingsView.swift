// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let msg = model.errorMessage {
                ErrorBanner(message: msg) { model.errorMessage = nil }.padding([.horizontal, .top])
            }
            TabView {
                GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
                ProtectionTab().tabItem { Label("Protection", systemImage: "shield") }
                FilesTab().tabItem { Label("Files", systemImage: "folder.badge.minus") }
                NetworkTab().tabItem { Label("Network", systemImage: "network") }
                CompanyTab().tabItem { Label("Company Data", systemImage: "building.2") }
                ActivityTab().tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
            }
            .padding()
        }
        .frame(width: 680, height: 500)
        .task { await model.refresh() }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Agents") {
                ForEach(Agent.allCases) { AgentToggle(agent: $0) }
                Text("Turning an agent on adds Kai's hooks to its settings file and keeps a backup. Restart open agent sessions to pick up the change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("App") {
                Toggle("Notify me when Kai blocks something", isOn: $model.notifyOnBlock)
                Toggle("Open Kai at login", isOn: Binding(get: { model.launchAtLogin },
                                                          set: { model.launchAtLogin = $0 }))
            }
            Section("About") {
                LabeledContent("Version", value: model.status?.version ?? "—")
                LabeledContent("Command-line tool", value: model.cliPath ?? "not found")
                LabeledContent("Policy file", value: model.status?.policy.source ?? "—")
                HStack {
                    Button("Edit Policy File…") { model.openPolicyFile() }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Protection switches

private struct ProtectionTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                SwitchPicker(key: "secrets", title: "Secrets found in text",
                             help: "API keys, tokens, private keys, passwords and database URLs.",
                             options: [("redact", "Redact"), ("block", "Block"), ("warn", "Warn only"), ("off", "Off")])
                SwitchPicker(key: "on_prompt_secret", title: "Secret typed into a prompt",
                             help: "Stop the prompt before it reaches the model.",
                             options: [("block", "Block"), ("warn", "Warn only")])
                SwitchPicker(key: "on_file_secret", title: "Agent reads a file full of secrets",
                             options: [("block", "Block"), ("warn", "Warn only")])
                SwitchPicker(key: "on_upload", title: "Command that looks like data upload",
                             help: "For example curl -d @file, piping downloads into a shell, nc, scp.",
                             options: [("block", "Block"), ("ask", "Warn only")])
                SwitchPicker(key: "injection", title: "Prompt injection in tool results",
                             help: "Warns the agent that the text is untrusted. Never blocks.",
                             options: [("warn", "Warn agent"), ("off", "Off")])
            }
            if let p = model.policy, !p.ok {
                Section { Text(p.error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .disabled(model.busy || model.policy == nil)
    }
}

private struct SwitchPicker: View {
    @EnvironmentObject var model: AppModel
    let key: String
    let title: String
    var help: String? = nil
    let options: [(String, String)]

    var body: some View {
        Picker(selection: Binding(get: { model.policy?.switches[key] ?? options[0].0 },
                                  set: { model.setSwitch(key, $0) })) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let help { Text(help).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Protected files

private struct FilesTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            PathList(kind: "protect", title: "Agents may never read",
                     help: "Folders, files or patterns like *.pem and .env.*",
                     items: model.policy?.protect ?? [])
            PathList(kind: "allow", title: "Exceptions (always allowed)",
                     help: "Overrides the list on the left, e.g. .env.example",
                     items: model.policy?.allow ?? [])
        }
        .disabled(model.busy || model.policy == nil)
    }
}

private struct PathList: View {
    @EnvironmentObject var model: AppModel
    let kind: String
    let title: String
    let help: String
    let items: [String]
    var placeholder = "~/path or pattern"
    var canChoose = true
    @State private var newItem = ""
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(help).font(.caption).foregroundStyle(.secondary)
            List(items, id: \.self, selection: $selection) { Text($0).font(.system(.body, design: .monospaced)) }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                TextField(placeholder, text: $newItem)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                if canChoose { Button("Choose…", action: choose) }
                Button {
                    if let s = selection { model.remove(kind, s); selection = nil }
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                .help("Remove the selected entry")
            }
        }
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

// MARK: - Network

private struct NetworkTab: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wall: NetworkWall

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section {
                    NetworkWallToggle()
                    SwitchPicker(key: "egress", title: "Agent connections to hosts not on the list",
                                 help: "Start with Log to see what your agents reach, then switch to Block.",
                                 options: [("log", "Log only"), ("block", "Block"), ("off", "Off")])
                }
            }
            .formStyle(.grouped)
            .frame(height: 170)
            PathList(kind: "egress_allow", title: "Extra allowed hosts",
                     help: "Each host also covers its subdomains. Model APIs, GitHub and package registries are always allowed.",
                     items: model.policy?.egressAllow ?? [],
                     placeholder: "e.g. artifacts.example.com", canChoose: false)
        }
        .disabled(model.busy || model.policy == nil)
        .onAppear { wall.refresh() }
    }
}

// MARK: - Company data

private struct CompanyTab: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var action = "replace"
    @State private var replacement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Words and names that must not reach a model").font(.headline)
            Text("Matched case-insensitively in prompts and MCP tool arguments.")
                .font(.caption).foregroundStyle(.secondary)
            Table(model.policy?.terms ?? []) {
                TableColumn("Text") { Text($0.text) }
                TableColumn("Action") { t in
                    Text(t.action == "replace" ? "Replace with “\(t.replacement ?? "")”" : t.action.capitalized)
                }
                TableColumn("") { t in
                    Button { model.remove("term", t.text) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                .width(30)
            }
            .frame(minHeight: 150)
            HStack {
                TextField("e.g. Project Falcon", text: $text)
                Picker("", selection: $action) {
                    Text("Replace").tag("replace")
                    Text("Redact").tag("redact")
                    Text("Block").tag("block")
                    Text("Warn").tag("warn")
                }
                .labelsHidden()
                .frame(width: 100)
                if action == "replace" {
                    TextField("with, e.g. Project X", text: $replacement).frame(width: 150)
                }
                Button("Add") {
                    model.addTerm(text: text, action: action, replacement: replacement)
                    text = ""; replacement = ""
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty
                          || (action == "replace" && replacement.isEmpty))
            }
            if let rules = model.policy?.rules, !rules.isEmpty {
                Divider()
                Text("Pattern rules (edit in the policy file)").font(.headline)
                ForEach(rules, id: \.self) { r in
                    HStack {
                        Text(r.name).bold()
                        Text(r.pattern).font(.system(.caption, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Text(r.action).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .disabled(model.busy || model.policy == nil)
    }
}

extension PolicyInfo.Term: Identifiable {
    var id: String { text }
}

// MARK: - Activity

private struct ActivityTab: View {
    @EnvironmentObject var model: AppModel
    @State private var verifyResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let a = model.status?.audit {
                    Label(a.intact ? "Audit log intact: \(a.records) records" : a.error,
                          systemImage: a.intact ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(a.intact ? Color.primary : Color.red)
                }
                Spacer()
                Button("Verify") { Task { verifyResult = await model.verifyAuditLog() } }
                Button("Show in Finder") { model.revealAuditLog() }
            }
            if let v = verifyResult { Text(v).font(.caption).foregroundStyle(.secondary) }
            if model.events.isEmpty {
                Spacer()
                Text("No blocks or warnings yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(model.events) { EventRow(event: $0) }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
            }
        }
    }
}
