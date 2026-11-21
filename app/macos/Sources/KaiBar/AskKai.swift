// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Ask Kai, 0.4: the chat dock, the Ask Kai page (empty state, suggestions,
// chats per workspace) and the phraser choice. Answers come from AskEngine;
// a phraser (Apple Intelligence, a local model, or none) only rewords them.
// Chats stay on this Mac: ~/Library/Application Support/Kai/chats/*.json,
// kept 30 days.
import AppKit
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Chats

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, kai }
    var id = UUID().uuidString
    var role: Role
    var text: String
    var basedOn: String? = nil
    var actions: [AskAction] = []
    var phrasedBy: String? = nil
    var date = Date()
}

struct ChatThread: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var workspace: String?
    var title: String = "New chat"
    var created = Date()
    var updated = Date()
    var messages: [ChatMessage] = []
}

enum ChatStore {
    static let keepDays: Double = 30
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Kai/chats", isDirectory: true)
    }
    static func load() -> [ChatThread] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let cutoff = Date().addingTimeInterval(-keepDays * 86400)
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        var out: [ChatThread] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), let t = try? d.decode(ChatThread.self, from: data) else { continue }
            if t.updated < cutoff { try? fm.removeItem(at: f); continue }   // kept 30 days
            out.append(t)
        }
        return out.sorted { $0.updated > $1.updated }
    }
    static func save(_ t: ChatThread) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(t) else { return }
        let url = dir.appendingPathComponent("\(t.id).json")
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func delete(_ t: ChatThread) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(t.id).json"))
    }
}

// MARK: - Phrasers

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private struct FoundationModelsPhraser: AskPhraser {
    var kind: PhraserKind { .appleIntelligence }
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
    func phrase(_ prompt: PhrasePrompt) async throws -> String {
        guard isAvailable else { throw PhraserError.unavailable }
        let session = LanguageModelSession(instructions: prompt.system)
        let r = try await session.respond(to: prompt.user,
                                          options: GenerationOptions(temperature: 0.2,
                                                                     maximumResponseTokens: prompt.maxTokens))
        return r.content
    }
}
#endif

/// Apple Intelligence (Foundation Models, macOS 26+ with Apple Intelligence
/// on). Unavailable elsewhere, including builds made with an older SDK.
struct AppleIntelligencePhraser: AskPhraser {
    var kind: PhraserKind { .appleIntelligence }
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return FoundationModelsPhraser().isAvailable }
        #endif
        return false
    }
    func phrase(_ prompt: PhrasePrompt) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return try await FoundationModelsPhraser().phrase(prompt) }
        #endif
        throw PhraserError.unavailable
    }
}

enum Phrasers {
    /// Set by the local-model integration (LocalModel.swift) when it's built in.
    static var local: () -> AskPhraser? = { nil }

    static var defaultKind: PhraserKind { AppleIntelligencePhraser().isAvailable ? .appleIntelligence : .templates }

    static func make(_ kind: PhraserKind) -> AskPhraser {
        switch kind {
        case .appleIntelligence: return AppleIntelligencePhraser()
        case .local: return local() ?? TemplatePhraser()
        case .templates: return TemplatePhraser()
        }
    }

    /// The model's rewording is used only when it keeps every number of the
    /// record and stays short; otherwise the template text stands.
    static func accept(_ phrased: String, original: String) -> String? {
        let out = AskAnswer.untag(phrased).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, out.count <= max(240, original.count * 2) else { return nil }
        let nums: (String) -> Set<String> = { s in
            Set(s.split(whereSeparator: { !$0.isNumber }).map(String.init))
        }
        guard nums(original).isSubset(of: nums(out)) else { return nil }
        return out
    }
}

// MARK: - Controller

@MainActor
final class AskController: ObservableObject {
    static let shared = AskController()
    @Published private(set) var threads: [ChatThread] = ChatStore.load()
    @Published var currentID: String? = nil
    @Published private(set) var thinking = false
    @Published var modelRaw: String = UserDefaults.standard.string(forKey: "askModel") ?? "" {
        didSet { UserDefaults.standard.set(modelRaw, forKey: "askModel") }
    }

    var kind: PhraserKind { PhraserKind(rawValue: modelRaw) ?? Phrasers.defaultKind }
    var current: ChatThread? { threads.first { $0.id == currentID } }
    func threads(in workspace: String?) -> [ChatThread] { threads.filter { $0.workspace == workspace } }

