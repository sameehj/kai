// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Ask Kai: deterministic answers from Kai's records. The question is
// normalised (case, punctuation, a leading "=", "/" or "?"), common typos are
// corrected against Kai's own vocabulary (one edit, words of 5+ letters), and
// a synonym table picks ONE intent. The answer is built only from structured
// state (kai activity, the audit log's decisions, kai snapshot, kai status,
// policy switches, the walls), each with a "Based on: …" line.
//
// No model decides anything here. When a model is present it may (a) pick an
// intent label for a question the table didn't match, from the fixed list
// below, validated against it (the model sees only the question), and (b)
// reword the answer afterwards (AskPhraser.swift). Action buttons come from
// records, never from text, and never change a setting without the user
// clicking them.
//
// Foundation only: compiled into the app tests with AuditLog.swift and
// ActivityFeed.swift.
import Foundation

enum AskIntent: Equatable {
    case today, files, stops, agent(String), destinations, blindSpots, unknown, outOfScope
    // 0.4.1: Kai itself
    case kaiStatus, recording, internet, settings(String), version, help

    /// The fixed labels a model may answer with (model routing).
    static let labels = ["today", "files", "stops", "agent", "destinations", "coverage", "kai_status",
                         "recording", "internet", "settings", "version", "help", "out_of_scope", "unknown"]

    var label: String {
        switch self {
        case .today: return "today"
        case .files: return "files"
        case .stops: return "stops"
        case .agent: return "agent"
        case .destinations: return "destinations"
        case .blindSpots: return "coverage"
        case .kaiStatus: return "kai_status"
        case .recording: return "recording"
        case .internet: return "internet"
        case .settings: return "settings"
        case .version: return "version"
        case .help: return "help"
        case .outOfScope: return "out_of_scope"
        case .unknown: return "unknown"
        }
    }

    /// A label back to an intent; agent and settings take their argument from
    /// the question. nil: not one of the labels.
    init?(label: String, question: String) {
        let t = AskEngine.normalize(question)
        switch label {
        case "today": self = .today
        case "files": self = .files
        case "stops": self = .stops
        case "agent": self = .agent(AskEngine.agentIn(t) ?? "")
        case "destinations": self = .destinations
        case "coverage": self = .blindSpots
        case "kai_status": self = .kaiStatus
        case "recording": self = .recording
        case "internet": self = .internet
        case "settings": self = .settings(AskEngine.settingsTopic(t))
        case "version": self = .version
        case "help": self = .help
        case "out_of_scope": self = .outOfScope
        case "unknown": self = .unknown
        default: return nil
        }
    }
}

struct AskAction: Equatable, Codable, Hashable {
    enum Kind: String, Codable {
        case openDecision, allowForSession, reconnect, openActivity, turnOnRecording, turnOnInternet
        case openSettings   // 0.4.1: ref = "general", "internet", "advanced:agents", ...
        case blockSite      // 0.5.1: ref = the host (adds it to Blocked sites)
    }
    var kind: Kind
    var title: String
    /// Decision id / event id, agent key, filter or settings page, as the kind needs.
    var ref: String = ""
}

struct AskAnswer: Equatable {
    var intent: AskIntent
    /// Record values (paths, commands, hosts) are wrapped in <data> tags for
    /// the phraser; `display` is what the user reads.
    var text: String
    var basedOn: String
    var actions: [AskAction] = []
    /// Questions offered as tappable chips (help, unknown).
    var suggestions: [String] = []
    /// 0.5: coverage limits ("Cursor doesn't report edits."). Rendered by Kai
    /// under the answer, never passed to a model, so rewording can't drop them.
    var limits: [String] = []
    var display: String { AskAnswer.untag(text) }
    /// The deterministic footer under every answer: limits, then "Based on".
    var footer: [String] { limits.map { AskAnswer.untag($0) } + ["Based on: \(basedOn)"] }
    static func untag(_ s: String) -> String {
        s.replacingOccurrences(of: "<data>", with: "").replacingOccurrences(of: "</data>", with: "")
    }
}

/// One agent as Kai measured it (kai snapshot + kai status).
struct AskAgent: Equatable {
    var key: String
    var connected: Bool       // Kai's hooks installed and answering
    var running: Bool         // a session of it is running
    var working: Int          // sessions that ran something in the last 15 minutes
    var problem: String? = nil
    /// Codex: hooks installed, but Kai has no record of Codex calling them.
    var untrusted: Bool = false
}

/// Internet watching as the user's Mac reports it.
enum InternetState: Equatable { case off, needsApproval, on, failed(String) }

