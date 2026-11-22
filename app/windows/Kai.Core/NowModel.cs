// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Now and Activity, ported from the macOS app (NowModel.swift,
// ActivityFeed.swift): one card per live agent session from `kai snapshot`
// and `kai activity` "sessions", and one timeline of today's records. Every
// number on Now, the tray flyout and Activity comes from SessionActivity
// counts through Counting, so a card and Activity can't disagree for the same
// range. Only what an agent reports is counted: Cursor's editor writes and
// Codex's file events read "not reported", never 0. A path shows as a file
// name, a command as its program name.
namespace Kai.Core;

public enum CountKind { Reads, Edits, Commands, Connections, Stops }

public sealed record CardCount(CountKind Kind, int? Value, string? NotReportedBy = null)
{
    static string Plural(CountKind k) => k.ToString().ToLowerInvariant();
    static string One(CountKind k) => k switch
    {
        CountKind.Reads => "read", CountKind.Edits => "edit", CountKind.Commands => "command",
        CountKind.Connections => "connection", _ => "stop",
    };
    public string Text => NotReportedBy is { } who
        ? $"{Plural(Kind)}: not reported by {who}"
        : $"{Value ?? 0:N0} {((Value ?? 0) == 1 ? One(Kind) : Plural(Kind))}";
}

/// What each agent's hooks report (the coverage table).
public static class AgentReports
{
    public static IReadOnlyList<CountKind> NotReported(string agent) => agent switch
    {
        "cursor" => new[] { CountKind.Edits },
        "codex" => new[] { CountKind.Reads, CountKind.Edits },
        _ => Array.Empty<CountKind>(),
    };
    public static string? Footnote(string agent) => agent switch
    {
        "cursor" => "edits: not reported by Cursor",
        "codex" => "files: not reported by Codex",
        _ => null,
    };
    public static string Coverage(string key) => key switch
    {
        "claude" => "Reports file reads, edits and writes, commands and MCP calls.",
        "cursor" => "Reports file reads, commands and MCP calls; not the editor's own writes.",
        "codex" => "Reports commands and MCP calls; no file events.",
        _ => "Kai has no hook in this agent: activity unavailable.",
    };
}

/// The one way counts are made from activity records (cards and Activity).
public static class Counting
{
    public static List<CardCount> Of(string agent, SessionActivity.Counts c, int stops, int? connections)
    {
        var missing = AgentReports.NotReported(agent);
        var who = Names.Agent(agent);
        var o = new List<CardCount>();
        void Add(CountKind k, int? v) => o.Add(missing.Contains(k) ? new CardCount(k, null, who) : new CardCount(k, v));
        Add(CountKind.Reads, c.Read);
        Add(CountKind.Edits, c.Edit + c.Write);
        Add(CountKind.Commands, c.Command);
        if (connections is { } n) Add(CountKind.Connections, n);
        Add(CountKind.Stops, stops);
        return o;
    }
}

public static class LastAction
{
    public static string Ago(double seconds)
    {
        var s = Math.Max(0, (long)seconds);
        if (s < 60) return "now";
        if (s < 3600) return $"{s / 60} min ago";
        if (s < 86400) return $"{s / 3600} h ago";
        return $"{s / 86400} d ago";
    }

    public static string? Object(SessionActivity.Event e)
    {
        if (string.IsNullOrEmpty(e.Name)) return null;
        return e.Op is "command" or "mcp" ? (e.Name.Length > 40 ? e.Name[..40] : e.Name) : Paths.Last(e.Name);
    }

    /// "Editing app.py · now", "Ran npm · 5 min ago", "Kai stopped a read of .env · now".
    public static string Line(SessionActivity.Event e, DateTimeOffset now)
    {
        var age = now.ToUnixTimeSeconds() - e.Ts;
        bool fresh = age < 60;
        var obj = Object(e);
        string what;
        if (e.IsStop)
        {
            var noun = e.Op switch
            {
                "read" => "a read", "command" => "a command", "mcp" => "an MCP call",
                "edit" or "write" => "a change", _ => "a request",
            };
            var of = obj is null ? "" : e.Op is "edit" or "write" ? $" to {obj}" : $" of {obj}";
            what = "Kai stopped " + noun + of;
        }
        else
        {
            what = e.Op switch
            {
                "read" => (fresh ? "Reading " : "Read ") + (obj ?? "a file"),
                "edit" => (fresh ? "Editing " : "Edited ") + (obj ?? "a file"),
                "write" => (fresh ? "Writing " : "Wrote ") + (obj ?? "a file"),
                "command" => obj is null ? (fresh ? "Running a command" : "Ran a command") : (fresh ? "Running " : "Ran ") + obj,
                "mcp" => "Used " + (obj is null ? "an MCP tool" : $"the {obj} MCP tool"),
                _ => "Used a tool",
            };
        }
        return what + " · " + Ago(age);
    }
}

