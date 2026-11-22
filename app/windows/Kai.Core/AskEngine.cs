// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Ask Kai, ported from the macOS app (AskEngine.swift): deterministic answers
// from Kai's records. The question is normalised, common typos corrected
// against Kai's own words, and a synonym table picks ONE intent. The answer is
// built only from structured state (kai activity, the audit log, kai
// snapshot, kai status, the policy, Kai Watch), with a "Based on" line and
// coverage limits that Kai renders itself, outside any model's text.
//
// No model decides anything. A model may only (a) pick an intent label from
// the fixed list for a question the table didn't match, validated against
// it, and (b) reword the answer, which is kept only if it keeps every number
// (Phrasers.Accept). Buttons come from records, never from text.
using System.Text;

namespace Kai.Core;

public enum AskIntentKind
{
    Today, Files, Stops, Agent, Destinations, BlindSpots, Unknown, OutOfScope,
    KaiStatus, Recording, Internet, Settings, Version, Help,
}

public sealed record AskIntent(AskIntentKind Kind, string Arg = "")
{
    public static readonly string[] Labels =
        { "today", "files", "stops", "agent", "destinations", "coverage", "kai_status", "recording", "internet",
          "settings", "version", "help", "out_of_scope", "unknown" };

    public string Label => Kind switch
    {
        AskIntentKind.BlindSpots => "coverage",
        AskIntentKind.KaiStatus => "kai_status",
        AskIntentKind.OutOfScope => "out_of_scope",
        _ => Kind.ToString().ToLowerInvariant(),
    };

    public static AskIntent? FromLabel(string label, string question)
    {
        var t = AskEngine.Normalize(question);
        return label switch
        {
            "today" => new(AskIntentKind.Today),
            "files" => new(AskIntentKind.Files),
            "stops" => new(AskIntentKind.Stops),
            "agent" => new(AskIntentKind.Agent, AskEngine.AgentIn(t) ?? ""),
            "destinations" => new(AskIntentKind.Destinations),
            "coverage" => new(AskIntentKind.BlindSpots),
            "kai_status" => new(AskIntentKind.KaiStatus),
            "recording" => new(AskIntentKind.Recording),
            "internet" => new(AskIntentKind.Internet),
            "settings" => new(AskIntentKind.Settings, AskEngine.SettingsTopic(t)),
            "version" => new(AskIntentKind.Version),
            "help" => new(AskIntentKind.Help),
            "out_of_scope" => new(AskIntentKind.OutOfScope),
            "unknown" => new(AskIntentKind.Unknown),
            _ => null,
        };
    }
}

public enum AskActionKind { OpenDecision, Reconnect, OpenActivity, TurnOnRecording, OpenInternet, OpenSettings, RestartWatching }

public sealed record AskAction(AskActionKind Kind, string Title, string Ref = "");

public sealed record AskAnswer
{
    public required AskIntent Intent { get; init; }
    /// Record values are wrapped in <data> tags for a phraser; Display is what the user reads.
    public required string Text { get; init; }
    public required string BasedOn { get; init; }
    public List<AskAction> Actions { get; init; } = new();
    public List<string> Suggestions { get; init; } = new();
    /// Coverage limits: rendered by Kai under the answer, never passed to a model.
    public List<string> Limits { get; init; } = new();
    public string Display => Untag(Text);
    public List<string> Footer => Limits.Select(Untag).Append("Based on: " + BasedOn).ToList();
    public static string Untag(string s) => s.Replace("<data>", "").Replace("</data>", "");
}

/// One agent as Kai measured it (kai snapshot + kai status).
public sealed record AskAgent(string Key, bool Connected, bool Running, int Working, string? Problem = null, bool Untrusted = false);

/// Internet watching as Kai Watch reports it.
public enum AskInternet { Off, On, Stopped }

public sealed record AskContext
{
    public string? Workspace { get; init; }
    public bool Recording { get; init; }
    public bool InternetWatching { get; init; }
    public AskInternet Internet { get; init; }
    public string InternetProblem { get; init; } = "";
    public List<ActivityItem> Items { get; init; } = new();
    public List<AuditEvent> Stops { get; init; } = new();
    public List<AskAgent> Agents { get; init; } = new();
    public Dictionary<string, WhyRecord> Why { get; init; } = new();
    public ActivityItem? Focus { get; init; }
    public SessionFocus? Session { get; init; }
    public string Version { get; init; } = "";
    public string Commit { get; init; } = "";
    public DateTimeOffset? RecordingFirst { get; init; }
    public string? PolicyProblem { get; init; }
    public bool Paused { get; init; }
}

/// Now → "Ask about this": the session as its card shows it.
public sealed record SessionFocus(string Id, string Agent, string AgentTitle, string Project, string Host, string State,
                                  string Started, List<CardCount> Counts, string? Last, int Stops, string? StopLine,
                                  string Topic, bool Recording);

