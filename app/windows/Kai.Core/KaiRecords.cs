// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// One refresh of everything the app shows, from kai.exe and the audit log,
// and the views built from it: Now's sections, Activity's timeline, the
// flyout's numbers, Ask Kai's context. Pages read this; none keeps its own
// copy, so a number can't differ between the flyout, Now and Activity.
//
// Also the held policy changes (%USERPROFILE%\.kai\pending-policy): a change
// that turns protection down is queued by kai.exe and applied only here,
// after the owner confirms (PendingPolicyStore.swift on macOS).
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Kai.Core;

public sealed record Snapshot0
{
    public KaiStatus? Status { get; init; }
    public PolicyInfo? Policy { get; init; }
    public Snapshot? Sessions { get; init; }
    public ActivityGroups? Activity { get; init; }
    public List<AuditEvent> Events { get; init; } = new();
    public DateTimeOffset Now { get; init; } = DateTimeOffset.Now;
    /// What failed to load, in words (shown, never hidden).
    public List<string> Problems { get; init; } = new();
}

public sealed class KaiRecords
{
    public Snapshot0 Data { get; private set; } = new();
    public event Action? Changed;

    public async Task RefreshAsync()
    {
        var st = KaiCli.RunAsync("status", "--json");
        var pol = KaiCli.RunAsync("policy", "show", "--json");
        var snap = KaiCli.RunAsync("snapshot", "--json");
        var act = KaiCli.RunAsync("activity", "--json", "--since", "24h");
        await Task.WhenAll(st, pol, snap, act);
        var problems = new List<string>();
        var status = (await st).Ok ? KaiStatus.Parse((await st).Out) : null;
        if (status is null) problems.Add("kai status: " + (await st).Message);
        var policy = (await pol).Ok ? PolicyInfo.Parse((await pol).Out) : null;
        var sessions = (await snap).Ok ? Snapshot.Parse((await snap).Out) : null;
        if (sessions is null) problems.Add("kai snapshot: " + (await snap).Message);
        var activity = (await act).Ok ? ActivityGroups.Parse((await act).Out) : null;
        var events = status is null ? new List<AuditEvent>() : await Task.Run(() => AuditReader.ReadRecent(status.AuditPath));
        Data = new Snapshot0 { Status = status, Policy = policy, Sessions = sessions, Activity = activity, Events = events,
                               Now = DateTimeOffset.Now, Problems = problems };
        Changed?.Invoke();
    }

    public void Load(Snapshot0 d) { Data = d; Changed?.Invoke(); }

    // --------------------------------------------------------------- views

    public static bool Recording(Snapshot0 d) => d.Activity?.Recording ?? d.Policy?.Recording ?? false;

    public static AskInternet Internet(Snapshot0 d) =>
        d.Status is null ? AskInternet.Off
        : d.Status.InternetWatching ? AskInternet.On
        : d.Status.InternetStopped ? AskInternet.Stopped : AskInternet.Off;

    public static List<NowSection> Sections(Snapshot0 d) =>
        NowBuilder.Sections(d.Sessions?.Sessions ?? new(), d.Activity?.Sessions ?? new(), d.Events,
                            Internet(d) != AskInternet.Off ? Timeline.ConnectionsToday(d.Events, d.Now) : null);

    public static NowSummary Summary(Snapshot0 d) => NowSummary.Of(Sections(d));

    public static List<TimelineGroup> Groups(Snapshot0 d) =>
        Timeline.Groups(d.Activity?.Sessions ?? new(), d.Sessions?.Sessions ?? new(), d.Events, Internet(d) != AskInternet.Off, d.Now);

    public static List<ActivityItem> Items(Snapshot0 d, string? workspace = null) =>
        ActivityFeed.Build(d.Activity, d.Events, workspace, Internet(d) != AskInternet.Off, d.Now);

    /// The newest stop today (the flyout's "latest stop").
    public static AuditEvent? LatestStop(Snapshot0 d) => ActivityFeed.Stops(d.Events, null, d.Now).FirstOrDefault();

    /// Today's numbers, as the flyout shows them: the sum of the cards'.
    public static (int Sessions, int Stops, int Connections) Today(Snapshot0 d)
    {
        var secs = Sections(d);
        return (secs.Sum(s => s.Cards.Count), ActivityFeed.Stops(d.Events, null, d.Now).Count,
                Timeline.ConnectionsToday(d.Events, d.Now).Values.Sum());
    }