/// One live session as Now shows it.
public sealed record NowCard
{
    public required SessionRow Session { get; init; }
    public List<SessionRow> Children { get; init; } = new();
    public SessionActivity? Activity { get; init; }
    public AuditEvent? LatestStop { get; init; }
    public int StopCount { get; init; }
    public int? Connections { get; init; }

    public string Id => Session.Id;
    public string AgentKey => Session.Agent;
    public bool Working => Session.IsWorking;
    public string Project => Session.ProjectName;
    public int Stops => Math.Max(StopCount, Activity?.Stops ?? 0);
    public List<CardCount> Counts => Counting.Of(AgentKey, Activity?.Count ?? new(), Stops, Connections);

    public string StatePill(DateTimeOffset now)
    {
        if (Session.IsWorking) return "Working";
        if (Session.LastActiveUtc <= 0) return "Idle";
        var m = Math.Max(0, now.ToUnixTimeSeconds() - Session.LastActiveUtc) / 60;
        return m < 60 ? $"Idle {Math.Max(1, m)} min" : $"Idle {m / 60} h";
    }

    public string Started(DateTimeOffset now)
    {
        if (Session.StartedUtc <= 0) return "";
        var d = DateTimeOffset.FromUnixTimeSeconds(Session.StartedUtc).ToLocalTime();
        var local = now.ToLocalTime();
        var clock = d.Date == local.Date ? d.ToString("HH:mm") : d.ToString("MMM d, HH:mm");
        var s = Math.Max(0, (long)(now - d).TotalSeconds);
        var dur = s >= 86400 ? $"{s / 86400} d {s % 86400 / 3600} h" : s >= 3600 ? $"{s / 3600} h {s % 3600 / 60} min" : $"{Math.Max(1, s / 60)} min";
        return $"started {clock} · {dur}";
    }

    public string? LastLine(DateTimeOffset now) => Activity?.Events.FirstOrDefault() is { } e ? LastAction.Line(e, now) : null;

    /// "Kai stopped a read of .env" (one line on the card; the sheet has the rest).
    public static string StopLine(AuditEvent e) => "Kai stopped " + e.AgentName + "'s " + Copy.What(e);
}

public sealed record NowSection(string Agent, string Title, List<NowCard> Cards)
{
    public string Line
    {
        get
        {
            int w = Cards.Count(c => c.Working), i = Cards.Count - w;
            var parts = new List<string> { Title };
            if (w > 0) parts.Add($"{w} working");
            if (i > 0) parts.Add($"{i} idle");
            return string.Join(" · ", parts);
        }
    }
}

/// The one source for "2 working · 1 idle" (Now, the tray, the flyout).
public sealed record NowSummary(int Working, int Idle)
{
    public string Text
    {
        get
        {
            if (Working == 0 && Idle == 0) return "No session running";
            var p = new List<string>();
            if (Working > 0) p.Add($"{Working} working");
            if (Idle > 0) p.Add($"{Idle} idle");
            return string.Join(" · ", p);
        }
    }
    public static NowSummary Of(IEnumerable<NowSection> sections)
    {
        var cards = sections.SelectMany(s => s.Cards).ToList();
        int w = cards.Count(c => c.Working);
        return new NowSummary(w, cards.Count - w);
    }
}

