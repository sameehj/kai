// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// What kai.exe's JSON commands return (status, snapshot, activity, policy
// show, why), read tolerantly as the macOS app does: a missing field takes its
// default, an unknown field is ignored, and one bad row is skipped instead of
// emptying the list. The app keeps no truth of its own: every number on
// screen comes from these.
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Kai.Core;

internal static class J
{
    public static string S(JsonNode? n, string key, string def = "")
    {
        try { return n?[key]?.GetValueKind() == JsonValueKind.String ? n[key]!.GetValue<string>() : def; }
        catch (Exception) when (n is not null) { return def; }
    }
    public static double D(JsonNode? n, string key, double def = 0)
    {
        var v = n?[key];
        if (v is null || v.GetValueKind() != JsonValueKind.Number) return def;
        return v.GetValue<double>();
    }
    public static int I(JsonNode? n, string key, int def = 0) => (int)D(n, key, def);
    public static long L(JsonNode? n, string key, long def = 0) => (long)D(n, key, def);
    public static bool B(JsonNode? n, string key, bool def = false)
    {
        var v = n?[key];
        return v?.GetValueKind() switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => def };
    }
    public static bool? BN(JsonNode? n, string key)
    {
        var v = n?[key];
        return v?.GetValueKind() switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => null };
    }
    public static IEnumerable<JsonNode> Arr(JsonNode? n, string key) =>
        n?[key] is JsonArray a ? a.Where(x => x is not null).Select(x => x!) : Enumerable.Empty<JsonNode>();
    public static JsonNode? Parse(string json)
    {
        try { return JsonNode.Parse(json); } catch (JsonException) { return null; }
    }
}

/// `kai status --json`.
public sealed record KaiStatus
{
    public sealed record Agent(bool Installed, bool Detected, string Config, bool? Working, string? Problem, double LastHook)
    {
        public bool Broken => Installed && Working == false;
    }
    public string Version { get; init; } = "";
    public string Commit { get; init; } = "";
    public string Home { get; init; } = "";
    public bool PolicyOk { get; init; }
    public string PolicyFile { get; init; } = "";
    public bool PolicyFileExists { get; init; }
    public string PolicyError { get; init; } = "";
    public Dictionary<string, Agent> Agents { get; init; } = new();
    public string AuditPath { get; init; } = "";
    public bool AuditIntact { get; init; } = true;
    /// "ok" or "degraded", with the reasons.
    public string State { get; init; } = "ok";
    public List<string> Degraded { get; init; } = new();
    /// Internet: the policy's mode ("off" | "log") and whether Kai Watch is
    /// really watching (its heartbeat, not the setting).
    public string NetworkConfigured { get; init; } = "off";
    public bool NetworkRunning { get; init; }
    public string NetworkProblem { get; init; } = "";

    public static KaiStatus? Parse(string json)
    {
        var o = J.Parse(json);
        if (o is null || o["version"] is null) return null;
        var agents = new Dictionary<string, Agent>();
        foreach (var k in new[] { "claude", "cursor", "codex" })
        {
            var a = o[k];
            if (a is null) continue;
            agents[k] = new Agent(J.B(a, "installed"), J.B(a, "detected"), J.S(a, "config"), J.BN(a, "working"),
                                  a["problem"] is null ? null : J.S(a, "problem"), J.D(a, "last_hook"));
        }
        var pol = o["policy"];
        var net = o["walls"]?["observed"]?["network"];
        return new KaiStatus
        {
            Version = J.S(o, "version"),
            Commit = J.S(o, "commit"),
            Home = J.S(o, "home"),
            PolicyOk = J.B(pol, "ok"),
            PolicyFile = J.S(pol, "file"),
            PolicyFileExists = J.B(pol, "file_exists"),
            PolicyError = J.S(pol, "error"),
            Agents = agents,
            AuditPath = J.S(o["audit"], "path"),
            AuditIntact = J.B(o["audit"], "intact", true),
            State = J.S(o, "state", "ok"),
            Degraded = J.Arr(o, "degraded").Select(x => x.GetValueKind() == JsonValueKind.String ? x.GetValue<string>() : "")
                        .Where(s => s.Length > 0).ToList(),
            NetworkConfigured = J.S(o["walls"]?["configured"], "network", "off"),
            NetworkRunning = J.B(net, "running"),
            NetworkProblem = J.S(net, "problem"),
        };
    }