struct AskContext {
    var workspace: String?
    var recording: Bool
    var internetWatching: Bool
    var items: [ActivityItem]
    var stops: [AuditEvent]
    var agents: [AskAgent]
    /// `kai why` per decision id, when fetched.
    var why: [String: WhyRecord] = [:]
    /// A record the user dropped in with "Ask about this".
    var focus: ActivityItem? = nil
    // 0.4.1
    var version: String = ""
    var commit: String = ""
    var internet: InternetState? = nil
    /// The first activity record in today's list, when there is one.
    var recordingFirst: Date? = nil
    var policyProblem: String? = nil
    var paused: Bool = false
    /// 0.5: a session the user asked about (Now → Ask about this).
    var session: SessionFocus? = nil

    var internetState: InternetState { internet ?? (internetWatching ? .on : .off) }
}

/// After a settings change: did the re-read value match? nil = yes; else
/// the reason shown inline ("Kai couldn't turn on recording: <reason>").
enum SettingCheck {
    static func failure(expected: String, after: String?, error: String?) -> String? {
        if after == expected { return nil }
        if let e = error, !e.isEmpty { return e }
        return after.map { "the setting still reads “\($0)” after the change" } ?? "Kai couldn't read its settings back"
    }
}

enum AskEngine {
    static let suggestions = ["Which agents are working right now?", "What did agents change today?",
                              "Why did Kai stop something?", "Is Cursor connected?"]

    static let canAnswer = "Kai can answer: whether Kai is on and recording, what happened today, which files "
        + "agents read or changed, what Kai stopped and why, whether an agent is connected, whether Internet "
        + "watching is on, which destinations were contacted, what Kai can't see, which version this is, and "
        + "where a setting is."

    static let agentNames: [(String, [String])] = [
        ("claude", ["claude", "claude code"]), ("cursor", ["cursor"]), ("codex", ["codex"]),
    ]

    // MARK: normalising and matching

    /// Lowercase, curly quotes straightened, a leading "=", "/" or "?"
    /// dropped, other punctuation turned into spaces, spaces collapsed.
    static func normalize(_ q: String) -> String {
        var s = q.lowercased().replacingOccurrences(of: "’", with: "'")
        s = String(s.drop { "=/?!.:;,- \t\n".contains($0) })
        let kept = s.map { c -> Character in
            c.isLetter || c.isNumber || c == "'" || c == " " ? c : " "
        }
        let words = String(kept).split(separator: " ").map(String.init)
        return fixTypos(words).joined(separator: " ")
    }