    public static List<AskAgent> Agents(Snapshot0 d)
    {
        var o = new List<AskAgent>();
        var rows = d.Sessions?.Agents ?? new();
        foreach (var key in new[] { "claude", "cursor", "codex" })
        {
            var row = rows.FirstOrDefault(r => r.Name == key);
            KaiStatus.Agent? a = d.Status is not null && d.Status.Agents.TryGetValue(key, out var x) ? x : null;
            if (row is null && a is null) continue;
            if (!(row?.Detected ?? a?.Detected ?? false) && !(a?.Installed ?? false)) continue;
            var live = d.Sessions?.Sessions.Where(s => s.Agent == key && s.IsActive && s.IsSession).ToList() ?? new();
            bool connected = a is { Installed: true } && a.Working != false;
            o.Add(new AskAgent(key, connected, live.Count > 0, live.Count(s => s.IsWorking),
                               a?.Problem is { Length: > 0 } p ? p : null,
                               Untrusted: key == "codex" && connected && a!.LastHook == 0));
        }
        return o;
    }

    public static AskContext AskContext(Snapshot0 d, ActivityItem? focus = null, SessionFocus? session = null) => new()
    {
        Recording = Recording(d),
        Internet = Internet(d),
        InternetWatching = Internet(d) == AskInternet.On,
        InternetProblem = d.Status?.NetworkProblem ?? "",
        Items = Items(d),
        Stops = ActivityFeed.Stops(d.Events, null, d.Now),
        Agents = Agents(d),
        Focus = focus,
        Session = session,
        Version = d.Status?.Version ?? "",
        Commit = d.Status?.Commit ?? "",
        RecordingFirst = d.Activity?.FirstRecord is { } f && f > 0 ? DateTimeOffset.FromUnixTimeSeconds((long)f) : null,
        PolicyProblem = d.Status is { PolicyOk: false } s && s.PolicyError.Length > 0 ? s.PolicyError : null,
        Paused = Native.Available && Native.Paused,
    };

    public static SessionFocus Focus(NowCard c, Snapshot0 d) =>
        new(c.Id, c.AgentKey, c.Session.DisplayAgent, c.Project, c.Session.HostApp, c.StatePill(d.Now), c.Started(d.Now),
            c.Counts, c.LastLine(d.Now), c.Stops, c.LatestStop is { } e ? NowCard.StopLine(e) : null, c.Session.Topic.Trim(), Recording(d));
}

/// A held change that would turn protection down.
public sealed record PendingPolicyChange(string Id, string Summary, string ProposedPolicy, string CallerChain, string CallerTeam);

public static class PendingPolicyStore
{
    static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public static string Dir => Path.Combine(Home, ".kai", "pending-policy");
    static string PolicyPath => Path.Combine(Home, ".kai", "policy");

    public static List<PendingPolicyChange> Load()
    {
        if (!Directory.Exists(Dir)) return new();
        var o = new List<PendingPolicyChange>();
        foreach (var f in Directory.EnumerateFiles(Dir, "*.json"))
        {
            var n = J.Parse(File.ReadAllText(f));
            if (n is null || J.S(n, "id").Length == 0) continue;   // not a request kai wrote
            o.Add(new PendingPolicyChange(J.S(n, "id"), J.S(n, "summary"), J.S(n, "proposed_policy"),
                                          J.S(n, "caller_chain"), J.S(n, "caller_team")));
        }
        return o.OrderBy(c => c.Id, StringComparer.Ordinal).ToList();
    }

    /// Write the proposed policy, record it, drop the request. Call only
    /// after the owner confirmed it.
    public static void Apply(PendingPolicyChange c)
    {
        var tmp = PolicyPath + ".kai-tmp";
        File.WriteAllText(tmp, c.ProposedPolicy);
        File.Move(tmp, PolicyPath, true);
        if (Native.Available) NativeAudit("applied", c.Summary);
        File.Delete(Path.Combine(Dir, c.Id + ".json"));
    }

    public static void Reject(PendingPolicyChange c)
    {
        if (Native.Available) NativeAudit("rejected", c.Summary);
        var f = Path.Combine(Dir, c.Id + ".json");
        if (File.Exists(f)) File.Delete(f);
    }

    static void NativeAudit(string what, string summary) => Native.Audit("policy", "confirm", what, "", $"user {what} in app: {summary}");
}
