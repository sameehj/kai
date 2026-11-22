// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Activity grouped for Ask Kai and the summary rows (ActivityFeed.swift):
// recorded tool requests per agent and operation ("Requested"), Kai's stops
// ("Stopped", Kai's own decision) and what Kai Watch saw ("Seen"). No
// matching record never means it didn't happen.
namespace Kai.Core;

public enum ActivityItemKind { Read, Edit, Write, Command, Mcp, Tool, Connection, Stop }

public sealed record ActivityItem
{
    public required string Id { get; init; }
    public ActivityItemKind Kind { get; init; }
    public string AgentKey { get; init; } = "";
    public string Agent { get; init; } = "";
    public string Title { get; init; } = "";
    public string Detail { get; init; } = "";
    public int Count { get; init; }
    public string CountText { get; init; } = "";
    public string Outcome { get; init; } = "";
    public Evidence Evidence { get; init; }
    public string Source { get; init; } = "";
    public List<string> Examples { get; init; } = new();
    public string Explanation { get; init; } = "";
    public string? DecisionId { get; init; }
    public string? EventId { get; init; }
}

public static class ActivityFeed
{
    static List<string> Examples(IReadOnlyList<ActivityGroups.Item> items, int distinct, string? workspace)
    {
        var ex = items.Take(3).Select(i => Paths.Shown(i.Name, workspace) + (i.Count > 1 ? $" · {i.Count:N0}×" : "")).ToList();
        if (distinct > 3) ex.Add($"+ {distinct - 3:N0} more");
        return ex;
    }

    public static ActivityItem Item(ActivityGroups.Group g, string? workspace)
    {
        var agent = Names.Agent(g.Agent);
        var kind = g.Op switch
        {
            "read" => ActivityItemKind.Read, "edit" => ActivityItemKind.Edit, "write" => ActivityItemKind.Write,
            "command" => ActivityItemKind.Command, "mcp" => ActivityItemKind.Mcp, _ => ActivityItemKind.Tool,
        };
        var paths = Names.N(g.Distinct, "distinct path");
        const string b = "Requested: Kai saw the agent ask for this through its hook, before the tool ran. ";
        (string title, string detail, string countText, string expl) = kind switch
        {
            ActivityItemKind.Read => ("Read project files", $"{Names.N(g.Count, "read")} · {paths}", Names.N(g.Count, "read"),
                                      b + "Commands and scripts can read other files that this view doesn't show."),
            ActivityItemKind.Edit => ("Edited project files", $"{Names.N(g.Count, "edit")} · {paths}", Names.N(g.Count, "edit"),
                                      b + "It doesn't confirm the final file content."),
            ActivityItemKind.Write => ("Wrote project files", $"{Names.N(g.Count, "write")} · {paths}", Names.N(g.Count, "write"),
                                       b + "It doesn't confirm the final file content."),
            ActivityItemKind.Command => ("Ran commands", $"{Names.N(g.Count, "command request")} · {Names.N(g.Distinct, "distinct command")}",
                                         Names.N(g.Count, "command"), b + "Kai keeps only each command's program name, never the full command line."),
            ActivityItemKind.Mcp => ("Used MCP tools", $"{Names.N(g.Count, "request")} · {Names.N(g.Distinct, "server")}",
                                     Names.N(g.Count, "request"), b + "What a tool did on its service isn't confirmed by Kai."),
            _ => ("Other tool requests", Names.N(g.Count, "request"), Names.N(g.Count, "request"), b),
        };
        return new ActivityItem
        {
            Id = $"act-{g.Agent}-{g.Op}", Kind = kind, AgentKey = g.Agent, Agent = agent, Title = title, Detail = detail,
            Count = g.Count, CountText = countText, Outcome = "Requested", Evidence = Evidence.Requested,
            Source = $"{agent} hook (activity recording)", Examples = Examples(g.Items, g.Distinct, workspace), Explanation = expl,
        };
    }

    static bool IsToday(DateTimeOffset? d, DateTimeOffset now) => d is { } x && x.ToLocalTime().Date == now.ToLocalTime().Date;