public static class NowBuilder
{
    /// The activity records of a session: by its keys, else (older records)
    /// by agent and project when only one live session of that agent is there.
    public static SessionActivity? ActivityFor(SessionRow s, IReadOnlyList<SessionRow> all, IReadOnlyList<SessionActivity> records)
    {
        var keys = s.ActivityKeys.ToHashSet();
        var mine = records.Where(r => keys.Contains(r.Key) && r.Agent == s.Agent).ToList();
        if (s.IsIDE)
        {
            mine = records.Where(r => r.Agent == s.Agent).ToList();
        }
        else if (s.Project.Length > 0 && s.Project != "/")
        {
            var peers = all.Where(p => p.IsActive && p.IsSession && p.Agent == s.Agent &&
                                       string.Equals(p.Project, s.Project, StringComparison.OrdinalIgnoreCase)).ToList();
            if (peers.Count == 1)
            {
                var claimed = all.SelectMany(a => a.ActivityKeys).ToHashSet();
                mine.AddRange(records.Where(r => r.Agent == s.Agent && !claimed.Contains(r.Key) && !keys.Contains(r.Key)
                                                 && Paths.InWorkspace(r.Workspace, s.Project)
                                                 && (s.StartedUtc == 0 || r.Last >= s.StartedUtc)));
            }
        }
        if (mine.Count == 0) return null;
        return new SessionActivity
        {
            Key = string.Join("+", mine.Select(m => m.Key)),
            Agent = s.Agent,
            Workspace = mine.MaxBy(m => m.Last)!.Workspace,
            First = mine.Min(m => m.First),
            Last = mine.Max(m => m.Last),
            Count = mine.Aggregate(new SessionActivity.Counts(), (a, b) => a + b.Count),
            Stops = mine.Sum(m => m.Stops),
            Events = mine.SelectMany(m => m.Events).OrderByDescending(e => e.Ts).ToList(),
        };
    }

    /// Kai's recorded stops for a session: same agent, inside its project
    /// (any project for an IDE app), since it started.
    public static List<AuditEvent> StopsFor(SessionRow s, IReadOnlyList<AuditEvent> events) =>
        events.Where(e =>
        {
            if (!e.IsBlock || e.IsNote || e.IsSilent || e.IsGrant || e.IsNetwork || e.IsStorage || e.AgentKey != s.Agent) return false;
            if (s.StartedUtc > 0 && e.Date is { } d && d.ToUnixTimeSeconds() < s.StartedUtc) return false;
            if (s.IsIDE) return true;
            return s.Project.Length > 0 && Paths.InWorkspace(e.Cwd, s.Project);
        }).OrderByDescending(e => e.Date ?? DateTimeOffset.MinValue).ToList();

    static readonly string[] Order = { "claude", "cursor", "codex" };

    public static List<NowSection> Sections(IReadOnlyList<SessionRow> sessions, IReadOnlyList<SessionActivity> records,
                                            IReadOnlyList<AuditEvent> events, IReadOnlyDictionary<string, int>? connections = null)
    {
        var live = sessions.Where(s => s.IsActive).ToList();
        var cards = live.Where(s => s.IsSession).Select(s =>
        {
            var st = StopsFor(s, events);
            return new NowCard
            {
                Session = s, Activity = ActivityFor(s, sessions, records), LatestStop = st.FirstOrDefault(),
                StopCount = st.Count, Connections = connections is not null && connections.TryGetValue(s.Agent, out var n) ? n : null,
            };
        }).ToList();
        foreach (var x in live.Where(s => !s.IsSession))
        {
            var c = cards.FirstOrDefault(c => c.Session.Agent == x.Agent && c.Session.Project == x.Project)
                    ?? cards.FirstOrDefault(c => c.Session.Agent == x.Agent);
            c?.Children.Add(x);
        }
        int Rank(string k) { int i = Array.IndexOf(Order, k); return i < 0 ? 9 : i; }
        return cards.GroupBy(c => c.AgentKey).OrderBy(g => Rank(g.Key)).ThenBy(g => g.Key).Select(g =>
        {
            var list = g.OrderByDescending(c => c.Working)
                        .ThenByDescending(c => Math.Max(c.Session.LastActiveUtc, c.Session.StartedUtc)).ToList();
            return new NowSection(g.Key, list[0].Session.DisplayAgent, list);
        }).ToList();
    }

    public static string EmptyText(IReadOnlyList<string> connected)
    {
        var names = connected.Select(Names.Agent).ToList();
        return names.Count == 0 ? "No agent is working right now. Kai isn't connected to an agent yet."
                                : $"No agent is working right now. Kai is connected to {Names.Joined(names)}.";
    }
}

// ---------------------------------------------------------------- Activity

public enum TimelineKind { File, Command, Connection, Stop, Tool }

public sealed record TimelineEvent
{
    public required string Id { get; init; }
    public TimelineKind Kind { get; init; }
    public double Ts { get; init; }
    public string Agent { get; init; } = "";
    public string Title { get; init; } = "";
    public string Object { get; init; } = "";
    public string Outcome { get; init; } = "";
    public Evidence Evidence { get; init; }
    public string Source { get; init; } = "";
    public string What { get; init; } = "";
    public string? StopEventId { get; init; }
}