    /// Watch mode on, and Kai Watch confirms it is watching.
    public bool InternetWatching => NetworkConfigured != "off" && NetworkRunning;
    /// Watch is on in the policy but nothing is watching: never shown as fine.
    public bool InternetStopped => NetworkConfigured != "off" && !NetworkRunning;
}

/// `kai policy show --json`: the switches the app shows.
public sealed record PolicyInfo
{
    public Dictionary<string, string> Switches { get; init; } = new();
    public List<string> Protect { get; init; } = new();
    public List<string> EgressAllow { get; init; } = new();
    public bool Ok { get; init; }
    public string Error { get; init; } = "";

    public static PolicyInfo? Parse(string json)
    {
        var o = J.Parse(json);
        if (o is null) return null;
        var sw = new Dictionary<string, string>();
        if (o["switches"] is JsonObject so)
            foreach (var kv in so)
                if (kv.Value?.GetValueKind() == JsonValueKind.String) sw[kv.Key] = kv.Value.GetValue<string>();
        return new PolicyInfo
        {
            Switches = sw,
            Protect = J.Arr(o, "protect").Select(x => x.ToString()).ToList(),
            EgressAllow = J.Arr(o, "egress_allow").Select(x => x.ToString()).ToList(),
            Ok = J.B(o, "ok"),
            Error = J.S(o, "error"),
        };
    }

    public bool Recording => !Switches.TryGetValue("record_activity", out var v) || v == "on";
    public string Egress => Switches.TryGetValue("egress", out var v) ? v : "log";
}

/// One agent session as `kai snapshot --json` lists it.
public sealed record SessionRow
{
    public string Id { get; init; } = "";
    public string Agent { get; init; } = "";
    public string Topic { get; init; } = "";
    public string Project { get; init; } = "";
    public string HostApp { get; init; } = "";
    public long StartedUtc { get; init; }
    public long EndedUtc { get; init; }
    public string Kind { get; init; } = "session";
    public string Tty { get; init; } = "";
    public string State { get; init; } = "active";
    public string Activity { get; init; } = "idle";
    public long LastActiveUtc { get; init; }
    public List<string>? Workspaces { get; init; }
    public List<string> ActivityKeys { get; init; } = new();

    public bool IsActive => State != "ended";
    public bool IsWorking => IsActive && Activity == "working";
    public bool IsSession => Kind == "session";
    public bool IsIDE => Workspaces is not null;
    public string DisplayAgent => Names.Agent(Agent);
    public string ProjectName
    {
        get
        {
            if (Workspaces is { } w)
                return w.Count == 0 ? (HostApp.Length == 0 ? DisplayAgent : HostApp)
                                    : $"{w.Count} workspace{(w.Count == 1 ? "" : "s")}";
            return Project.Length == 0 ? "—" : Paths.Last(Project);
        }
    }
    /// Windows has no terminal device: the host app ("Windows Terminal").
    public string Tab => HostApp;

    internal static SessionRow? From(JsonNode n)
    {
        var id = J.S(n, "id");
        var agent = J.S(n, "agent");
        if (id.Length == 0 || agent.Length == 0) return null;   // a bad row
        static string Known(string v, params string[] ok) => ok.Contains(v) ? v : "unknown";
        List<string>? ws = n["workspaces"] is JsonArray wa
            ? wa.Where(x => x is not null).Select(x => J.S(x, "path")).Where(p => p.Length > 0).ToList() : null;
        return new SessionRow
        {
            Id = id, Agent = agent, Topic = J.S(n, "topic"), Project = J.S(n, "project"),
            HostApp = J.S(n, "host_app"), StartedUtc = J.L(n, "started_utc"), EndedUtc = J.L(n, "ended_utc"),
            Kind = J.S(n, "kind", "session"), Tty = J.S(n, "tty"),
            State = Known(J.S(n, "state", "active"), "active", "ended"),
            Activity = Known(J.S(n, "activity", "idle"), "working", "idle"),
            LastActiveUtc = J.L(n, "last_active_utc"), Workspaces = ws,
            ActivityKeys = J.Arr(n, "activity_keys").Select(x => x.ToString()).ToList(),
        };
    }
}