    func newChat() { currentID = nil }
    func open(_ t: ChatThread) { currentID = t.id }
    func delete(_ t: ChatThread) {
        ChatStore.delete(t)
        threads.removeAll { $0.id == t.id }
        if currentID == t.id { currentID = nil }
    }

    func ask(_ question: String, context: AskContext) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var t = current ?? ChatThread(workspace: context.workspace,
                                      title: String(q.prefix(48)))
        t.messages.append(ChatMessage(role: .user, text: q))
        upsert(t)
        thinking = true
        defer { thinking = false }
        var ctx = context
        // Fetch kai why for the stops an answer may cite.
        for s in ctx.stops.prefix(3) {
            if let id = s.decision_id, ctx.why[id] == nil, let w = await KaiRecords.shared.why(id) { ctx.why[id] = w }
        }
        if let id = ctx.focus?.decisionID, ctx.why[id] == nil, let w = await KaiRecords.shared.why(id) { ctx.why[id] = w }
        let a = AskEngine.answer(q, ctx)
        var text = a.display, by: String? = nil
        let phraser = Phrasers.make(kind)
        if phraser.kind != .templates, phraser.isAvailable, a.intent != .outOfScope {
            if let out = try? await phraser.phrase(PhrasePrompts.make(question: q, answer: a.text)),
               let ok = Phrasers.accept(out, original: a.display) {
                text = ok; by = phraser.kind.title
            }
        }
        t.messages.append(ChatMessage(role: .kai, text: text, basedOn: a.basedOn, actions: a.actions, phrasedBy: by))
        t.updated = Date()
        upsert(t)
        MainNav.shared.askContext = nil
    }

    private func upsert(_ t: ChatThread) {
        if let i = threads.firstIndex(where: { $0.id == t.id }) { threads[i] = t } else { threads.insert(t, at: 0) }
        currentID = t.id
        ChatStore.save(t)
    }
}

// MARK: - Dock

struct ChatDock: View {
    let context: () -> AskContext
    @ObservedObject private var nav = MainNav.shared
    @ObservedObject private var ask = AskController.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let c = nav.askContext {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip").foregroundStyle(Theme.purple)
                    Text("About: \(c.title) · \(c.agent)").font(.system(size: 11.5)).lineLimit(1)
                    Button { nav.askContext = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(Theme.muted)
                    Spacer()
                }
                .frame(maxWidth: 815)
            }
            HStack(spacing: 9) {
                Text("Ask Kai").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.purple)
                TextField(nav.askContext == nil ? "Ask about activity, agents or decisions…" : "Ask about this record…",
                          text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(send)
                if ask.thinking { ProgressView().controlSize(.small) }
                Button("Ask", action: send).buttonStyle(LimeButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty && nav.askContext == nil)
            }
            .padding(.leading, 15).padding(.trailing, 6).padding(.vertical, 5)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border))
            .frame(maxWidth: 815)
            Text("Answers come only from what Kai recorded on this Mac. ⌘K to ask · ⌘J to hide")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(Theme.ink)
        .onChange(of: nav.focusChat) { _ in focused = true }
        .onAppear { if nav.focusChat > 0 { focused = true } }
    }

    private func send() {
        var q = text.trimmingCharacters(in: .whitespaces)
        if q.isEmpty, nav.askContext != nil { q = "Explain this" }
        guard !q.isEmpty else { return }
        text = ""
        nav.page = .ask
        let ctx = context()
        Task { await ask.ask(q, context: ctx) }
    }
}

// MARK: - Page