public enum TimelineFilter { All, Files, Commands, Connections, Stops }

public static class TimelineFilters
{
    public static bool Matches(this TimelineFilter f, TimelineKind k) => f switch
    {
        TimelineFilter.Files => k == TimelineKind.File,
        TimelineFilter.Commands => k == TimelineKind.Command,
        TimelineFilter.Connections => k == TimelineKind.Connection,
        TimelineFilter.Stops => k == TimelineKind.Stop,
        _ => true,
    };
}

public sealed record TimelineGroup
{
    public required string Id { get; init; }
    public string Agent { get; init; } = "";
    public string Project { get; init; } = "";
    public string ProjectPath { get; init; } = "";
    public string? SessionId { get; init; }
    public double Start { get; set; }
    public double? End { get; init; }
    public List<TimelineEvent> Events { get; init; } = new();
    /// The session's totals from its activity records and Kai's stops: the
    /// same numbers its Now card shows (Events holds only the newest).
    public SessionActivity.Counts Totals { get; set; } = new();
    public int Stops { get; set; }
    public int? Connections { get; set; }
    public List<CardCount> Counts => Counting.Of(Agent, Totals, Stops, Connections);

    public string Header
    {
        get
        {
            string Clock(double t) => DateTimeOffset.FromUnixTimeSeconds((long)t).ToLocalTime().ToString("HH:mm");
            var range = $"{Clock(Start)}–{(End is { } e ? Clock(e) : "now")}";
            return string.Join(" · ", new[] { Agent.Length > 0 ? Names.Agent(Agent) : "", Project, range }.Where(s => s.Length > 0));
        }
    }
}

public static class Timeline
{
    public static TimelineEvent Event(SessionActivity.Event e, string agent, string key, int index, string? workspace)
    {
        var name = e.Name is null ? "" : e.Op is "command" or "mcp" ? e.Name : Paths.Shown(e.Name, workspace);
        var who = Names.Agent(agent);
        var baseText = $"{who} asked for this through its hook, before the tool ran.";
        TimelineKind kind;
        string title, what;
        switch (e.Op)
        {
            case "read":
                kind = TimelineKind.File; title = "Read " + (name.Length == 0 ? "a file" : Paths.Last(name));
                what = baseText + " Commands and scripts can read other files that this list doesn't show.";
                break;
            case "edit":
            case "write":
                kind = TimelineKind.File; title = (e.Op == "edit" ? "Edited " : "Wrote ") + (name.Length == 0 ? "a file" : Paths.Last(name));
                what = baseText + " It doesn't confirm the final file content.";
                break;
            case "command":
                kind = TimelineKind.Command; title = name.Length == 0 ? "Ran a command" : "Ran " + name;
                what = baseText + " Kai keeps only the program's name, never the full command line, and doesn't know if it succeeded.";
                break;
            case "mcp":
                kind = TimelineKind.Tool; title = name.Length == 0 ? "Used an MCP tool" : $"Used the {name} MCP tool";
                what = baseText + " What the tool did on its service isn't confirmed by Kai.";
                break;
            default:
                kind = TimelineKind.Tool; title = "Used a tool"; what = baseText;
                break;
        }
        bool stopped = e.IsStop;
        return new TimelineEvent
        {
            Id = $"{key}-{(long)e.Ts}-{index}", Kind = stopped ? TimelineKind.Stop : kind, Ts = e.Ts, Agent = agent,
            Title = stopped ? LastAction.Line(e, DateTimeOffset.FromUnixTimeSeconds((long)e.Ts)).Split(" · ")[0] : title,
            Object = name, Outcome = stopped ? "Stopped" : "Requested",
            Evidence = stopped ? Evidence.Confirmed : Evidence.Requested,
            Source = $"{who} hook (activity recording)",
            What = stopped ? "Kai stopped this request at the agent's tool boundary." : what,
        };
    }