public sealed record AgentRow(string Name, string Hooks, bool Detected, int ActiveSessions, string? Detail);

/// `kai snapshot --json`.
public sealed record Snapshot(List<SessionRow> Sessions, List<AgentRow> Agents, int Failures)
{
    public static Snapshot? Parse(string json)
    {
        var o = J.Parse(json);
        if (o?["sessions"] is not JsonArray) return null;   // no list at all = a failed source
        int bad = 0;
        var s = new List<SessionRow>();
        foreach (var n in J.Arr(o, "sessions"))
            if (SessionRow.From(n) is { } r) s.Add(r); else bad++;
        var a = new List<AgentRow>();
        foreach (var n in J.Arr(o, "agents"))
        {
            var name = J.S(n, "name");
            if (name.Length == 0) { bad++; continue; }
            a.Add(new AgentRow(name, J.S(n, "hooks", "n/a"), J.B(n, "detected"), J.I(n, "active_sessions"),
                               n["detail"] is null ? null : J.S(n, "detail")));
        }
        return new Snapshot(s, a, bad);
    }
}

/// `kai activity --json` "sessions": one Kai session key's recorded activity.
public sealed record SessionActivity
{
    public sealed record Counts(int Read = 0, int Edit = 0, int Write = 0, int Command = 0, int Mcp = 0, int Tool = 0)
    {
        public static Counts operator +(Counts a, Counts b) =>
            new(a.Read + b.Read, a.Edit + b.Edit, a.Write + b.Write, a.Command + b.Command, a.Mcp + b.Mcp, a.Tool + b.Tool);
    }
    public sealed record Event(double Ts, string Op, string? Name, string Decision = "allow")
    {
        public bool IsStop => Decision is "block" or "deny";
    }
    public string Key { get; init; } = "";
    public string Agent { get; init; } = "";
    public string Workspace { get; init; } = "";
    public double First { get; init; }
    public double Last { get; init; }
    public Counts Count { get; init; } = new();
    public int Stops { get; init; }
    public List<Event> Events { get; init; } = new();

    internal static SessionActivity? From(JsonNode n)
    {
        var key = J.S(n, "key");
        var agent = J.S(n, "agent");
        if (key.Length == 0 || agent.Length == 0) return null;
        var c = n["counts"];
        var evs = new List<Event>();
        foreach (var e in J.Arr(n, "events"))
        {
            var op = J.S(e, "op");
            if (op.Length == 0 || e["ts"] is null) continue;   // a bad event is skipped
            evs.Add(new Event(J.D(e, "ts"), op, e["name"] is null ? null : J.S(e, "name"), J.S(e, "decision", "allow")));
        }
        return new SessionActivity
        {
            Key = key, Agent = agent, Workspace = J.S(n, "workspace"), First = J.D(n, "first"), Last = J.D(n, "last"),
            Count = new Counts(J.I(c, "read"), J.I(c, "edit"), J.I(c, "write"), J.I(c, "command"), J.I(c, "mcp"), J.I(c, "tool")),
            Stops = J.I(n, "stops"), Events = evs,
        };
    }
}

/// `kai activity --json` (the opt-in recorder, grouped).
public sealed record ActivityGroups
{
    public sealed record Item(string Name, int Count);
    public sealed record Group(string Agent, string Op, int Count, int Distinct, int Sessions, int Stops, List<Item> Items);
    public bool Recording { get; init; }
    public List<Group> Groups { get; init; } = new();
    public List<SessionActivity> Sessions { get; init; } = new();
    public double? FirstRecord { get; init; }