public static class AskEngine
{
    public static readonly string[] SuggestionsList =
        { "Which agents are working right now?", "What did Claude Code do today?", "Why did Kai stop something?", "Is Cursor connected?" };

    public const string CanAnswer = "Kai can answer: whether Kai is on and recording, what happened today, which files "
        + "agents read or changed, what Kai stopped and why, whether an agent is connected, whether Internet "
        + "watching is on, which destinations were seen, what Kai can't see, which version this is, and "
        + "where a setting is.";

    static readonly (string Key, string[] Names)[] AgentNames =
        { ("claude", new[] { "claude", "claude code" }), ("cursor", new[] { "cursor" }), ("codex", new[] { "codex" }) };

    // ------------------------------------------------------------ matching

    public static string Normalize(string q)
    {
        var s = q.ToLowerInvariant().Replace('’', '\'');
        s = new string(s.SkipWhile(c => "=/?!.:;,- \t\n".Contains(c)).ToArray());
        var kept = new string(s.Select(c => char.IsLetterOrDigit(c) || c == '\'' || c == ' ' ? c : ' ').ToArray());
        var words = kept.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return string.Join(" ", FixTypos(words));
    }

    /// Damerau-Levenshtein distance (optimal string alignment).
    public static int Distance(string a, string b)
    {
        if (a.Length == 0) return b.Length;
        if (b.Length == 0) return a.Length;
        var d = new int[a.Length + 1, b.Length + 1];
        for (int i = 0; i <= a.Length; i++) d[i, 0] = i;
        for (int j = 0; j <= b.Length; j++) d[0, j] = j;
        for (int i = 1; i <= a.Length; i++)
            for (int j = 1; j <= b.Length; j++)
            {
                int cost = a[i - 1] == b[j - 1] ? 0 : 1;
                d[i, j] = Math.Min(Math.Min(d[i - 1, j] + 1, d[i, j - 1] + 1), d[i - 1, j - 1] + cost);
                if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) d[i, j] = Math.Min(d[i, j], d[i - 2, j - 2] + 1);
            }
        return d[a.Length, b.Length];
    }

    static readonly Lazy<string[]> Vocabulary = new(() =>
        Synonyms.All.Concat(AgentNames.SelectMany(a => a.Names))
            .SelectMany(p => p.Split(' ')).Select(w => w.Replace("*", "")).Where(w => w.Length >= 5)
            .Distinct().OrderBy(w => w, StringComparer.Ordinal).ToArray());

    static IEnumerable<string> FixTypos(IEnumerable<string> words) => words.Select(w =>
    {
        if (w.Length < 5 || Vocabulary.Value.Contains(w)) return w;
        return Vocabulary.Value.FirstOrDefault(v => Math.Abs(v.Length - w.Length) <= 1 && Distance(v, w) <= 1) ?? w;
    });

    public static bool Has(string t, IEnumerable<string> words)
    {
        var padded = " " + t + " ";
        return words.Any(w => padded.Contains(" " + w + " ", StringComparison.Ordinal)
                              || (w.EndsWith('*') && padded.Contains(" " + w[..^1], StringComparison.Ordinal)));
    }

    public static string? AgentIn(string t)
    {
        foreach (var (key, names) in AgentNames) if (Has(t, names)) return key;
        return null;
    }

    public static class Synonyms
    {
        public static readonly string[] Help = { "help", "what can you answer", "what can you do", "what can i ask", "what do you know",
            "what can you tell me", "what questions", "how does this work", "what are you" };
        public static readonly string[] SettingsVerbs = { "turn off", "turn on", "switch off", "switch on", "disable", "enable",
            "configure", "set up", "setup", "settings", "setting", "preferences", "where do i", "how do i", "how can i", "how to",
            "stop recording", "stop watching", "opt out" };
        public static readonly string[] SettingsTopics = { "recording", "record", "activity", "internet", "network", "watching", "agent",
            "agents", "hooks", "notification*", "sound*", "model", "llama", "qwen", "kai", "check*", "protect*", "uninstall", "pause",
            "claude", "cursor", "codex", "language", "theme", "secrets", "files", "startup", "start with windows" };
        public static readonly string[] Version = { "version", "which kai", "what kai is this", "kai version", "build", "release",
            "what's new", "whats new", "up to date", "update" };
        public static readonly string[] Recording = { "recording", "record*", "keeping a list", "keep a list", "logging activity",
            "tracking", "track activity" };
        public static readonly string[] Internet = { "internet watching", "watching the internet", "watching internet", "kai watch",
            "internet on", "internet off", "is internet", "internet watch", "internet enabled", "network watching",
            "watch the internet", "internet status" };
        public static readonly string[] StatusWords = { "on", "off", "working", "running", "status", "health", "healthy", "doing",
            "enabled", "active", "ok", "okay", "alive", "checking", "protecting", "up", "broken", "fine", "ready", "protected" };
        public static readonly string[] Blind = { "can't see", "cannot see", "can not see", "blind", "not see", "doesn't see",
            "coverage", "limit*", "what can't", "invisible", "miss*", "what can you see", "what can kai see", "can you see",
            "visibility", "what do you see", "what does kai see", "gaps", "what does it see", "what can it see" };
        public static readonly string[] Connected = { "connected", "connection to kai", "working", "running", "installed", "hooked",
            "status", "connect*", "set up", "hooks", "checking", "checked", "protected", "protecting" };
        public static readonly string[] Stops = { "stop*", "block*", "denied", "deny", "prevent*", "refuse*", "why" };
        public static readonly string[] Destinations = { "destination*", "domain*", "host*", "network", "internet", "server*",
            "contact*", "url*", "website*", "connections", "sites", "traffic" };
        public static readonly string[] Files = { "file*", "read", "reads", "changed", "change*", "edit*", "wrote", "write*",
            "modif*", "touch*", "open*", "saved" };
        public static readonly string[] Today = { "today", "happen*", "summary", "summari*", "what did", "recent*", "activity",
            "doing", "going on", "this morning", "so far", "overview", "what has", "what have", "did", "do today" };
        public static readonly string[] Commands = { "write", "fix", "implement", "refactor", "generate", "create", "build",
            "deploy", "install", "delete", "rename", "translate", "summarize", "debug", "add", "make", "run" };
        public static IEnumerable<string> All => Help.Concat(SettingsVerbs).Concat(SettingsTopics).Concat(Version).Concat(Recording)
            .Concat(Internet).Concat(StatusWords).Concat(Blind).Concat(Connected).Concat(Stops).Concat(Destinations).Concat(Files)
            .Concat(Today);
    }

    public static AskIntent Route(string question)
    {
        var t = Normalize(question);
        if (t.Length == 0) return new(AskIntentKind.Help);
        var first = t.Split(' ')[0];
        var agent = AgentIn(t);
        bool aboutKai = Has(t, new[] { "kai", "you" }) || t.StartsWith("is it ", StringComparison.Ordinal);

        if (Has(t, Synonyms.Help)) return new(AskIntentKind.Help);
        bool asksToChange = Has(t, Synonyms.SettingsVerbs) || first is "change" or "set" or "edit";
        if (asksToChange && Has(t, Synonyms.SettingsTopics) && !Has(t, new[] { "what did", "which", "did" }))
            return new(AskIntentKind.Settings, SettingsTopic(t));
        if ((Synonyms.Commands.Contains(first) && !Has(t, new[] { "recording", "record" }))
            || Has(t, new[] { "write me", "write a", "code for", "how do i", "how to" }))
            return new(AskIntentKind.OutOfScope);
        if (Has(t, new[] { "version", "which kai", "what kai is this", "what's new", "whats new" })
            || (Has(t, Synonyms.Version) && aboutKai)) return new(AskIntentKind.Version);
        if (Has(t, Synonyms.Recording) && !Has(t, new[] { "what did", "which files" })) return new(AskIntentKind.Recording);
        if (Has(t, Synonyms.Internet)) return new(AskIntentKind.Internet);
        if (Has(t, Synonyms.Blind)) return new(AskIntentKind.BlindSpots);
        if (agent is null && (t is "status" or "health" or "kai"
                              || (Has(t, new[] { "kai" }) && Has(t, Synonyms.StatusWords) && !Has(t, Synonyms.Stops))))
            return new(AskIntentKind.KaiStatus);
        if (agent is not null && Has(t, Synonyms.Connected) && !Has(t, new[] { "what did", "today" })) return new(AskIntentKind.Agent, agent);
        if (agent is null && Has(t, new[] { "connected", "installed", "hooked" })) return new(AskIntentKind.Agent, "");
        if (agent is null && Has(t, new[] { "which agents", "what agents", "agents working", "working right now", "who is working",
                                            "any agent", "agents running", "is anyone working", "sessions" }))
            return new(AskIntentKind.Agent, "");
        if (Has(t, Synonyms.Stops)) return new(AskIntentKind.Stops);
        if (Has(t, Synonyms.Files)) return new(AskIntentKind.Files);
        if (Has(t, Synonyms.Destinations)) return new(AskIntentKind.Destinations);
        if (Has(t, Synonyms.Today)) return new(AskIntentKind.Today);
        if (agent is not null) return new(AskIntentKind.Agent, agent);
        return new(AskIntentKind.Unknown);
    }

    public static string SettingsTopic(string t)
    {
        if (Has(t, new[] { "recording", "record", "activity", "keep a list" })) return "recording";
        if (Has(t, new[] { "internet", "network", "watching" })) return "internet";
        if (Has(t, new[] { "model", "llama", "qwen", "ask kai", "answers" })) return "model";
        if (Has(t, new[] { "uninstall", "remove kai" })) return "uninstall";
        if (Has(t, new[] { "pause" })) return "pause";
        if (Has(t, new[] { "startup", "start with windows" })) return "advanced";
        if (Has(t, new[] { "check*", "protect*", "secrets", "files" })) return "checks";
        if (AgentIn(t) is not null || Has(t, new[] { "agent", "agents", "hooks" })) return "agents";
        return "general";
    }

    public static AskAnswer Answer(string question, AskContext c, AskIntent? forced = null)
    {
        var intent = forced ?? Route(question);
        var t = Normalize(question);
        if (c.Focus is { } f && intent.Kind != AskIntentKind.OutOfScope && (intent.Kind == AskIntentKind.Unknown || Has(t, new[] { "this", "it", "that" })))
            return About(f, c);
        if (c.Session is { } s && intent.Kind != AskIntentKind.OutOfScope
            && (intent.Kind == AskIntentKind.Unknown || Has(t, new[] { "this", "it", "that", "session" })))
            return AboutSession(s);
        var agent = AgentIn(t);
        return intent.Kind switch
        {
            AskIntentKind.OutOfScope => new AskAnswer
            {
                Intent = intent, Text = "Kai only answers from what it recorded; ask your agent for help with the work itself.",
                BasedOn = "Nothing: this isn't a question about Kai's records.",
            },
            AskIntentKind.Stops => Stops(c, agent),
            AskIntentKind.Files => Files(c, agent),
            AskIntentKind.Destinations => Destinations(c, agent),
            AskIntentKind.Agent => Agent(intent.Arg, c),
            AskIntentKind.BlindSpots => BlindSpots(c, agent),
            AskIntentKind.Today => Today(c, agent),
            AskIntentKind.KaiStatus => KaiStatus(c),
            AskIntentKind.Recording => Recording(c),
            AskIntentKind.Internet => Internet(c),
            AskIntentKind.Settings => Settings(intent.Arg, c),
            AskIntentKind.Version => Version(c),
            AskIntentKind.Help => new AskAnswer
            {
                Intent = intent, Text = CanAnswer, BasedOn = "What Kai records on this computer", Suggestions = SuggestionsList.ToList(),
            },
            _ => new AskAnswer
            {
                Intent = intent, Text = "I can't answer that from Kai's records yet. Try one of these, or ask what Kai can answer.",
                BasedOn = "Nothing matched this question in Kai's records.", Suggestions = Closest(t),
            },
        };
    }

    public static List<string> Closest(string t)
    {
        var examples = new (string Q, IEnumerable<string> Keys)[]
        {
            ("Is Kai recording?", Synonyms.Recording.Append("kai").Append("list")),
            ("Is Kai on?", Synonyms.StatusWords.Append("kai")),
            ("What happened today?", Synonyms.Today),
            ("What did Kai stop?", Synonyms.Stops),
            ("Which files were changed?", Synonyms.Files),
            ("Is Internet watching on?", Synonyms.Internet.Append("internet").Append("network")),
            ("Which destinations did Kai see?", Synonyms.Destinations),
            ("What can't Kai see?", Synonyms.Blind),
            ("Is Cursor connected?", Synonyms.Connected),
        };
        var words = t.Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(w => w.Length >= 3).ToList();
        int Score(IEnumerable<string> keys)
        {
            var ks = keys.SelectMany(k => k.Split(' ')).Select(k => k.Replace("*", "")).Where(k => k.Length >= 3).ToList();
            return words.Count(w => ks.Any(k => w.StartsWith(k, StringComparison.Ordinal) || k.StartsWith(w, StringComparison.Ordinal) || Distance(k, w) <= 2));
        }
        return examples.Select((e, i) => (i, e.Q, s: Score(e.Keys))).OrderByDescending(x => x.s).ThenBy(x => x.i)
                       .Take(3).Select(x => x.Q).ToList();
    }

    static string Where(AskContext c) => c.Workspace is { Length: > 0 } w ? " in " + Paths.Last(w) : "";
    static string Clock(DateTimeOffset d) => d.ToLocalTime().ToString("HH:mm");
    public static string Data(string s) => PhrasePrompts.Data(s);

    public static string Reports(string key) => key switch
    {
        "claude" => "reads, edits, writes",
        "cursor" => "reads only (not its editor's writes)",
        "codex" => "commands, no file events",
        _ => "no hook: nothing recorded",
    };

    // --------------------------------------------------------- Kai itself

    public static string RecordingWords(AskContext c) =>
        !c.Recording ? "Activity recording is off"
        : "Activity recording is on" + (c.RecordingFirst is { } d ? $" (first record today at {Clock(d)})" : "");

    public static string InternetWords(AskContext c) => c.Internet switch
    {
        AskInternet.On => "Internet watching is on (Watch only)",
        AskInternet.Stopped => "Internet watching stopped" + (c.InternetProblem.Length > 0 ? ": " + c.InternetProblem.TrimEnd('.') : ""),
        _ => "Internet watching is off",
    };

    static AskAnswer KaiStatus(AskContext c)
    {
        var lines = new List<string>();
        var checkedAgents = c.Agents.Where(a => a.Connected && !a.Untrusted).ToList();
        if (c.PolicyProblem is { } p) lines.Add("Kai's policy has an error: " + Names.Sentence(p));
        else if (c.Paused) lines.Add("Kai is paused; its checks resume by themselves.");
        else if (checkedAgents.Count == 0) lines.Add("Kai is off: no agent is connected to its checks.");
        else lines.Add("Kai is on: it checks " + Names.Joined(checkedAgents.Select(a => Names.Agent(a.Key)).ToList()) + ".");
        if (c.Agents.FirstOrDefault(a => a.Untrusted) is { } u)
            lines.Add($"{Names.Agent(u.Key)} is connected but not checked until you run /hooks in Codex once.");
        var off = c.Agents.Where(a => !a.Connected).Select(a => Names.Agent(a.Key)).ToList();
        if (off.Count > 0) lines.Add("Not connected: " + Names.Joined(off) + ".");
        lines.Add(RecordingWords(c) + " · " + InternetWords(c) + ".");
        var actions = new List<AskAction>();
        if (!c.Recording) actions.Add(new(AskActionKind.TurnOnRecording, "Turn on activity recording"));
        if (c.Internet == AskInternet.Stopped) actions.Add(new(AskActionKind.RestartWatching, "Restart"));
        else if (c.Internet == AskInternet.Off) actions.Add(new(AskActionKind.OpenInternet, "Internet settings"));
        return new AskAnswer { Intent = new(AskIntentKind.KaiStatus), Text = string.Join("\n", lines.Take(4)),
                               BasedOn = "kai status, kai snapshot and your settings", Actions = actions };
    }

    static AskAnswer Recording(AskContext c)
    {
        var cov = string.Join(" ", c.Agents.Select(a => $"{Names.Agent(a.Key)}: {Reports(a.Key)}."));
        if (c.Recording)
        {
            var w = RecordingWords(c);
            return new AskAnswer { Intent = new(AskIntentKind.Recording),
                Text = "Yes, " + char.ToLowerInvariant(w[0]) + w[1..] + ". " + cov + " Kai keeps paths and a command's program name, never file contents.",
                BasedOn = "Settings: record_activity, and kai activity" };
        }
        return new AskAnswer { Intent = new(AskIntentKind.Recording),
            Text = "No, activity recording is off, so Kai keeps only what it stopped. Turn it on to keep a list of what agents read, edit and run, on this computer only.",
            BasedOn = "Settings: record_activity is off",
            Actions = { new(AskActionKind.TurnOnRecording, "Turn on activity recording") } };
    }

    static AskAnswer Internet(AskContext c)
    {
        var text = InternetWords(c) + ".";
        if (c.Internet == AskInternet.On) text += " Kai lists the destinations agents connect to; it doesn't read traffic or block anything.";
        if (c.Internet == AskInternet.Off) text += " When on, Kai Watch lists the destinations agents connect to (Watch only).";
        return new AskAnswer { Intent = new(AskIntentKind.Internet), Text = text, BasedOn = "Kai Watch's state on this computer",
            Actions = c.Internet switch
            {
                AskInternet.Stopped => new() { new(AskActionKind.RestartWatching, "Restart") },
                AskInternet.Off => new() { new(AskActionKind.OpenInternet, "Internet settings") },
                _ => new(),
            } };
    }

    static AskAnswer Settings(string topic, AskContext c)
    {
        var (place, r) = topic switch
        {
            "recording" => ("Settings → Advanced → “Keep a list of what agents read, edit and run”", "advanced"),
            "internet" => ("Settings → Internet", "internet"),
            "model" => ("the model menu next to the Ask button, or Settings → Ask Kai model", "model"),
            "uninstall" => ("Windows Settings → Apps → Installed apps → Kai", ""),
            "pause" => ("the Kai icon in the taskbar → Pause", ""),
            "checks" => ("Settings → Advanced → Policy file", "advanced"),
            "agents" => ("Settings → Agents (one switch per agent)", "agents"),
            "advanced" => ("Settings → Advanced", "advanced"),
            _ => ("Settings", "agents"),
        };
        var actions = new List<AskAction>();
        if (r.Length > 0) actions.Add(new(AskActionKind.OpenSettings, "Open Settings", r));
        if (topic == "recording" && !c.Recording) actions.Add(new(AskActionKind.TurnOnRecording, "Turn on activity recording"));
        return new AskAnswer { Intent = new(AskIntentKind.Settings, topic),
            Text = $"Kai doesn't change settings from a chat. You'll find it in {place}.", BasedOn = "Kai's settings layout", Actions = actions };
    }

    static AskAnswer Version(AskContext c) => new()
    {
        Intent = new(AskIntentKind.Version),
        Text = "This is Kai " + (c.Version.Length == 0 ? "an unknown version" : c.Version) + (c.Commit.Length == 0 ? "" : $" (commit {c.Commit})") + ".",
        BasedOn = "kai status",
    };

    // ------------------------------------------------------------ records

    static AskAnswer Stops(AskContext c, string? agent)
    {
        var s = c.Stops.Where(e => agent is null || e.AgentKey == agent).ToList();
        var who = agent is null ? "" : " for " + Names.Agent(agent);
        if (s.Count == 0)
            return new AskAnswer { Intent = new(AskIntentKind.Stops), Text = $"No matching record: Kai recorded no stops{who}{Where(c)} today.",
                BasedOn = "Kai's decisions (audit log), today", Limits = { "No stop doesn't mean every action was checked." } };
        var lines = s.Take(3).Select(e =>
        {
            var l = $"Kai stopped {e.AgentName}'s {Copy.What(e).Split(' ')[0]} ({Data(e.Object.Length > 0 ? e.Object : "the request")}), because {e.Detail.Trim('.', ' ')}";
            if (e.DecisionId is { } id && c.Why.TryGetValue(id, out var w) && w.RetryLine is { } rl) l += "; " + rl.ToLowerInvariant();
            return l + ".";
        });
        var more = s.Count > 3 ? $" And {s.Count - 3} more in Activity → Stops." : "";
        var actions = s.Take(3).Select(e => new AskAction(AskActionKind.OpenDecision, "Open decision", e.DecisionId ?? e.Id)).ToList();
        if (actions.Count > 1) actions = new() { new(AskActionKind.OpenActivity, "Open Stops", "stops") };
        return new AskAnswer { Intent = new(AskIntentKind.Stops),
            Text = $"Kai recorded {Names.N(s.Count, "stop")}{who}{Where(c)} today. " + string.Join(" ", lines) + more,
            BasedOn = "Kai's decisions (audit log)" + (c.Why.Count == 0 ? "" : " and kai why") + ", today", Actions = actions };
    }

    static readonly ActivityItemKind[] FileKinds = { ActivityItemKind.Read, ActivityItemKind.Edit, ActivityItemKind.Write };

    static AskAnswer Files(AskContext c, string? agent)
    {
        if (!c.Recording && !c.Items.Any(i => FileKinds.Contains(i.Kind)))
            return new AskAnswer { Intent = new(AskIntentKind.Files),
                Text = "No matching record: activity recording is off, so Kai has no list of files agents read or changed. Kai still records what it stopped.",
                BasedOn = "Settings: activity recording is off", Actions = { new(AskActionKind.TurnOnRecording, "Turn on activity recording") } };
        var f = c.Items.Where(i => FileKinds.Contains(i.Kind) && (agent is null || i.AgentKey == agent)).ToList();
        if (f.Count == 0)
            return new AskAnswer { Intent = new(AskIntentKind.Files),
                Text = $"No matching record: Kai recorded no file reads or changes{(agent is null ? "" : " by " + Names.Agent(agent))}{Where(c)} today.",
                BasedOn = "kai activity, today", Limits = FileLimits(c, agent) };
        var lines = f.Take(4).Select(i => $"{i.Agent} {i.Title.ToLowerInvariant()}: {i.Detail}"
                                           + (i.Examples.Count == 0 ? "" : $" (for example {Data(i.Examples[0])})"));
        return new AskAnswer { Intent = new(AskIntentKind.Files), Text = string.Join(". ", lines) + ".",
            BasedOn = "kai activity (activity recording), today", Actions = { new(AskActionKind.OpenActivity, "Open Activity", "files") },
            Limits = new List<string> { "These are requests Kai saw through the agents' hooks, not every file access: commands and scripts can touch other files." }
                     .Concat(FileLimits(c, agent)).ToList() };
    }

    static List<string> FileLimits(AskContext c, string? agent)
    {
        var keys = agent is not null ? new List<string> { agent } : c.Agents.Count == 0 ? new() { "cursor", "codex" } : c.Agents.Select(a => a.Key).ToList();
        var o = new List<string>();
        if (keys.Contains("cursor")) o.Add("Cursor doesn't report its editor's writes.");
        if (keys.Contains("codex")) o.Add("Codex reports no file events.");
        return o;
    }

    static AskAnswer Destinations(AskContext c, string? agent)
    {
        if (c.Internet != AskInternet.On)
            return new AskAnswer { Intent = new(AskIntentKind.Destinations),
                Text = c.Internet == AskInternet.Stopped
                    ? "No complete record: Internet watching stopped, so Kai can't say which destinations were or weren't contacted since then."
                    : "No matching record: Internet watching is off, so Kai has no list of destinations. It can't say which were or weren't contacted.",
                BasedOn = "Kai Watch's state on this computer",
                Actions = { c.Internet == AskInternet.Stopped ? new(AskActionKind.RestartWatching, "Restart") : new(AskActionKind.OpenInternet, "Internet settings") } };
        var n = c.Items.Where(i => i.Kind == ActivityItemKind.Connection && (agent is null || i.AgentKey == agent)).ToList();
        if (n.Count == 0)
            return new AskAnswer { Intent = new(AskIntentKind.Destinations), Text = "No matching record: Kai Watch saw no agent connections today.",
                BasedOn = "Kai Watch (watching only), today" };
        var g = n[0];
        return new AskAnswer { Intent = new(AskIntentKind.Destinations),
            Text = $"Kai saw {g.CountText} to {g.Detail.Replace(" · watching only", "")}: " + string.Join(", ", g.Examples.Select(Data)) + ".",
            BasedOn = "Kai Watch (watching only), today", Actions = { new(AskActionKind.OpenActivity, "Open Activity", "connections") },
            Limits = { "Internet is Watch-only: nothing was blocked, and a connection doesn't show what was sent.",
                       "A connection through a proxy on this computer shows as the proxy, not the site." } };
    }

    public static string AgentWords(AskAgent a)
    {
        var name = Names.Agent(a.Key);
        if (a.Connected && a.Untrusted) return $"{name} is connected, but Kai hasn't seen it use Kai's hook: not checked until you run /hooks in Codex once.";
        if (a.Connected) return $"{name} is connected" + (a.Working > 0 ? $" · {a.Working} working" : "") + ".";
        return $"{name} is not connected" + (a.Running ? ", but it's running: activity unknown." : ": activity unavailable.")
               + (a.Problem is { Length: > 0 } p ? $" ({p.TrimEnd('.')})" : "");
    }

    static AskAnswer Agent(string key, AskContext c)
    {
        var rows = key.Length == 0 ? c.Agents : c.Agents.Where(a => a.Key == key).ToList();
        if (rows.Count == 0)
            return new AskAnswer { Intent = new(AskIntentKind.Agent, key),
                Text = $"No matching record: Kai didn't find {Names.Agent(key)} on this computer.", BasedOn = "kai snapshot (agents found on this computer)" };
        return new AskAnswer { Intent = new(AskIntentKind.Agent, key), Text = string.Join(" ", rows.Select(AgentWords)),
            BasedOn = "kai snapshot and kai status",
            Actions = rows.Where(a => !a.Connected).Select(a => new AskAction(AskActionKind.Reconnect, "Connect " + Names.Agent(a.Key), a.Key)).ToList(),
            Limits = new List<string> { "Connected is about Kai's integration only; working means a connected agent ran something in the last 15 minutes." }
                     .Concat(rows.Select(a => AgentReports.Footnote(a.Key)).Where(x => x is not null).Select(x => char.ToUpperInvariant(x![0]) + x[1..] + ".")).ToList() };
    }

    static AskAnswer BlindSpots(AskContext c, string? agent)
    {
        var s = new List<string>();
        if (agent is not null) s.Add($"{Names.Agent(agent)}: {AgentReports.Coverage(agent)}");
        s.Add("Kai's checks run inside each agent (hooks): a script or program the agent starts can read or change files Kai doesn't check.");
        if (agent is null) s.Add("Claude Code reports reads, edits and writes; Cursor reports reads but not its editor's writes; Codex reports commands and MCP calls but no file events.");
        s.Add("Internet is Watch-only on Windows: Kai Watch can list destinations, never what was sent, and nothing is blocked at the system level.");
        if (!c.Recording) s.Add("Activity recording is off, so Kai keeps only its stops.");
        if (c.Internet != AskInternet.On) s.Add(InternetWords(c) + ".");
        return new AskAnswer { Intent = new(AskIntentKind.BlindSpots), Text = s[0],
            BasedOn = "Kai's coverage notes (docs/COVERAGE.md) and your settings", Limits = s.Skip(1).ToList() };
    }

    static AskAnswer Today(AskContext c, string? agent)
    {
        var lines = new List<string>();
        var agents = c.Agents.Where(a => agent is null || a.Key == agent).ToList();
        if (agents.Count > 0)
            lines.Add(string.Join(" · ", agents.Select(a =>
            {
                var name = Names.Agent(a.Key);
                if (!a.Connected) return $"{name}: not connected" + (a.Running ? " (running, activity unknown)" : "");
                if (a.Untrusted) return $"{name}: waiting for /hooks in Codex";
                if (a.Working > 0) return $"{name}: {Names.N(a.Working, "working session")}";
                return $"{name}: " + (a.Running ? "idle" : "no session running");
            })));
        var acts = c.Items.Where(i => i.Kind != ActivityItemKind.Stop && (agent is null || i.AgentKey == agent)).ToList();
        if (acts.Count > 0) lines.Add(string.Join("; ", acts.Take(3).Select(i => $"{i.Agent}: {i.Title.ToLowerInvariant()}, {i.CountText}")));
        else if (!c.Recording) lines.Add("No list of reads, edits or commands: activity recording is off");
        else lines.Add($"No reads, edits or commands recorded{Where(c)}" + (agent is null ? "" : " for " + Names.Agent(agent)));
        var stops = c.Stops.Where(e => agent is null || e.AgentKey == agent).ToList();
        lines.Add(stops.Count == 0 ? "Kai recorded no stops" : $"Kai recorded {Names.N(stops.Count, "stop")}");
        lines.Add(RecordingWords(c) + " · " + InternetWords(c));
        var actions = new List<AskAction> { new(AskActionKind.OpenActivity, "Open Activity", "all") };
        if (!c.Recording) actions.Add(new(AskActionKind.TurnOnRecording, "Turn on activity recording"));
        return new AskAnswer { Intent = new(AskIntentKind.Today),
            Text = $"Today{Where(c)}" + (agent is null ? "" : " for " + Names.Agent(agent)) + ":\n" + string.Join("\n", lines.Take(4).Select(Names.Sentence)),
            BasedOn = (c.Recording ? "kai activity, " : "") + "Kai's decisions, kai snapshot and your settings, today",
            Actions = actions,
            Limits = agents.Where(a => a.Connected).Select(a => AgentReports.Footnote(a.Key)).Where(x => x is not null)
                           .Select(x => char.ToUpperInvariant(x![0]) + x[1..] + ".").ToList() };
    }

    static AskAnswer AboutSession(SessionFocus s)
    {
        var b = new StringBuilder($"{s.AgentTitle} in {s.Project}" + (s.Host.Length == 0 ? "" : $" ({s.Host})") + $": {s.State.ToLowerInvariant()}"
                                  + (s.Started.Length == 0 ? "" : $", {s.Started}") + ".");
        if (!s.Recording) b.Append(" Activity recording is off, so Kai kept only its stops for this session.");
        else
        {
            var counted = s.Counts.Where(x => x.NotReportedBy is null && x.Kind != CountKind.Stops).Select(x => x.Text).ToList();
            if (counted.Count > 0) b.Append(" Kai recorded " + Names.Joined(counted) + ".");
            if (s.Last is { } l) b.Append(" Last: " + Data(l) + ".");
        }
        b.Append(s.Stops == 0 ? " Kai stopped nothing in it." : $" Kai stopped {Names.N(s.Stops, "request")} in it"
                 + (s.StopLine is { } sl ? ", most recently: " + Data(sl) : "") + ".");
        if (s.Topic.Length > 0) b.Append(" Topic, as the agent reported it: " + Data(s.Topic) + ".");
        return new AskAnswer { Intent = new(AskIntentKind.Unknown), Text = b.ToString(), BasedOn = "kai snapshot and kai activity, this session",
            Actions = { new(AskActionKind.OpenActivity, "Open in Activity", "session:" + s.Id) },
            Limits = s.Counts.Where(x => x.NotReportedBy is not null).Select(x => char.ToUpperInvariant(x.Text[0]) + x.Text[1..] + ".")
                     .Append($"Counts are requests Kai saw through {s.AgentTitle}'s hook, not everything it did.").ToList() };
    }

    static AskAnswer About(ActivityItem i, AskContext c)
    {
        var text = $"{i.Title} ({i.Agent}): {i.Outcome.ToLowerInvariant()}. {i.Explanation}";
        if (i.DecisionId is { } id && c.Why.TryGetValue(id, out var r))
        {
            if (!string.IsNullOrEmpty(r.Reason)) text += " Reason: " + Names.Sentence(r.Reason);
            if (r.RetryLine is { } l) text += " " + Names.Sentence(l);
        }
        var actions = new List<AskAction>();
        if (i.Kind == ActivityItemKind.Stop) actions.Add(new(AskActionKind.OpenDecision, "Open decision", i.DecisionId ?? i.EventId ?? ""));
        return new AskAnswer { Intent = new(AskIntentKind.Unknown), Text = text, BasedOn = i.Source, Actions = actions };
    }
}