    public static SessionRow? SessionFor(SessionActivity r, IReadOnlyList<SessionRow> sessions)
    {
        var s = sessions.FirstOrDefault(x => x.Agent == r.Agent && x.ActivityKeys.Contains(r.Key));
        if (s is not null) return s;
        var ide = sessions.FirstOrDefault(x => x.Agent == r.Agent && x.IsIDE);
        if (ide is not null) return ide;
        var c = sessions.Where(x => x.IsSession && x.Agent == r.Agent && x.Project.Length > 0 && x.Project != "/"
                                    && Paths.InWorkspace(r.Workspace, x.Project) && (x.StartedUtc == 0 || r.Last >= x.StartedUtc)).ToList();
        return c.Count == 1 ? c[0] : null;
    }

    static bool IsToday(DateTimeOffset? d, DateTimeOffset now) => d is { } x && x.ToLocalTime().Date == now.ToLocalTime().Date;

    /// One group per session, newest first; Kai's stops without a matching
    /// activity line in their own group; Kai Watch's records ("Seen") in one group.
    public static List<TimelineGroup> Groups(IReadOnlyList<SessionActivity> records, IReadOnlyList<SessionRow> sessions,
                                             IReadOnlyList<AuditEvent> events, bool internetWatching, DateTimeOffset now)
    {
        var o = new Dictionary<string, TimelineGroup>();
        var stopTimes = new List<(string Agent, double Ts)>();
        var auditStops = events.Where(e => e.IsBlock && !e.IsNote && !e.IsSilent && !e.IsGrant && !e.IsNetwork && !e.IsStorage
                                          && IsToday(e.Date, now)).ToList();
        foreach (var r in records)
        {
            var s = SessionFor(r, sessions);
            var gid = s is not null ? "s-" + s.Id : "r-" + r.Key;
            var path = s is null ? r.Workspace : s.IsIDE ? r.Workspace : s.Project;
            var name = s is null ? (r.Workspace.Length == 0 ? "" : Paths.Last(r.Workspace))
                     : s.IsIDE ? (r.Workspace.Length == 0 ? s.DisplayAgent : Paths.Last(r.Workspace)) : s.ProjectName;
            if (!o.TryGetValue(gid, out var g))
                g = o[gid] = new TimelineGroup
                {
                    Id = gid, Agent = r.Agent, Project = name, ProjectPath = path, SessionId = s?.Id,
                    Start = s is not null && s.StartedUtc > 0 ? s.StartedUtc : r.First,
                    End = s?.IsActive == true ? null : r.Last,
                };
            for (int i = 0; i < r.Events.Count; i++)
            {
                var e = r.Events[i];
                var t = Event(e, r.Agent, r.Key, i, path.Length == 0 ? null : path);
                if (e.IsStop)
                {
                    stopTimes.Add((r.Agent, e.Ts));
                    t = t with
                    {
                        StopEventId = auditStops.FirstOrDefault(a => a.AgentKey == r.Agent
                                          && Math.Abs((a.Date?.ToUnixTimeSeconds() ?? 0) - e.Ts) < 3)?.Id,
                    };
                }
                g.Events.Add(t);
            }
            g.Start = Math.Min(g.Start, r.First);
            g.Totals += r.Count;
        }
        foreach (var e in auditStops)
        {
            double ts = e.Date?.ToUnixTimeSeconds() ?? 0;
            if (stopTimes.Any(x => x.Agent == e.AgentKey && Math.Abs(x.Ts - ts) < 3)) continue;
            var s = sessions.FirstOrDefault(x => x.Agent == e.AgentKey && x.IsSession && x.Project.Length > 0
                                                 && Paths.InWorkspace(e.Cwd, x.Project) && (x.StartedUtc == 0 || ts >= x.StartedUtc));
            var gid = s is not null ? "s-" + s.Id : $"stops-{e.AgentKey}-{e.Cwd}";
            if (!o.TryGetValue(gid, out var g))
                g = o[gid] = new TimelineGroup
                {
                    Id = gid, Agent = e.AgentKey, Project = s?.ProjectName ?? (e.Cwd is null ? "" : Paths.Last(e.Cwd)),
                    ProjectPath = s?.Project ?? e.Cwd ?? "", SessionId = s?.Id, Start = s?.StartedUtc ?? ts,
                    End = s?.IsActive == true ? null : ts,
                };
            g.Events.Add(StopEvent(e, g.ProjectPath));
            if (g.Start == 0 || ts < g.Start) g.Start = ts;
        }
        if (internetWatching)
        {
            var seen = events.Where(e => e.IsWatch && !e.IsSilent && IsToday(e.Date, now))
                             .OrderByDescending(e => e.Date).Take(80).ToList();
            if (seen.Count > 0)
            {
                var evs = seen.Select(SeenEvent).ToList();
                o["seen"] = new TimelineGroup { Id = "seen", Project = "Seen by Kai Watch", Start = evs.Min(x => x.Ts), Events = evs };
            }
        }
        // Stops: the same rule as the card (NowBuilder.StopsFor), else the records' own count.
        var connections = internetWatching ? ConnectionsToday(events, now) : null;
        foreach (var g in o.Values)
        {
            var s = g.SessionId is null ? null : sessions.FirstOrDefault(x => x.Id == g.SessionId);
            int recStops = records.Where(r => SessionFor(r, sessions)?.Id is { } id && id == g.SessionId).Sum(r => r.Stops);
            g.Stops = s is null ? g.Events.Count(e => e.Kind == TimelineKind.Stop) : Math.Max(NowBuilder.StopsFor(s, events).Count, recStops);
            if (s is not null && connections is not null && connections.TryGetValue(s.Agent, out var n)) g.Connections = n;
        }
        foreach (var g in o.Values) g.Events.Sort((a, b) => b.Ts.CompareTo(a.Ts));
        return o.Values.OrderByDescending(g => g.Events.FirstOrDefault()?.Ts ?? g.Start).ToList();
    }

