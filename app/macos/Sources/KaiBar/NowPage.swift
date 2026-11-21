// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.5: Now (the home screen) and Activity (one timeline). Data: NowData /
// NowBuilder and Timeline (NowModel.swift), from kai snapshot, kai activity
// and Kai's decisions. Evidence words stay as they are: hook requests are
// "Requested", Kai's decisions "Stopped", connections "Observed".
import AppKit
import SwiftUI
import KaiCore

// MARK: - Now

struct NowPageView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var agents = AgentsModel.shared
    @ObservedObject private var records = KaiRecords.shared
    @ObservedObject private var nav = MainNav.shared
    @State private var showEarlier = false
    @State private var tick = Date()

    var body: some View {
        let sections = NowData.sections(model)
        let summary = NowSummary.of(sections)
        let ended = NowBuilder.endedToday(agents.sessions, now: tick)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Now").font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Text(summary.text).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                Text("Your agent sessions, across all projects.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .padding(.top, 2).padding(.bottom, 18)
                if !agents.loaded {
                    ProgressView().controlSize(.small)
                } else if let err = agents.sourceError {
                    Text("Kai can't list sessions right now: \(err)").font(.system(size: 12)).foregroundStyle(Theme.amber)
                } else if sections.isEmpty {
                    emptyState
                }
                if let note = model.connectedNote { ConnectedNote(text: note).padding(.bottom, 10) }
                if !model.recordingActivity { recordingOffBar.padding(.bottom, 12) }
                ForEach(sections) { sec in
                    SectionLine(text: sec.line, agent: sec.agent)
                    ForEach(sec.cards) { c in SessionCardView(card: c, recording: model.recordingActivity, now: tick) }
                }
                ForEach(idleAgents(sections)) { a in
                    SectionLine(text: LiveCoverage.title(a.name), agent: a.name)
                    AgentSlimRow(agent: a)
                }
                if !ended.isEmpty {
                    Button { withAnimation { showEarlier.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showEarlier ? "chevron.down" : "chevron.right").font(.system(size: 10))
                            Text("Earlier today (\(ended.count))").font(.system(size: 12, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(Theme.muted).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.top, 18).padding(.bottom, 6)
                    if showEarlier {
                        RecordList {
                            ForEach(Array(ended.enumerated()), id: \.element.id) { i, s in
                                if i > 0 { Divider() }
                                EndedRow(session: s) { nav.showActivity(session: s.id, agent: s.agent) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 38).padding(.vertical, 30)
            .frame(maxWidth: 890, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                tick = Date()
            }
        }
    }

    /// Connected agents with no live session: one slim row each.
    private func idleAgents(_ sections: [NowSection]) -> [AgentRow] {
        let running = Set(sections.map(\.agent))
        return (model.displayAgents(agents) ?? []).filter { a in
            a.detected && (a.hooks == "installed" || a.hooks == "untrusted") && !running.contains(a.name)
        }
    }

    private var emptyState: some View {
        let connected = (model.displayAgents(agents) ?? []).filter { $0.detected && ($0.hooks == "installed" || $0.hooks == "untrusted") }
        return VStack(alignment: .leading, spacing: 6) {
            Text(NowBuilder.emptyText(connected: connected.map(\.name)))
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Text("Earlier sessions are in Activity.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            if connected.isEmpty {
                Button("Settings → Agents") { nav.go(.settings(.agents)) }.buttonStyle(LimeButtonStyle(subtle: true))
                    .padding(.top, 4)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.border))
        .padding(.bottom, 14)
    }

    private var recordingOffBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle").foregroundStyle(Theme.muted)
            Text("Recording is off: Kai keeps only stops.").font(.system(size: 12.5))
            Spacer()
            Button("Turn on") { model.setSwitch("record_activity", "on") }.buttonStyle(LimeButtonStyle(subtle: true))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.border))
    }
}

/// "Claude Code · 2 working", with the agent's logo.
struct SectionLine: View {
    let text: String
    let agent: String
    var body: some View {
        HStack(spacing: 7) {
            AgentLogo(agent: agent, size: 16)
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(.top, 14).padding(.bottom, 7)
    }
}

/// One live session.
struct SessionCardView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var nav = MainNav.shared
    let card: NowCard
    let recording: Bool
    let now: Date
    @State private var hover = false

    var body: some View {
        let s = card.session
        let stopped = card.stopCount > 0 || (card.activity?.stops ?? 0) > 0
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                AgentLogo(agent: card.agentKey, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(s.displayAgent).font(.system(size: 13.5, weight: .semibold))
                        Text("· " + [card.project, s.tab].filter { !$0.isEmpty && $0 != "—" }.joined(separator: " · "))
                            .font(.system(size: 13)).foregroundStyle(Theme.soft).lineLimit(1)
                    }
                    // The most important line: what it's doing now.
                    lastLine
                    if !s.topicLine.isEmpty {
                        Text("“\(s.topicLine)”").font(.system(size: 12)).foregroundStyle(Theme.soft).lineLimit(1)
                            .help("Topic as reported by \(s.displayAgent)")
                    }
                    Text(card.started(now: now)).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                StatePill(text: card.statePill(now: now), working: card.working)
            }
            if recording {
                HStack(spacing: 6) {
                    ForEach(card.counts.filter { $0.notReportedBy == nil && !($0.kind == .stops && ($0.value ?? 0) == 0) },
                            id: \.kind) { c in CountChip(text: c.text, stop: c.kind == .stops) }
                }
            }
            if let e = card.latestStop {
                Button { nav.openDecision = e } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.raised.fill").font(.system(size: 10.5)).foregroundStyle(Theme.amber)
                        Text("Kai " + NowCard.stopLine(e)).font(.system(size: 12)).foregroundStyle(Theme.text)
                        if let d = e.date { Text("· " + LastAction.ago(now.timeIntervalSince(d))).font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !card.children.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(card.children) { c in
                        Text("↳ " + (c.kind == "nested" ? "Nested session" : "Background service")
                             + (c.isWorking ? " · working" : " · idle"))
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
            }
            Divider().opacity(0.6)
            HStack(spacing: 8) {
                if let note = AgentReports.footnote(card.agentKey) {
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Ask about this") { nav.ask(aboutSession: card.focus(now: now, recording: recording)) }
                    .buttonStyle(GhostButtonStyle()).controlSize(.small)
                Button("Open →") { nav.showActivity(session: s.id, agent: s.agent) }
                    .buttonStyle(LimeButtonStyle(subtle: true))
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.border))
        .overlay(alignment: .top) {
            if stopped {   // any stop: an amber top border
                Rectangle().fill(Theme.amber).frame(height: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .padding(.bottom, 10)
    }

    @ViewBuilder private var lastLine: some View {
        if !recording {
            HStack(spacing: 6) {
                Text("Recording is off: Kai keeps only stops,").font(.system(size: 12.5)).foregroundStyle(Theme.soft)
                Button("Turn on") { model.setSwitch("record_activity", "on") }
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.teal)
            }
        } else if let l = card.lastLine(now: now) {
            Text(l).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
        } else {
            Text(card.agentKey == "codex" ? "No command recorded yet" : "Nothing recorded yet in this session")
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
        }
    }
}

struct StatePill: View {
    let text: String
    let working: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(working ? Theme.teal : Theme.muted).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(working ? Theme.teal : Theme.muted)
        }
        .padding(.horizontal, 9).padding(.vertical, 3.5)
        .background((working ? Theme.teal : Theme.muted).opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

struct CountChip: View {
    let text: String
    var stop = false
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(stop ? Theme.amber : Theme.soft)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.raised.opacity(0.7), in: Capsule())
    }
}

/// A connected agent with no session today: "Codex · connected · not running today".
struct AgentSlimRow: View {
    @EnvironmentObject var model: AppModel
    let agent: AgentRow
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AgentLogo(agent: agent.name, size: 16)
                Text("\(LiveCoverage.title(agent.name)) · connected · not running today")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.soft)
                Spacer()
            }
            if agent.name == "codex" && model.codexNeedsTrust { CodexTrustRow() }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.border))
        .padding(.bottom, 8)
    }
}