    /// Kai's stops today, one per stop (same decision id listed once).
    public static List<AuditEvent> Stops(IReadOnlyList<AuditEvent> events, string? workspace, DateTimeOffset now)
    {
        var seen = new HashSet<string>();
        return events.Where(e => e.IsBlock && !e.IsNote && !e.IsSilent && !e.IsGrant && IsToday(e.Date, now)
                                 && (e.IsNetwork || Paths.InWorkspace(e.Cwd, workspace))
                                 && seen.Add(e.DecisionId ?? e.Id))
                     .OrderByDescending(e => e.Date).ToList();
    }

    public static ActivityItem StopItem(AuditEvent e, string? workspace) => new()
    {
        Id = "stop-" + (e.DecisionId ?? e.Id), Kind = ActivityItemKind.Stop, AgentKey = e.AgentKey, Agent = e.AgentName,
        Title = Copy.Sentence(e).TrimEnd('.'), Detail = e.IsPrompt ? "the prompt" : e.Object.Length > 0 ? e.Object : (e.ActionLabel ?? "an action"),
        Count = 1, CountText = "1 stopped", Outcome = "Stopped", Evidence = Evidence.Confirmed,
        Source = $"Kai's decision ({e.AgentName} hook)",
        Examples = (e.DecisionId is { } id ? new List<string> { "Decision: " + id } : new()),
        Explanation = $"Kai stopped this specific request: {Names.Sentence(e.Detail)} It doesn't show that other ways to do the same thing were stopped.",
        DecisionId = e.DecisionId, EventId = e.Id,
    };

    /// What Kai Watch saw today, grouped by destination.
    public static List<ActivityItem> Connections(IReadOnlyList<AuditEvent> events, DateTimeOffset now)
    {
        var seen = events.Where(e => e.IsWatch && e.IsNetwork && !e.IsSilent && IsToday(e.Date, now)).ToList();
        if (seen.Count == 0) return new();
        var hosts = seen.GroupBy(e => e.Target ?? "unknown host").Select(g => (Host: g.Key, N: g.Count()))
                        .OrderByDescending(x => x.N).ToList();
        var ex = hosts.Take(3).Select(h => $"{h.Host} · {h.N:N0}×").ToList();
        if (hosts.Count > 3) ex.Add($"+ {hosts.Count - 3:N0} more");
        var agents = seen.Select(e => e.AgentKey).Distinct().ToList();
        return new()
        {
            new ActivityItem
            {
                Id = "net-seen", Kind = ActivityItemKind.Connection, AgentKey = agents.Count == 1 ? agents[0] : "",
                Agent = agents.Count == 1 ? Names.Agent(agents[0]) : "Agents", Title = "Network destinations",
                Detail = $"{Names.N(hosts.Count, "destination")} · watching only", Count = seen.Count,
                CountText = Names.N(seen.Count, "connection"), Outcome = "Seen", Evidence = Evidence.Seen,
                Source = "Kai Watch (watching only)", Examples = ex,
                Explanation = "Kai Watch saw these connections on Windows itself. They don't show what data was sent, and Kai only watched: nothing was blocked.",
            },
        };
    }

    public static List<ActivityItem> Build(ActivityGroups? groups, IReadOnlyList<AuditEvent> events, string? workspace,
                                           bool internetWatching, DateTimeOffset now)
    {
        var o = Stops(events, workspace, now).Select(e => StopItem(e, workspace)).ToList();
        if (groups is not null && (groups.Recording || groups.Groups.Count > 0))
        {
            string[] order = { "edit", "write", "read", "command", "mcp", "tool" };
            int R(string op) { int i = Array.IndexOf(order, op); return i < 0 ? 9 : i; }
            o.AddRange(groups.Groups.OrderBy(g => R(g.Op)).ThenByDescending(g => g.Count).Select(g => Item(g, workspace)));
        }
        if (internetWatching) o.AddRange(Connections(events, now));
        return o;
    }
}