    public static TimelineEvent StopEvent(AuditEvent e, string? workspace) => new()
    {
        Id = "stop-" + e.Id, Kind = TimelineKind.Stop, Ts = e.Date?.ToUnixTimeSeconds() ?? 0, Agent = e.AgentKey,
        Title = Copy.Sentence(e).TrimEnd('.'), Object = e.Excerpt is { } x ? (e.ActionLabel == "Command" ? Copy.Program(x) : Paths.Shown(x, workspace)) : "",
        Outcome = Copy.Outcome(e), Evidence = e.Evidence,
        Source = $"Kai's decision ({e.AgentName} hook)",
        What = $"Kai stopped this specific request: {Names.Sentence(e.Detail)} It doesn't show that other ways to do the same thing were stopped.",
        StopEventId = e.Id,
    };

    public static TimelineEvent SeenEvent(AuditEvent e) => new()
    {
        Id = "seen-" + e.Id, Kind = e.IsNetwork ? TimelineKind.Connection : TimelineKind.File,
        Ts = e.Date?.ToUnixTimeSeconds() ?? 0, Agent = e.AgentKey, Title = Copy.Sentence(e).TrimEnd('.'),
        Object = e.Target ?? "", Outcome = "Seen", Evidence = Evidence.Seen, Source = "Kai Watch (watching only)",
        What = e.IsNetwork
            ? "Kai Watch saw this connection on Windows itself. It doesn't show what data was sent, and Kai only watched: nothing was blocked."
            : "Kai Watch saw a program running under the agent open this protected file, outside the agent's hooks. Kai only watched: it didn't stop it, and can't tell what was read.",
    };

    /// Connections Kai Watch saw today, per agent: the number a card shows
    /// next to its reads and edits.
    public static Dictionary<string, int> ConnectionsToday(IReadOnlyList<AuditEvent> events, DateTimeOffset now) =>
        events.Where(e => e.IsWatch && e.IsNetwork && !e.IsSilent && IsToday(e.Date, now))
              .GroupBy(e => e.AgentKey).ToDictionary(g => g.Key, g => g.Count());

    /// Counts over the timeline (Activity's header), from the same records as the cards.
    public static Dictionary<CountKind, int> Counts(IReadOnlyList<TimelineGroup> groups, string? sessionId = null)
    {
        var d = new Dictionary<CountKind, int> { [CountKind.Reads] = 0, [CountKind.Edits] = 0, [CountKind.Commands] = 0,
                                                 [CountKind.Connections] = 0, [CountKind.Stops] = 0 };
        foreach (var g in groups.Where(g => sessionId is null || g.SessionId == sessionId))
            foreach (var e in g.Events)
            {
                if (e.Kind == TimelineKind.Stop) d[CountKind.Stops]++;
                else if (e.Kind == TimelineKind.Command) d[CountKind.Commands]++;
                else if (e.Kind == TimelineKind.Connection) d[CountKind.Connections]++;
                else if (e.Kind == TimelineKind.File) d[e.Title.StartsWith("Read ", StringComparison.Ordinal) ? CountKind.Reads : CountKind.Edits]++;
            }
        return d;
    }
}