struct EndedRow: View {
    let session: SessionRow
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                AgentLogo(agent: session.agent, size: 16)
                Text("\(session.displayAgent) · \(session.projectName)").font(.system(size: 12.5))
                Spacer()
                let f = { (t: Int) -> String in
                    let d = DateFormatter(); d.dateFormat = "HH:mm"
                    return d.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
                }
                Text(session.startedUtc > 0 ? "\(f(session.startedUtc))–\(f(session.endedUtc))" : "ended \(f(session.endedUtc))")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Activity

struct ActivityTimelineView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wall: NetworkWall
    @ObservedObject private var nav = MainNav.shared
    @ObservedObject private var records = KaiRecords.shared
    @ObservedObject private var agents = AgentsModel.shared

    private var all: [TimelineGroup] {
        Timeline.groups(records: records.groups?.sessions ?? [], sessions: agents.sessions, events: model.events,
                        internetWatching: wall.isOn)
    }

    private func filtered(_ gs: [TimelineGroup]) -> [TimelineGroup] {
        gs.compactMap { g in
            if let a = nav.agentFilter, g.agent != a { return nil }
            if let s = nav.sessionFilter, g.sessionID != s { return nil }
            if let p = nav.projectFilter, g.id != "net", !ActivityFeed.inWorkspace(g.projectPath, p) { return nil }
            var g = g
            let q = nav.search.trimmingCharacters(in: .whitespaces).lowercased()
            g.events = g.events.filter { e in
                nav.filter.matches(e.kind) && (q.isEmpty || e.title.lowercased().contains(q) || e.object.lowercased().contains(q))
            }
            return g.events.isEmpty ? nil : g
        }
    }