    public static ActivityGroups? Parse(string json)
    {
        var o = J.Parse(json);
        if (o is null) return null;
        return new ActivityGroups
        {
            Recording = J.B(o, "recording"),
            Groups = J.Arr(o, "groups").Select(g => new Group(J.S(g, "agent"), J.S(g, "op"), J.I(g, "count"), J.I(g, "distinct"),
                         J.I(g, "sessions"), J.I(g, "stops"),
                         J.Arr(g, "items").Select(i => new Item(J.S(i, "name"), J.I(i, "count"))).ToList())).ToList(),
            Sessions = J.Arr(o, "sessions").Select(SessionActivity.From).Where(x => x is not null).Select(x => x!).ToList(),
            FirstRecord = o["first_record"] is null ? null : J.D(o, "first_record"),
        };
    }
}

/// `kai why <decision-id> --json`: one decision re-checked against today's rules.
public sealed record WhyRecord(string? Reason, string? Retry, string? Attribution, string? Component, string? Rule)
{
    public static WhyRecord? Parse(string json)
    {
        var o = J.Parse(json);
        if (o is null) return null;
        string? N(string k) => o[k] is null ? null : J.S(o, k);
        return new WhyRecord(N("reason"), N("retry"), N("attribution"), N("component"), N("rule"));
    }
    /// "Retry would now be: allowed", or null when kai didn't say.
    public string? RetryLine => string.IsNullOrWhiteSpace(Retry) ? null : $"Retry would now be: {Retry!.Trim()}";
}

/// Small helpers the models share.
public static class Names
{
    public static string Agent(string key) => key switch
    {
        "claude" => "Claude Code",
        "cursor" => "Cursor",
        "codex" => "Codex",
        "gemini" => "Gemini CLI",
        "" => "An agent",
        _ => char.ToUpperInvariant(key[0]) + key[1..],
    };

    /// "A, B and C".
    public static string Joined(IReadOnlyList<string> items) => items.Count switch
    {
        0 => "",
        1 => items[0],
        2 => items[0] + " and " + items[1],
        _ => string.Join(", ", items.Take(items.Count - 1)) + " and " + items[^1],
    };

    public static string N(int v, string one, string? many = null) =>
        $"{v:N0} {(v == 1 ? one : many ?? one + "s")}";

    /// One final full stop, never two.
    public static string Sentence(string s)
    {
        var t = s.Trim();
        return t.Length == 0 || ".!?…".Contains(t[^1]) ? t : t + ".";
    }
}

public static class Paths
{
    /// The last component of a '/'- or '\'-separated path.
    public static string Last(string p)
    {
        var t = p.TrimEnd('/', '\\');
        int i = Math.Max(t.LastIndexOf('/'), t.LastIndexOf('\\'));
        return i >= 0 ? t[(i + 1)..] : t;
    }

    static string Norm(string p) => p.Replace('\\', '/');

    /// Is cwd inside workspace (either slash, any letter case)?
    public static bool InWorkspace(string? cwd, string? workspace)
    {
        if (string.IsNullOrEmpty(workspace)) return true;
        if (string.IsNullOrEmpty(cwd)) return false;
        var c = Norm(cwd).TrimEnd('/');
        var w = Norm(workspace).TrimEnd('/');
        return c.Equals(w, StringComparison.OrdinalIgnoreCase) || c.StartsWith(w + "/", StringComparison.OrdinalIgnoreCase);
    }

    /// A path as the user reads it: relative to the workspace, ~ for home.
    public static string Shown(string path, string? workspace, string? home = null)
    {
        var p = Norm(path);
        if (!string.IsNullOrEmpty(workspace))
        {
            var w = Norm(workspace).TrimEnd('/');
            if (p.StartsWith(w + "/", StringComparison.OrdinalIgnoreCase)) return p[(w.Length + 1)..];
        }
        var h = Norm(home ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)).TrimEnd('/');
        if (h.Length > 0 && p.StartsWith(h + "/", StringComparison.OrdinalIgnoreCase)) return "~" + p[h.Length..];
        return p;
    }
}
