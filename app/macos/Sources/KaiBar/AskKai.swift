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
    /// 0.4.1: suggested questions (chips). Optional: older chats lack it.
    var suggestions: [String]? = nil
    /// 0.5: coverage limits, rendered by Kai under the answer (never by a model).
    var limits: [String]? = nil

    /// The deterministic footer: limits, then "Based on" (and who worded it).
    var footer: [String] {
        (limits ?? []) + (basedOn.map { ["Based on: \($0)" + (phrasedBy.map { " · worded by \($0)" } ?? "")] } ?? [])
    }
}

struct ChatThread: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var workspace: String?
    var title: String = "New chat"
    var created = Date()
    var updated = Date()
    var messages: [ChatMessage] = []
    /// 0.5.1: the item an "Ask about this" thread started from, shown as a
    /// quoted chip at the top (never a full command or file contents).
    var quote: String? = nil
    var quoteAgent: String? = nil
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
    /// Set at launch by LocalModelChoice.register().
    static var localInstalled: () -> Bool = { false }
    static var localName: () -> String = { "local model" }

    /// Apple Intelligence when available, else a downloaded local model,
    /// else templates. The user's choice in Settings overrides this.
    static var defaultKind: PhraserKind {
        if AppleIntelligencePhraser().isAvailable { return .appleIntelligence }
        return localInstalled() ? .local : .templates
    }

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
    /// "Loading model…" while the model loads for its first answer.
    @Published private(set) var modelStatus: String?
    private var warm = Set<String>()
    @Published var modelRaw: String = UserDefaults.standard.string(forKey: "askModel") ?? "" {
        didSet { UserDefaults.standard.set(modelRaw, forKey: "askModel") }
    }

    var kind: PhraserKind { PhraserKind(rawValue: modelRaw) ?? Phrasers.defaultKind }

    /// What the Ask header says answers come from.
    var sourceTitle: String {
        let p = Phrasers.make(kind)
        guard p.kind != .templates, p.isAvailable else { return "Templates" }
        return p.kind == .appleIntelligence ? "Apple Intelligence" : "Local model · " + Phrasers.localName()
    }
    var usingModel: Bool { sourceTitle != "Templates" }

    /// A short message from Kai in the current chat (an action's result);
    /// starts a chat when there is none.
    func note(_ text: String) {
        var t = current ?? ChatThread(workspace: nil, title: String(text.prefix(48)))
        t.messages.append(ChatMessage(role: .kai, text: text))
        t.updated = Date()
        upsert(t)
    }
    var current: ChatThread? { threads.first { $0.id == currentID } }
    func threads(in workspace: String?) -> [ChatThread] { threads.filter { $0.workspace == workspace } }

    func newChat() { currentID = nil }
    /// 0.5.1: "Ask about this" always opens a new thread, titled after the
    /// item and starting with it as a quoted chip; never the current thread.
    func startThread(title: String, quote: String, agent: String?) {
        var t = ChatThread(workspace: nil, title: String(title.prefix(48)))
        t.quote = quote
        t.quoteAgent = agent
        upsert(t)
    }
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
        if ctx.session != nil && !t.title.hasPrefix("About ") { t.title = "About \(ctx.session!.agentTitle) · \(ctx.session!.project)" }
        let phraser = Phrasers.make(kind)
        let modelOn = phraser.kind != .templates && phraser.isAvailable
        let warmKey = phraser.kind.rawValue + Phrasers.localName()
        var intent = AskEngine.route(q)
        // Model routing: only for a question the table didn't match, only the
        // question text, only a label from the fixed list. The answer is still
        // built from records. Skipped while the model is still loading.
        if intent == .unknown, ctx.focus == nil, ctx.session == nil, modelOn, warm.contains(warmKey),
           let reply = try? await phraser.phrase(PhrasePrompts.classify(question: q)) {
            intent = PhrasePrompts.intent(fromModel: reply, question: q)
        }
        let a = AskEngine.answer(q, ctx, intent: intent)
        // The limits and "Based on" are Kai's own footer: the model never sees
        // them (PhrasePrompts.make gets a.text only), so it can't drop them.
        let msg = ChatMessage(role: .kai, text: a.display, basedOn: a.basedOn, actions: a.actions,
                              suggestions: a.suggestions.isEmpty ? nil : a.suggestions,
                              limits: a.limits.isEmpty ? nil : a.limits.map(AskAnswer.untag))
        t.messages.append(msg)
        t.updated = Date()
        upsert(t)
        MainNav.shared.askContext = nil
        MainNav.shared.askSession = nil
        // The template answer shows at once; a model's rewording replaces it
        // when it arrives and keeps every number (Phrasers.accept).
        guard modelOn, a.intent != .outOfScope, a.intent != .unknown else { return }
        if !warm.contains(warmKey) { modelStatus = "Loading model…" }
        let threadID = t.id, messageID = msg.id
        Task {
            let out = try? await phraser.phrase(PhrasePrompts.make(question: q, answer: a.text))
            warm.insert(warmKey)
            modelStatus = nil
            guard let out, let ok = Phrasers.accept(out, original: a.display),
                  var th = threads.first(where: { $0.id == threadID }),
                  let i = th.messages.firstIndex(where: { $0.id == messageID }) else { return }
            th.messages[i].text = ok
            th.messages[i].phrasedBy = phraser.kind.title
            if let k = threads.firstIndex(where: { $0.id == threadID }) { threads[k] = th }
            ChatStore.save(th)
        }
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

    private var placeholder: String {
        if let s = nav.askSession { return "Ask about this \(s.agentTitle) session…" }
        if nav.askContext != nil { return "Ask about this record…" }
        return "Ask about activity, agents or decisions…"
    }

    var body: some View {
        VStack(spacing: 6) {
            if let s = nav.askSession {
                contextChip(agent: s.agent, text: "About: \(s.agentTitle) · \(s.project)" + (s.tab.isEmpty ? "" : " · \(s.tab)")) {
                    nav.askSession = nil
                }
            } else if let c = nav.askContext {
                contextChip(agent: c.agentKey, text: "About: \(c.title) · \(c.agent)") { nav.askContext = nil }
            }
            HStack(spacing: 9) {
                Text("Ask Kai").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.purple)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(send)
                if ask.thinking { ProgressView().controlSize(.small) }
                ModelChooser(style: .chip)
                Button("Ask", action: send).buttonStyle(LimeButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty && nav.askContext == nil && nav.askSession == nil)
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

    private func contextChip(agent: String, text: String, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            if agent.isEmpty { Image(systemName: "paperclip").foregroundStyle(Theme.muted) }
            else { AgentLogo(agent: agent, size: 16) }
            Text(text).font(.system(size: 11.5)).lineLimit(1)
            Button(action: clear) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(Theme.muted)
            Spacer()
        }
        .frame(maxWidth: 815)
    }

    private func send() {
        var q = text.trimmingCharacters(in: .whitespaces)
        if q.isEmpty, nav.askContext != nil || nav.askSession != nil { q = "Explain this" }
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
    @EnvironmentObject var wall: NetworkWall
    @ObservedObject private var ask = AskController.shared
    @ObservedObject private var nav = MainNav.shared
    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        ModelFirstRunCard()
                        if let t = ask.current, !t.messages.isEmpty || t.quote != nil {
                            if let q = t.quote { QuoteChip(text: q, agent: t.quoteAgent) }
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
        .confirmationDialog("Turn on blocking for your list?", isPresented: $askTurnOn) {
            Button("Turn on Watch + block my list") { model.setSwitch("egress", InternetMode.blocklist.egress) }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("In Watch, Kai only records connections. With Watch + block my list it also refuses agents' direct connections to the sites on your list.")
        }
    }
    @State private var askTurnOn = false

    /// "Ask Kai", the model chip (where answers come from) and New chat.
    private var header: some View {
        HStack(spacing: 10) {
            Text("Ask Kai").font(.system(size: 18, weight: .semibold))
            ModelChooser(style: .chip)
            ask.modelStatus.map { Text($0).font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
            Spacer()
            Button { ask.newChat() } label: { Label("New chat", systemImage: "square.and.pencil") }
                .buttonStyle(GhostButtonStyle())
        }
    }

    /// An action is shown only while the state it offers isn't already true.
    private func stillUseful(_ a: AskAction) -> Bool {
        switch a.kind {
        case .turnOnRecording: return !model.recordingActivity
        case .turnOnInternet: return !wall.isOn
        case .blockSite: return !BlockList.shared.contains(a.ref)
        case .reconnect: return Agent(rawValue: a.ref).map { !model.installed($0) } ?? true
        default: return true
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image("KaiLogo").resizable().frame(width: 46, height: 46).accessibilityHidden(true)
            Text("What would you like to know?").font(.system(size: 26, weight: .semibold))
            Text("Ask about a session, a connection or a stopped action.").foregroundStyle(Theme.muted)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(AskEngine.suggestions, id: \.self) { s in
                    Button { let c = context(); Task { await ask.ask(s, context: c) } } label: {
                        Text(s).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }
            .frame(maxWidth: 520)
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
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
                // Kai's own footer: limits and "Based on", never model text.
                ForEach(Array(m.footer.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let live = m.actions.filter(stillUseful)
                if !live.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(live, id: \.self) { a in
                            Button(a.title) { perform(a) }.buttonStyle(LimeButtonStyle(subtle: true))
                        }
                    }
                }
                if let chips = m.suggestions, !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { s in
                            Button(s) { let c = context(); Task { await ask.ask(s, context: c) } }
                                .buttonStyle(GhostButtonStyle())
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
        case .blockSite:
            BlockList.shared.add(a.ref, model: model)
            if BlockList.shared.offerTurnOn { BlockList.shared.offerTurnOn = false; askTurnOn = true }
        case .openDecision:
            if let e = model.events.first(where: { $0.decision_id == a.ref || $0.id == a.ref }) { nav.openDecision = e }
            else { nav.showStops() }
        case .allowForSession:
            if let e = model.events.first(where: { $0.decision_id == a.ref || $0.id == a.ref }) { nav.openDecision = e }
        case .reconnect:
            if let ag = Agent(rawValue: a.ref) { model.setAgent(ag, enabled: true) }
        case .openActivity:
            if a.ref == "stops" { nav.showStops(); return }
            if a.ref.hasPrefix("session:"),
               let s = AgentsModel.shared.sessions.first(where: { $0.id == String(a.ref.dropFirst(8)) }) {
                nav.showActivity(session: s.id, agent: s.agent); return
            }
            nav.filter = a.ref == "files" ? .files : a.ref == "connections" ? .connections : .all
            nav.sessionFilter = nil
            nav.page = .activity
        case .turnOnRecording:
            Task {
                if let why = await model.setSwitchVerified("record_activity", "on") {
                    ask.note("Kai couldn't turn on recording: \(why.sentenceEnded)")
                } else {
                    ask.note("Activity recording is on. From now on Kai keeps a list of reads, edits and commands. "
                             + "Earlier activity wasn't recorded.")
                }
            }
        case .turnOnInternet:
            UserDefaults.standard.set(SettingsPage.internet.rawValue, forKey: "settingsPage")
            nav.page = .settings
        case .openSettings:
            let parts = a.ref.split(separator: ":").map(String.init)
            UserDefaults.standard.set(SettingsPage(stored: parts.first ?? "general").rawValue, forKey: "settingsPage")
            if parts.count > 1 { UserDefaults.standard.set(parts[1], forKey: "advancedSection") }
            nav.page = .settings
        }
    }

    private var chats: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Chats").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
                Spacer()
            }
            .padding(.bottom, 4)
            // 0.5: every project is in scope, so every chat is listed.
            let list = ask.threads
            if list.isEmpty {
                Text("No chats yet.").font(.system(size: 11)).foregroundStyle(Theme.muted)
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep a list of what agents read, edit and run").font(.system(size: 14, weight: .semibold))
                            Text("Stored only on this Mac. No file contents.").font(.system(size: 12)).foregroundStyle(Theme.soft)
                        }
                    }
                    .toggleStyle(KaiToggleStyle())
                    if let e = model.errorMessage { Text(e).font(.system(size: 12)).foregroundStyle(Theme.amber) }
                    Text("On by default. Kai keeps one line per agent tool request: the agent, session, "
                         + "workspace, operation, the file path for file tools, the first word of a command, and "
                         + "the MCP server. Never file contents, arguments or full commands. Kept for 7 days.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    Text("Claude Code reports reads, edits and writes; Cursor reports reads but not its editor's "
                         + "writes; Codex reports commands and MCP calls, no file events.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Card(padding: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask Kai").font(.system(size: 14, weight: .semibold))
                        Text("Which model words answers: Settings → Ask Kai, or the model menu next to Ask.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    ModelChooser(style: .chip)
                }
            }
        }
    }

}

/// The item an "Ask about this" thread is about, quoted at its top.
struct QuoteChip: View {
    let text: String
    let agent: String?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle().fill(Theme.purple.opacity(0.6)).frame(width: 3)
            if let a = agent, !a.isEmpty { AgentLogo(agent: a, size: 16) }
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.soft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8).padding(.trailing, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border))
    }
}

#if DEBUG
extension AskController {
    func loadFixture(_ threads: [ChatThread]) {
        self.threads = threads
        currentID = threads.first?.id
    }
}
#endif