struct AskKaiPage: View {
    let context: () -> AskContext
    @EnvironmentObject var model: AppModel
    @ObservedObject private var ask = AskController.shared
    @ObservedObject private var nav = MainNav.shared

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let t = ask.current, !t.messages.isEmpty {
                            ForEach(t.messages) { m in bubble(m).id(m.id) }
                        } else {
                            hero
                        }
                    }
                    .padding(.horizontal, 38).padding(.vertical, 28)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: ask.current?.messages.count ?? 0) { _ in
                    if let last = ask.current?.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            chats.frame(width: 210)
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Text("What would you like to know?").font(.system(size: 26, weight: .semibold))
            Text("Ask about agents, recorded actions, or a decision Kai made.").foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                ForEach(AskEngine.suggestions, id: \.self) { s in
                    Button(s) { let c = context(); Task { await ask.ask(s, context: c) } }
                        .buttonStyle(GhostButtonStyle())
                }
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder private func bubble(_ m: ChatMessage) -> some View {
        if m.role == .user {
            HStack {
                Spacer(minLength: 80)
                Text(m.text).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(m.text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let b = m.basedOn {
                    Text("Based on: \(b)" + (m.phrasedBy.map { " · worded by \($0)" } ?? ""))
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                if !m.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(m.actions, id: \.self) { a in
                            Button(a.title) { perform(a) }.buttonStyle(LimeButtonStyle(subtle: true))
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border))
        }
    }

    /// Buttons come from the record (AskAnswer.actions), never from model text.
    private func perform(_ a: AskAction) {
        switch a.kind {
        case .openDecision:
            if let e = model.events.first(where: { $0.decision_id == a.ref || $0.id == a.ref }) { nav.openDecision = e }
            else { nav.page = .decisions }
        case .allowForSession:
            if let e = model.events.first(where: { $0.decision_id == a.ref || $0.id == a.ref }) { nav.openDecision = e }
        case .reconnect:
            if let ag = Agent(rawValue: a.ref) { model.setAgent(ag, enabled: true) }
        case .openActivity:
            if a.ref == "stops" { nav.page = .decisions; return }
            nav.filter = a.ref == "files" ? .files : a.ref == "connections" ? .connections : .all
            nav.page = .activity
        case .turnOnRecording:
            model.setSwitch("record_activity", "on")
        case .turnOnInternet:
            UserDefaults.standard.set(SettingsPage.internet.rawValue, forKey: "settingsPage")
            nav.page = .settings
        }
    }

    private var chats: some View {
        let workspace = context().workspace
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Chats").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
                Spacer()
                Button { ask.newChat() } label: { Label("New chat", systemImage: "square.and.pencil") }
                    .buttonStyle(.borderless).font(.system(size: 12))
            }
            .padding(.bottom, 4)
            let list = ask.threads(in: workspace)
            if list.isEmpty {
                Text("No chats in \(Workspaces.name(workspace)) yet.").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(list) { t in
                        HStack {
                            Button { ask.open(t) } label: {
                                Text(t.title).font(.system(size: 12)).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { ask.delete(t) } label: { Image(systemName: "trash").font(.system(size: 10)) }
                                .buttonStyle(.borderless).foregroundStyle(Theme.muted).help("Delete this chat")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(t.id == ask.currentID ? Theme.teal.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
            Text("Kept on this Mac for 30 days.").font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
        .padding(14)
        .background(Theme.sidebar)
    }
}

// MARK: - Settings → General

struct KaiGeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var ask = AskController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Binding(get: { model.recordingActivity },
                                         set: { model.setSwitch("record_activity", $0 ? "on" : "off") })) {
                        Text("Record agent activity").font(.system(size: 14, weight: .semibold))
                    }
                    .toggleStyle(KaiToggleStyle())
                    Text("Off by default. When on, Kai keeps one line per agent tool request: the agent, session, "
                         + "workspace, operation, the file path for file tools, the first word of a command, and "
                         + "the MCP server. Never file contents, arguments or full commands. Kept on this Mac for "
                         + "7 days.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    Text("Claude Code reports reads, edits and writes; Cursor reports reads but not its editor's "
                         + "writes; Codex reports commands and MCP calls, no file events.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ask Kai").font(.system(size: 14, weight: .semibold))
                    Text("Kai answers from its records first. A model only rewords that answer; it never decides "
                         + "anything and can't add actions. It receives only the answer and your question.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    Picker("Model", selection: Binding(get: { ask.kind }, set: { ask.modelRaw = $0.rawValue })) {
                        ForEach(PhraserKind.allCases) { k in
                            Text(k.title + (available(k) ? "" : " (not available)")).tag(k)
                        }
                    }
                    .frame(maxWidth: 380)
                    if ask.kind == .appleIntelligence && !AppleIntelligencePhraser().isAvailable {
                        Text("Apple Intelligence needs macOS 26 with Apple Intelligence turned on. Kai uses templates until then.")
                            .font(.system(size: 12)).foregroundStyle(Theme.amber)
                    }
                    if ask.kind == .local { LocalModelSettings() }
                }
            }
        }
    }

    private func available(_ k: PhraserKind) -> Bool {
        switch k {
        case .appleIntelligence: return AppleIntelligencePhraser().isAvailable
        case .local: return true   // downloadable on first use
        case .templates: return true
        }
    }
}