    /// Damerau-Levenshtein distance (optimal string alignment).
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = i }
        for j in 0...y.count { d[0][j] = j }
        for i in 1...x.count {
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[x.count][y.count]
    }

    /// Words Kai's tables use: a token of 5+ letters within one edit of one
    /// of these is read as it.
    static let vocabulary: [String] = {
        var v = Set<String>()
        let all = Synonyms.all + agentNames.flatMap(\.1)
        for phrase in all { for w in phrase.split(separator: " ") { let x = w.replacingOccurrences(of: "*", with: ""); if x.count >= 5 { v.insert(x) } } }
        return v.sorted()
    }()

    static func fixTypos(_ words: [String]) -> [String] {
        words.map { w in
            guard w.count >= 5, !vocabulary.contains(w) else { return w }
            return vocabulary.first { abs($0.count - w.count) <= 1 && distance($0, w) <= 1 } ?? w
        }
    }

    /// Phrase match on whole words: " x " inside " text ".
    static func has(_ t: String, _ words: [String]) -> Bool {
        let padded = " " + t + " "
        return words.contains { padded.contains(" " + $0 + " ") || ($0.hasSuffix("*") && padded.contains(" " + $0.dropLast())) }
    }

    static func agentIn(_ t: String) -> String? {
        for (key, names) in agentNames where has(t, names) { return key }
        return nil
    }

    /// The synonym table, one list per intent ("word*" = any word starting so).
    enum Synonyms {
        static let help = ["help", "what can you answer", "what can you do", "what can i ask", "what do you know",
                           "what can you tell me", "what questions", "how does this work", "what are you"]
        static let settingsVerbs = ["turn off", "turn on", "switch off", "switch on", "disable", "enable",
                                    "configure", "set up", "setup", "settings", "setting", "preferences", "where do i",
                                    "how do i", "how can i", "how to", "stop recording", "stop watching", "opt out"]
        static let settingsTopics = ["recording", "record", "activity", "internet", "network", "watching", "agent",
                                     "agents", "hooks", "notification*", "sound*", "model", "apple intelligence",
                                     "llama", "kai", "check*", "protect*", "uninstall", "pause", "claude", "cursor",
                                     "codex", "language", "theme", "secrets", "files"]
        static let version = ["version", "which kai", "what kai is this", "kai version", "build", "release",
                              "what's new", "whats new", "up to date", "update"]
        static let recording = ["recording", "record*", "keeping a list", "keep a list", "logging activity",
                                "tracking", "track activity"]
        static let internet = ["internet watching", "watching the internet", "watching internet", "network filter",
                               "network extension", "internet on", "internet off", "is internet", "internet watch",
                               "internet enabled", "network watching", "watch the internet", "internet status"]
        static let statusWords = ["on", "off", "working", "running", "status", "health", "healthy", "doing",
                                  "enabled", "active", "ok", "okay", "alive", "checking", "protecting", "up",
                                  "broken", "fine", "ready", "protected"]
        static let blind = ["can't see", "cannot see", "can not see", "blind", "not see", "doesn't see", "coverage",
                            "limit*", "what can't", "invisible", "miss*", "what can you see", "what can kai see",
                            "can you see", "visibility", "what do you see", "what does kai see", "gaps", "what does it see",
                            "what can it see"]
        static let connected = ["connected", "connection to kai", "working", "running", "installed", "hooked",
                                "status", "connect*", "set up", "hooks", "checking", "checked", "protected", "protecting"]
        static let stops = ["stop*", "block*", "denied", "deny", "prevent*", "refuse*", "why"]
        static let destinations = ["destination*", "domain*", "host*", "network", "internet", "server*", "contact*",
                                   "url*", "website*", "connections", "sites", "traffic"]
        static let files = ["file*", "read", "reads", "changed", "change*", "edit*", "wrote", "write*", "modif*",
                            "touch*", "open*", "saved"]
        static let today = ["today", "happen*", "summary", "summari*", "what did", "recent*", "activity", "doing",
                            "going on", "this morning", "so far", "overview", "what has", "what have", "did"]
        static let commands = ["write", "fix", "implement", "refactor", "generate", "create", "build", "deploy",
                               "install", "delete", "rename", "translate", "summarize", "debug", "add", "make", "run"]
        static let all: [String] = help + settingsVerbs + settingsTopics + version + recording + internet + statusWords
            + blind + connected + stops + destinations + files + today
    }

    static func route(_ question: String) -> AskIntent {
        let t = normalize(question)
        guard !t.isEmpty else { return .help }
        let first = t.split(separator: " ").first.map(String.init) ?? ""
        let agent = agentIn(t)
        let aboutKai = has(t, ["kai", "you"]) || t.hasPrefix("is it ")

        if has(t, Synonyms.help) || t == "what can you answer" { return .help }
        // Settings questions are answered with where to change it, never by changing it.
        let asksToChange = has(t, Synonyms.settingsVerbs) || ["change", "set", "edit"].contains(first)
        if asksToChange && has(t, Synonyms.settingsTopics) && !has(t, ["what did", "which", "did"]) {
            return .settings(settingsTopic(t))
        }
        if Synonyms.commands.contains(first) && !has(t, ["recording", "record"])
            || has(t, ["write me", "write a", "code for", "how do i", "how to"]) {
            return .outOfScope
        }
        if has(t, ["version", "which kai", "what kai is this", "what's new", "whats new"])
            || (has(t, Synonyms.version) && aboutKai) { return .version }
        if has(t, Synonyms.recording) && !has(t, ["what did", "which files"]) { return .recording }
        if has(t, Synonyms.internet) { return .internet }
        if has(t, Synonyms.blind) {
            return .blindSpots
        }
        if agent == nil && (t == "status" || t == "health" || t == "kai"
            || (has(t, ["kai"]) && has(t, Synonyms.statusWords) && !has(t, Synonyms.stops))) {
            return .kaiStatus
        }
        if let a = agent, has(t, Synonyms.connected) && !has(t, ["what did", "today"]) { return .agent(a) }
        if agent == nil, has(t, ["connected", "installed", "hooked"]) { return .agent("") }
        if agent == nil, has(t, ["which agents", "what agents", "agents working", "working right now", "who is working",
                                 "any agent", "agents running", "is anyone working", "sessions"]) { return .agent("") }
        if has(t, Synonyms.stops) { return .stops }
        if has(t, Synonyms.files) { return .files }
        if has(t, Synonyms.destinations) { return .destinations }
        if has(t, Synonyms.today) { return .today }
        if let a = agent { return .agent(a) }
        return .unknown
    }

    /// Where a setting lives: the settings page ref for the action.
    static func settingsTopic(_ t: String) -> String {
        if has(t, ["recording", "record", "activity", "keep a list"]) { return "recording" }
        if has(t, ["internet", "network", "watching"]) { return "internet" }
        if has(t, ["notification*", "sound*"]) { return "app" }
        if has(t, ["model", "apple intelligence", "llama", "qwen", "ask kai", "answers"]) { return "model" }
        if has(t, ["uninstall", "remove kai"]) { return "uninstall" }
        if has(t, ["pause"]) { return "pause" }
        if has(t, ["check*", "protect*", "secrets", "files"]) { return "checks" }
        if agentIn(t) != nil || has(t, ["agent", "agents", "hooks"]) { return "agents" }
        return "general"
    }

    static func answer(_ question: String, _ c: AskContext, intent forced: AskIntent? = nil) -> AskAnswer {
        let intent = forced ?? route(question)
        let t = normalize(question)
        if let f = c.focus, intent != .outOfScope,
           intent == .unknown || has(t, ["this", "it", "that"]) {
            return about(f, c)
        }
        if let s = c.session, intent != .outOfScope,
           intent == .unknown || has(t, ["this", "it", "that", "session"]) {
            return aboutSession(s)
        }
        let agent = agentIn(t)
        switch intent {
        case .outOfScope:
            return AskAnswer(intent: .outOfScope,
                             text: "Kai only answers from what it recorded; ask your agent for help with the work itself.",
                             basedOn: "Nothing: this isn't a question about Kai's records.")
        case .stops: return stops(c, agent: agent)
        case .files: return files(c, agent: agent)
        case .destinations: return destinations(c)
        case .agent(let k): return self.agent(k, c)
        case .blindSpots: return blindSpots(c, agent: agent)
        case .today: return today(c, agent: agent)
        case .kaiStatus: return kaiStatus(c)
        case .recording: return recording(c)
        case .internet: return internet(c)
        case .settings(let topic): return settings(topic, c)
        case .version: return version(c)
        case .help:
            return AskAnswer(intent: .help, text: canAnswer, basedOn: "What Kai records on this Mac",
                             suggestions: suggestions)
        case .unknown:
            return AskAnswer(intent: .unknown,
                             text: "I can't answer that from Kai's records yet. Try one of these, or ask what "
                                + "Kai can answer.",
                             basedOn: "Nothing matched this question in Kai's records.",
                             suggestions: closest(t))
        }
    }

    /// Three questions for an unmatched one, from the intents whose words
    /// are closest to it.
    static func closest(_ t: String) -> [String] {
        let examples: [(String, [String])] = [
            ("Is Kai recording?", Synonyms.recording + ["kai", "list"]),
            ("Is Kai on?", Synonyms.statusWords + ["kai"]),
            ("What happened today?", Synonyms.today),
            ("What did Kai stop?", Synonyms.stops),
            ("Which files were changed?", Synonyms.files),
            ("Is Internet watching on?", Synonyms.internet + ["internet", "network"]),
            ("Which destinations were contacted?", Synonyms.destinations),
            ("What can't Kai see?", Synonyms.blind),
            ("Is Cursor connected?", Synonyms.connected),
        ]
        let words = t.split(separator: " ").map(String.init).filter { $0.count >= 3 }
        func score(_ keys: [String]) -> Int {
            let ks = keys.flatMap { $0.split(separator: " ") }.map { String($0).replacingOccurrences(of: "*", with: "") }
            return words.reduce(0) { n, w in
                n + (ks.contains { k in k.count >= 3 && (w.hasPrefix(k) || k.hasPrefix(w) || distance(k, w) <= 2) } ? 1 : 0)
            }
        }
        let ranked = examples.enumerated().map { (i, e) in (i, e.0, score(e.1)) }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
        return Array(ranked.prefix(3).map(\.1))
    }

    static var whereText: (AskContext) -> String = { c in
        c.workspace.map { " in " + ($0 as NSString).lastPathComponent } ?? ""
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// What each agent's hooks report, in a few words.
    static func reports(_ key: String) -> String {
        switch key {
        case "claude": return "reads, edits, writes"
        case "cursor": return "reads only (not its editor's writes)"
        case "codex": return "commands, no file events"
        default: return "no hook: nothing recorded"
        }
    }

    // MARK: Kai itself (0.4.1)

    static func recordingWords(_ c: AskContext) -> String {
        guard c.recording else { return "Activity recording is off" }
        return "Activity recording is on" + (c.recordingFirst.map { " (first record today at \(clock($0)))" } ?? "")
    }

    static func internetWords(_ c: AskContext) -> String {
        switch c.internetState {
        case .on: return InternetMode.current == .blocklist ? "Internet is on: Watch + block my list"
                                                            : "Internet watching is on (Watch only)"
        case .off: return "Internet watching is off"
        case .needsApproval: return "Internet watching is waiting for your OK in System Settings"
        case .failed(let why): return "Internet watching isn't on: \(why.sentenceEnded.dropLast())"
        }
    }

    static func kaiStatus(_ c: AskContext) -> AskAnswer {
        var lines: [String] = []
        let checked = c.agents.filter { $0.connected && !$0.untrusted }
        if let p = c.policyProblem {
            lines.append("Kai's policy has an error: \(p.sentenceEnded)")
        } else if c.paused {
            lines.append("Kai is paused; its checks resume by themselves.")
        } else if checked.isEmpty {
            lines.append("Kai is off: no agent is connected to its checks.")
        } else {
            lines.append("Kai is on: it checks " + AutoConnectWords.joined(checked.map { ActivityFeed.agentTitle($0.key) }) + ".")
        }
        if let u = c.agents.first(where: { $0.untrusted }) {
            lines.append("\(ActivityFeed.agentTitle(u.key)) is connected but not checked until you run /hooks in Codex once.")
        }
        let off = c.agents.filter { !$0.connected }.map { ActivityFeed.agentTitle($0.key) }
        if !off.isEmpty { lines.append("Not connected: " + AutoConnectWords.joined(off) + ".") }
        lines.append(recordingWords(c) + " · " + internetWords(c) + ".")
        var actions: [AskAction] = []
        if !c.recording { actions.append(AskAction(kind: .turnOnRecording, title: "Turn on activity recording")) }
        if c.internetState != .on { actions.append(AskAction(kind: .turnOnInternet, title: "Internet settings")) }
        return AskAnswer(intent: .kaiStatus, text: lines.prefix(4).joined(separator: "\n"),
                         basedOn: "kai status, kai snapshot and your settings", actions: actions)
    }

    static func recording(_ c: AskContext) -> AskAnswer {
        let cov = c.agents.map { "\(ActivityFeed.agentTitle($0.key)): \(reports($0.key))." }.joined(separator: " ")
        if c.recording {
            return AskAnswer(intent: .recording,
                             text: "Yes, " + recordingWords(c).prefix(1).lowercased() + recordingWords(c).dropFirst()
                                + ". " + cov + " Kai keeps paths and a command's first word, never file contents.",
                             basedOn: "Settings: record_activity, and kai activity")
        }
        return AskAnswer(intent: .recording,
                         text: "No, activity recording is off, so Kai keeps only what it stopped. Turn it on to "
                            + "keep a list of what agents read, edit and run, on this Mac only.",
                         basedOn: "Settings: record_activity is off",
                         actions: [AskAction(kind: .turnOnRecording, title: "Turn on activity recording")])
    }

    static func internet(_ c: AskContext) -> AskAnswer {
        let s = c.internetState
        var text = internetWords(c) + "."
        if s == .on { text += " Kai lists the destinations agents connect to; it doesn't read traffic or block anything." }
        if s == .off { text += " When on, Kai lists the destinations agents connect to (Watch only)." }
        return AskAnswer(intent: .internet, text: text, basedOn: "Network wall state on this Mac",
                         actions: s == .on ? [] : [AskAction(kind: .turnOnInternet, title: "Internet settings")])
    }

    static func settings(_ topic: String, _ c: AskContext) -> AskAnswer {
        let (place, ref): (String, String)
        switch topic {
        case "recording": (place, ref) = ("Settings → General → “Keep a list of what agents read, edit and run”", "general")
        case "internet": (place, ref) = ("Settings → Internet", "internet")
        case "app": (place, ref) = ("Settings → Advanced → App", "advanced:app")
        case "model": (place, ref) = ("the model menu next to the Ask button, or Settings → Ask Kai", "ask")
        case "uninstall": (place, ref) = ("Settings → Uninstall", "uninstall")
        case "pause": (place, ref) = ("the menu-bar popover → Pause 15 min", "")
        case "checks": (place, ref) = ("Settings → Rules", "rules")
        case "agents": (place, ref) = ("Settings → Agents (one switch per agent)", "agents")
        default: (place, ref) = ("Settings", "general")
        }
        return AskAnswer(intent: .settings(topic),
                         text: "Kai doesn't change settings from a chat. You'll find it in \(place).",
                         basedOn: "Kai's settings layout",
                         actions: (ref.isEmpty ? [] : [AskAction(kind: .openSettings, title: "Open Settings", ref: ref)])
                            + (topic == "recording" && !c.recording
                               ? [AskAction(kind: .turnOnRecording, title: "Turn on activity recording")] : []))
    }

    static func version(_ c: AskContext) -> AskAnswer {
        let v = c.version.isEmpty ? "an unknown version" : c.version
        return AskAnswer(intent: .version,
                         text: "This is Kai \(v)" + (c.commit.isEmpty ? "" : " (commit \(c.commit))") + ".",
                         basedOn: "kai status")
    }

    // MARK: records

    static func stops(_ c: AskContext, agent: String? = nil) -> AskAnswer {
        let s = c.stops.filter { agent == nil || $0.agentKey == agent }
        let who = agent.map { " for \(ActivityFeed.agentTitle($0))" } ?? ""
        guard !s.isEmpty else {
            return AskAnswer(intent: .stops,
                             text: "No matching record: Kai recorded no stops\(who)\(whereText(c)) today.",
                             basedOn: "Kai's decisions (audit log), today",
                             limits: ["No stop doesn't mean every action was checked."])
        }
        let lines = s.prefix(3).map { e -> String in
            // 0.5.1: Kai is the subject of every stop.
            let k = StopWords.kind(e)
            let obj = PhrasePrompts.data(ActivityFeed.stopItem(e, workspace: c.workspace).detail)
            let head = (k == .read || k == .change || k == .connection)
                ? StopWords.line(agent: e.agentName, kind: k, object: obj)
                : StopWords.line(agent: e.agentName, kind: k) + " (\(obj))"
            var l = head + ", because \(e.detail.trimmingCharacters(in: CharacterSet(charactersIn: ". ")))"
            if let id = e.decision_id, let r = c.why[id]?.retryLine { l += "; \(r.lowercased())" }
            return l + "."
        }
        let more = s.count > 3 ? " And \(s.count - 3) more in Activity → Stops." : ""
        var actions: [AskAction] = s.prefix(3).map {
            AskAction(kind: .openDecision, title: "Open decision", ref: $0.decision_id ?? $0.id)
        }
        if actions.count > 1 { actions = [AskAction(kind: .openActivity, title: "Open Stops", ref: "stops")] }
        return AskAnswer(intent: .stops,
                         text: "Kai recorded \(ActivityFeed.n(s.count, "stop"))\(who)\(whereText(c)) today. "
                            + lines.joined(separator: " ") + more,
                         basedOn: "Kai's decisions (audit log)" + (c.why.isEmpty ? "" : " and kai why") + ", today",
                         actions: actions)
    }

    static func files(_ c: AskContext, agent: String? = nil) -> AskAnswer {
        guard c.recording || c.items.contains(where: { [.read, .edit, .write].contains($0.kind) }) else {
            return AskAnswer(intent: .files,
                             text: "No matching record: activity recording is off, so Kai has no list of files "
                                + "agents read or changed. Kai still records what it stopped.",
                             basedOn: "Settings: activity recording is off",
                             actions: [AskAction(kind: .turnOnRecording, title: "Turn on activity recording")])
        }
        let f = c.items.filter { [.read, .edit, .write].contains($0.kind) && (agent == nil || $0.agentKey == agent) }
        guard !f.isEmpty else {
            let who = agent.map { " by \(ActivityFeed.agentTitle($0))" } ?? ""
            return AskAnswer(intent: .files,
                             text: "No matching record: Kai recorded no file reads or changes\(who)\(whereText(c)) today.",
                             basedOn: "kai activity, today", limits: fileLimits(c, agent: agent))
        }
        let lines = f.prefix(4).map { i in
            "\(i.agent) \(i.title.lowercased()): \(i.detail)"
                + (i.examples.isEmpty ? "" : " (for example \(PhrasePrompts.data(i.examples[0])))")
        }
        return AskAnswer(intent: .files,
                         text: lines.joined(separator: ". ") + ".",
                         basedOn: "kai activity (activity recording), today",
                         actions: [AskAction(kind: .openActivity, title: "Open Activity", ref: "files")],
                         limits: ["These are requests Kai saw through the agents' hooks, not every file access: "
                                  + "commands and scripts can touch other files."] + fileLimits(c, agent: agent))
    }

    /// What the agents asked about don't report about files (the coverage table).
    static func fileLimits(_ c: AskContext, agent: String?) -> [String] {
        let keys = agent.map { [$0] } ?? (c.agents.isEmpty ? ["cursor", "codex"] : c.agents.map(\.key))
        var out: [String] = []
        if keys.contains("cursor") { out.append("Cursor doesn't report its editor's writes.") }
        if keys.contains("codex") { out.append("Codex reports no file events.") }
        return out
    }

    static func destinations(_ c: AskContext) -> AskAnswer {
        guard c.internetWatching else {
            return AskAnswer(intent: .destinations,
                             text: "No matching record: Internet watching is off, so Kai has no list of "
                                + "destinations. It can't say which were or weren't contacted.",
                             basedOn: "Settings: Internet watching is off",
                             actions: [AskAction(kind: .turnOnInternet, title: "Internet settings")])
        }
        let n = c.items.filter { $0.kind == .connection }
        guard let g = n.first else {
            return AskAnswer(intent: .destinations,
                             text: "No matching record: Kai observed no connections today.",
                             basedOn: InternetMode.current.evidence + ", today")
        }
        // 0.5.1: Block site for the top destinations (Kai adds it to your list; never on its own).
        let hosts = g.examples.filter { !$0.hasPrefix("+ ") }.map { String($0.split(separator: " ").first ?? "") }
            .filter { !$0.isEmpty && $0 != "unknown" }
        let blocks = InternetMode.blocklistOffered
            ? hosts.prefix(3).map { AskAction(kind: .blockSite, title: "Block \($0)", ref: $0) } : []
        return AskAnswer(intent: .destinations,
                         text: "Kai observed \(g.countText) to \(g.detail.replacingOccurrences(of: " · watching only", with: "").replacingOccurrences(of: " · watching", with: "")): "
                            + g.examples.map(PhrasePrompts.data).joined(separator: ", ") + ".",
                         basedOn: InternetMode.current.evidence + ", today",
                         actions: [AskAction(kind: .openActivity, title: "Open Activity", ref: "connections")] + blocks,
                         limits: [InternetMode.current.connectionLimit])
    }

    static func agentWords(_ a: AskAgent) -> String {
        let name = ActivityFeed.agentTitle(a.key)
        if a.connected && a.untrusted {
            return "\(name) is connected, but Kai hasn't seen it use Kai's hook: not checked until you run /hooks in Codex once."
        }
        if a.connected {
            return "\(name) is connected" + (a.working > 0 ? " · \(a.working) working" : "") + "."
        }
        return "\(name) is not connected" + (a.running ? ", but it's running: activity unknown." : ": activity unavailable.")
            + (a.problem.map { " (\($0.sentenceEnded.dropLast()))" } ?? "")
    }

    static func agent(_ key: String, _ c: AskContext) -> AskAnswer {
        let rows = key.isEmpty ? c.agents : c.agents.filter { $0.key == key }
        guard !rows.isEmpty else {
            return AskAnswer(intent: .agent(key),
                             text: "No matching record: Kai didn't find \(ActivityFeed.agentTitle(key)) on this Mac.",
                             basedOn: "kai snapshot (agents found on this Mac)")
        }
        let actions = rows.filter { !$0.connected }.map {
            AskAction(kind: .reconnect, title: "Reconnect \(ActivityFeed.agentTitle($0.key))", ref: $0.key)
        }
        return AskAnswer(intent: .agent(key),
                         text: rows.map(agentWords).joined(separator: " "),
                         basedOn: "kai snapshot and kai status", actions: actions,
                         limits: ["Connected is about Kai's integration only; working means a connected agent ran a "
                                  + "command in the last 15 minutes."]
                            + rows.compactMap { AgentReports.footnote($0.key).map { $0.prefix(1).uppercased() + $0.dropFirst() + "." } })
    }

    static func blindSpots(_ c: AskContext, agent: String? = nil) -> AskAnswer {
        var s: [String] = []
        if let a = agent {
            s.append("\(ActivityFeed.agentTitle(a)): \(ActivityFeed.coverage(a))")
        }
        s.append("Kai's checks run inside each agent (hooks): a script or program the agent starts can read or "
                 + "change files Kai doesn't see.")
        if agent == nil {
            s.append("Claude Code reports reads, edits and writes; Cursor reports reads but not its editor's writes; "
                     + "Codex reports commands and MCP calls but no file events.")
        }
        s.append(InternetMode.current == .blocklist
                 ? "Internet: Kai refuses agents' direct connections to the sites on your block list and only records the rest; never what was sent."
                 : "Internet is Watch only: Kai can list destinations when watching is on, never what was sent.")
        if !c.recording { s.append("Activity recording is off, so Kai keeps only its stops.") }
        if !c.internetWatching { s.append("Internet watching is off.") }
        // The first sentence is the answer; the rest are limits Kai renders itself.
        return AskAnswer(intent: .blindSpots, text: s[0],
                         basedOn: "Kai's coverage notes (docs/COVERAGE.md) and your settings",
                         limits: Array(s.dropFirst()))
    }

    /// At most 4 lines: sessions per agent, what was recorded, stops, and
    /// the recording and Internet state.
    static func today(_ c: AskContext, agent: String? = nil) -> AskAnswer {
        var lines: [String] = []
        let agents = c.agents.filter { agent == nil || $0.key == agent }
        if !agents.isEmpty {
            lines.append(agents.map { a -> String in
                let name = ActivityFeed.agentTitle(a.key)
                if !a.connected { return "\(name): not connected" + (a.running ? " (running, activity unknown)" : "") }
                if a.untrusted { return "\(name): waiting for /hooks in Codex" }
                if a.working > 0 { return "\(name): \(ActivityFeed.n(a.working, "working session"))" }
                return "\(name): " + (a.running ? "idle" : "no session running")
            }.joined(separator: " · "))
        }
        let acts = c.items.filter { $0.kind != .stop && (agent == nil || $0.agentKey == agent) }
        if !acts.isEmpty {
            lines.append(acts.prefix(3).map { "\($0.agent): \($0.title.lowercased()), \($0.countText)" }.joined(separator: "; "))
        } else if !c.recording {
            lines.append("No list of reads, edits or commands: activity recording is off")
        } else {
            lines.append("No reads, edits or commands recorded\(whereText(c))" + (agent.map { " for \(ActivityFeed.agentTitle($0))" } ?? ""))
        }
        let stops = c.stops.filter { agent == nil || $0.agentKey == agent }
        lines.append(stops.isEmpty ? "Kai recorded no stops" : "Kai recorded \(ActivityFeed.n(stops.count, "stop"))")
        lines.append(recordingWords(c) + " · " + internetWords(c))
        let text = "Today\(whereText(c)):\n" + lines.prefix(4).map { $0.sentenceEnded }.joined(separator: "\n")
        var actions = [AskAction(kind: .openActivity, title: "Open Activity", ref: "all")]
        if !c.recording { actions.append(AskAction(kind: .turnOnRecording, title: "Turn on activity recording")) }
        return AskAnswer(intent: .today, text: text,
                         basedOn: (c.recording ? "kai activity, " : "") + "Kai's decisions, kai snapshot and your settings, today",
                         actions: actions,
                         limits: agents.filter(\.connected).compactMap { a in
                             AgentReports.footnote(a.key).map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }
                         })
    }

    /// Now → "Ask about this": the session, from its card's own numbers.
    static func aboutSession(_ s: SessionFocus) -> AskAnswer {
        var text = "\(s.agentTitle) in \(s.project)" + (s.tab.isEmpty ? "" : " (\(s.tab))") + ": \(s.state.lowercased())"
            + (s.started.isEmpty ? "" : ", \(s.started)") + "."
        if !s.recording {
            text += " Activity recording is off, so Kai kept only its stops for this session."
        } else {
            let counted = s.counts.filter { $0.notReportedBy == nil && $0.kind != .stops }.map(\.text)
            text += counted.isEmpty ? "" : " Kai recorded " + AutoConnectWords.joined(counted) + "."
            if let l = s.last { text += " Last: " + PhrasePrompts.data(l) + "." }
        }
        text += s.stops == 0 ? " Kai stopped nothing in it." : " Kai stopped \(ActivityFeed.n(s.stops, "request")) in it"
            + (s.stopLine.map { ", most recently: " + PhrasePrompts.data($0) } ?? "") + (s.stops == 0 ? "" : ".")
        if !s.topic.isEmpty { text += " Topic, as the agent reported it: " + PhrasePrompts.data(s.topic) + "." }
        return AskAnswer(intent: .unknown, text: text, basedOn: "kai snapshot and kai activity, this session",
                         actions: [AskAction(kind: .openActivity, title: "Open in Activity", ref: "session:" + s.id)],
                         limits: s.counts.compactMap { $0.notReportedBy == nil ? nil : $0.text.prefix(1).uppercased() + $0.text.dropFirst() + "." }
                            + ["Counts are requests Kai saw through \(s.agentTitle)'s hook, not everything it did."])
    }

    /// "Ask about this": the record dropped in, explained from itself.
    static func about(_ i: ActivityItem, _ c: AskContext) -> AskAnswer {
        var text = "\(i.title) (\(i.agent)): \(i.outcome.lowercased()). \(i.explanation)"
        if let id = i.decisionID, let r = c.why[id] {
            if let reason = r.reason, !reason.isEmpty { text += " Reason: \(reason.sentenceEnded)" }
            if let l = r.retryLine { text += " \(l.sentenceEnded)" }
        }
        var actions: [AskAction] = []
        if i.kind == .stop { actions.append(AskAction(kind: .openDecision, title: "Open decision", ref: i.decisionID ?? i.eventID ?? "")) }
        return AskAnswer(intent: .unknown, text: text, basedOn: i.source, actions: actions)
    }
}

/// "A, B and C" (kept here so AskEngine stays independent of AutoConnect).
enum AutoConnectWords {
    static func joined(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + " and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