    var body: some View {
        let groups = all
        let shown = filtered(groups)
        let recording = model.recordingActivity || (records.groups?.recording ?? false)
        PageColumn(title: "Activity", subtitle: Text("What Kai recorded today, across ")
                    + Text(nav.projectFilter.map { ($0 as NSString).lastPathComponent } ?? "all projects").bold()) {
            filterBar(groups)
                .padding(.bottom, 13)
            if let late = Timeline.recordingLate(firstRecord: records.groups?.first_record, sessions: agents.sessions),
               recording {
                Text(late).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.bottom, 10)
            }
            if !recording && !shown.isEmpty { recordingOff.padding(.bottom, 12) }
            if shown.isEmpty {
                empty(anyEvents: groups.contains { !$0.events.isEmpty }, recording: recording)
            } else {
                ForEach(shown) { g in
                    HStack(spacing: 7) {
                        if g.agent.isEmpty { Image(systemName: "network").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                        else { AgentLogo(agent: g.agent, size: 16) }
                        Text(g.agent.isEmpty ? "Connections · Internet watching · today" : g.header(now: Date()))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                        Spacer()
                        if g.events.count > 1 { Text(ActivityFeed.n(g.events.count, "event")).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                    }
                    .padding(.top, 12).padding(.bottom, 7)
                    RecordList {
                        ForEach(Array(g.events.prefix(60).enumerated()), id: \.element.id) { i, e in
                            if i > 0 { Divider() }
                            TimelineRow(event: e) { open(e) }
                        }
                    }
                }
            }
            if !wall.isOn && nav.filter == .connections {
                Text("Connections appear when Internet watching is on (Settings → Internet).")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 10)
            }
        }
    }

    private func open(_ e: TimelineEvent) {
        if let id = e.stopEventID, let a = model.events.first(where: { $0.id == id }) { nav.openDecision = a; return }
        nav.openEvent = e
    }

    private func filterBar(_ groups: [TimelineGroup]) -> some View {
        HStack(spacing: 10) {
            Picker("", selection: $nav.filter) {
                ForEach(TimelineFilter.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            Spacer(minLength: 4)
            Menu {
                Button("All projects") { nav.projectFilter = nil }
                Divider()
                ForEach(Workspaces.list(agents.sessions, records: records.groups?.sessions ?? []), id: \.path) { w in
                    Button(Workspaces.name(w.path)) { nav.projectFilter = w.path; nav.sessionFilter = nil }
                }
            } label: { Text(Workspaces.name(nav.projectFilter)).font(.system(size: 12)) }
            .fixedSize()
            Menu {
                Button("All agents") { nav.agentFilter = nil }
                Divider()
                ForEach(Array(Set(groups.map(\.agent).filter { !$0.isEmpty })).sorted(), id: \.self) { a in
                    Button(ActivityFeed.agentTitle(a)) { nav.agentFilter = a }
                }
            } label: { Text(nav.agentFilter.map(ActivityFeed.agentTitle) ?? "All agents").font(.system(size: 12)) }
            .fixedSize()
            if nav.sessionFilter != nil {
                Button("Clear session ×") { nav.sessionFilter = nil }.buttonStyle(GhostButtonStyle())
            }
            TextField("Search", text: $nav.search).textFieldStyle(.roundedBorder).frame(width: 130)
        }
    }

    @ViewBuilder private func empty(anyEvents: Bool, recording: Bool) -> some View {
        let state = Timeline.empty(projectFilter: nav.projectFilter, working: agents.workingNow, recording: recording,
                                   anyEvents: anyEvents)
        RecordList {
            VStack(spacing: 8) {
                switch state {
                case .elsewhere(let agent, let project, let filter):
                    (Text("\(agent) is working in ") + Text(project).bold() + Text(", not in \(filter)."))
                        .font(.system(size: 13))
                    Button("Show all projects") { nav.projectFilter = nil; nav.sessionFilter = nil }
                        .buttonStyle(LimeButtonStyle(subtle: true))
                case .recordingOff:
                    Text("Recording is off, so Kai keeps only its stops, and none matches.").font(.system(size: 13))
                    Button("Turn on") { model.setSwitch("record_activity", "on") }.buttonStyle(LimeButtonStyle(subtle: true))
                case .nothing:
                    Text("No agent activity today.").font(.system(size: 13))
                case .noMatch:
                    Text("Nothing Kai recorded today matches these filters.").font(.system(size: 13))
                    Button("Show everything") {
                        nav.filter = .all; nav.agentFilter = nil; nav.sessionFilter = nil; nav.projectFilter = nil; nav.search = ""
                    }.buttonStyle(GhostButtonStyle())
                }
            }
            .frame(maxWidth: .infinity).padding(26)
        }
    }

    private var recordingOff: some View {
        HStack(spacing: 10) {
            Text("Recording is off: Kai keeps only stops.").font(.system(size: 12.5))
            Spacer()
            Button("Turn on") { model.setSwitch("record_activity", "on") }.buttonStyle(LimeButtonStyle(subtle: true))
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.border))
    }
}

struct TimelineRow: View {
    let event: TimelineEvent
    let open: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 12))
                    .foregroundStyle(event.kind == .stop ? Theme.amber : Theme.muted)
                    .frame(width: 28, height: 28)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !event.object.isEmpty && event.kind != .command && event.kind != .connection {
                        Text(event.object).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Text(event.outcome).font(.system(size: 11)).foregroundStyle(event.kind == .stop ? Theme.amber : Theme.muted)
                Text(clock).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.muted)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(hover ? Theme.raised.opacity(0.6) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
    private var clock: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: event.ts))
    }
    private var symbol: String {
        switch event.kind {
        case .file: return "doc.text"
        case .command: return "terminal"
        case .connection: return "network"
        case .stop: return "hand.raised"
        case .tool: return "wrench.and.screwdriver"
        }
    }
}

/// One timeline event: what happened, Evidence, Outcome, Session, Ask about this.
struct TimelineEventSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var nav = MainNav.shared
    @ObservedObject private var agents = AgentsModel.shared
    @Environment(\.dismiss) private var dismiss
    let event: TimelineEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if !event.agent.isEmpty { AgentLogo(agent: event.agent, size: 28) }
                Text(event.title).font(.system(size: 19, weight: .semibold))
            }
            Text(event.what).font(.system(size: 13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            Divider().padding(.vertical, 14)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                row("Evidence", event.evidence)
                row("Outcome", event.outcome)
                row("Session", session)
                if !event.object.isEmpty { row(event.kind == .command ? "Program" : "Path", event.object) }
                row("Time", Date(timeIntervalSince1970: event.ts).formatted(date: .abbreviated, time: .standard))
            }
            HStack {
                Spacer()
                Button("Ask about this →") {
                    dismiss()
                    nav.ask(about: ActivityItem(id: event.id, kind: event.kind == .file ? .read : event.kind == .command ? .command : .tool,
                                                agentKey: event.agent, agent: ActivityFeed.agentTitle(event.agent),
                                                title: event.title, detail: event.object, count: 1, countText: "1",
                                                outcome: event.outcome, source: event.evidence, session: session,
                                                scope: "This one request", examples: [], explanation: event.what))
                    nav.page = .ask
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
        }
        .padding(26)
        .frame(width: 540)
    }

    private var session: String {
        let g = Timeline.groups(records: KaiRecords.shared.groups?.sessions ?? [], sessions: agents.sessions,
                                events: [], internetWatching: false)
            .first { $0.events.contains { $0.id == event.id } }
        return g?.header(now: Date()) ?? ActivityFeed.agentTitle(event.agent)
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(Theme.muted)
            Text(v).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
    }
}
