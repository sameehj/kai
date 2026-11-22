// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// One record of %USERPROFILE%\.kai\audit.log, as the macOS app reads it
// (AuditLog.swift), and the sentences the Windows app shows for it.
//
// Copy rules (the UX decisions of 2026-11-19 and the launch review): Kai is
// the subject when it acted ("Kai stopped Claude Code's read of .env"), never
// the agent ("Claude Code tried..."); Watch records say what Kai saw ("Kai saw
// Claude Code connect to api.github.com"); nothing claims a block Kai didn't
// make. Every record carries one evidence level.
using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Kai.Core;

/// How Kai knows: shown on every record.
public enum Evidence
{
    /// The agent asked for it through its hook, before the tool ran.
    Requested,
    /// The agent reported it after the tool ran.
    ToolReported,
    /// Kai Watch saw it happen at the operating-system level (ETW).
    Seen,
    /// Kai's own decision: Kai stopped, asked or cleaned it.
    Confirmed,
    /// No record says.
    Unknown,
}

public static class EvidenceWords
{
    public static string Label(Evidence e) => e switch
    {
        Evidence.Requested => "Requested",
        Evidence.ToolReported => "Tool-reported",
        Evidence.Seen => "Seen",
        Evidence.Confirmed => "Confirmed",
        _ => "Unknown",
    };
    public static string Explain(Evidence e) => e switch
    {
        Evidence.Requested => "The agent asked for this through its hook, before the tool ran. It doesn't confirm the tool ran.",
        Evidence.ToolReported => "The agent reported this after its tool ran.",
        Evidence.Seen => "Kai Watch saw this on Windows itself, outside the agent's hooks. Kai only watched: it didn't stop it.",
        Evidence.Confirmed => "Kai's own decision: Kai did this.",
        _ => "Kai has no record that says.",
    };
}

public sealed record AuditEvent
{
    public string Ts { get; init; } = "";
    public string Source { get; init; } = "";
    public string Event { get; init; } = "";
    public string Decision { get; init; } = "";
    public string Rule { get; init; } = "";
    public string RawDetail { get; init; } = "";
    public string H { get; init; } = "";
    public string? Tool { get; init; }
    public string? Target { get; init; }
    public string? Match { get; init; }
    public string? Session { get; init; }
    public string? Cwd { get; init; }
    public string? Identity { get; init; }
    public string? DecisionId { get; init; }

    public string Id => H;
    public string Detail => PlainDetail.Text(RawDetail, Source, Decision, IsPrompt);
    public DateTimeOffset? Date =>
        DateTimeOffset.TryParse(Ts, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d) ? d : null;

    public bool IsBlock => Decision == "block";
    public bool IsAsk => Decision == "ask";
    public bool IsNote => Decision == "note";
    public bool IsNotable => Decision != "allow";
    public bool IsNetwork => Source is "network" or "gateway";
    public bool IsStorage => Source == "storage";
    public bool IsGrant => Source == "grant";
    public bool IsPrompt => Event is "UserPromptSubmit" or "beforeSubmitPrompt";
    /// Kai Watch's records: observed, never blocked (decision "log").
    public bool IsWatch => (IsNetwork || IsStorage) && Decision == "log";

    public bool IsTelemetry => Detail.StartsWith("telemetry to ", StringComparison.Ordinal);
    public bool IsKeptBlocked => Detail.StartsWith("kept blocked", StringComparison.Ordinal);
    public bool IsQuicFallback => IsNetwork && Target == "QUIC";
    /// In the log and in Activity, never in notifications or counts.
    public bool IsSilent => IsTelemetry || IsKeptBlocked || IsQuicFallback;
    public bool IsUnknownHost => IsNetwork && Detail.EndsWith("host unknown", StringComparison.Ordinal);

    /// "claude": network and storage records name the agent in `event`.
    public string AgentKey
    {
        get
        {
            if (IsGrant)
            {
                int i = Detail.IndexOf("agent=", StringComparison.Ordinal);
                if (i >= 0) return new string(Detail[(i + 6)..].TakeWhile(c => !char.IsWhiteSpace(c)).ToArray());
            }
            return IsNetwork || IsStorage ? Event : Source;
        }
    }
    public string AgentName => Names.Agent(AgentKey);

    public string? ActionLabel
    {
        get
        {
            if (IsPrompt) return "Prompt";
            if (IsNetwork) return "Connection";
            if (IsStorage) return "File access";
            var t = Tool ?? "";
            return t switch
            {
                "Bash" or "Shell" or "shell" or "PowerShell" => "Command",
                "Read" => "File read",
                "Edit" or "MultiEdit" or "Write" or "NotebookEdit" or "apply_patch" => "File edit",
                "Grep" or "Glob" or "LS" => "File search",
                "" => null,
                _ when t.StartsWith("mcp__", StringComparison.Ordinal) || t == "MCP" => "Tool call",
                _ => t,
            };
        }
    }

    public string? Excerpt => string.IsNullOrEmpty(Target) ? null : Target;

    /// Kai's own protection (its files, the agents' hook settings).
    public bool IsBuiltinRule
    {
        get
        {
            string[] builtin = { "kai_self_protect", "~/.kai", ".claude/settings.json", ".claude/settings.local.json",
                                 ".cursor/hooks.json", ".codex/hooks.json", ".codex/config.toml", "hooks.json", "config.toml",
                                 "kai_program" };
            return builtin.Any(b => Rule == b || Rule.EndsWith(b, StringComparison.Ordinal));
        }
    }

    public Evidence Evidence => IsWatch ? Evidence.Seen
                              : IsBlock || IsAsk || Decision is "redact" or "replace" or "exempt" ? Evidence.Confirmed
                              : Source == "grant" ? Evidence.Confirmed
                              : Evidence.Requested;

    /// What was acted on, short: a file name, a program name, a host.
    public string Object
    {
        get
        {
            var x = Excerpt;
            if (x is null) return "";
            return ActionLabel switch
            {
                "Command" => Copy.Program(x),
                "Connection" => x,
                _ => Paths.Last(x),
            };
        }
    }

    public static AuditEvent? Parse(string line)
    {
        var o = J.Parse(line);
        if (o is null || o["h"] is null) return null;
        string? N(string k) => o[k] is null ? null : J.S(o, k);
        return new AuditEvent
        {
            Ts = J.S(o, "ts"), Source = J.S(o, "source"), Event = J.S(o, "event"), Decision = J.S(o, "decision"),
            Rule = J.S(o, "rule"), RawDetail = J.S(o, "detail"), H = J.S(o, "h"), Tool = N("tool"), Target = N("target"),
            Match = N("match"), Session = N("session"), Cwd = N("cwd"), Identity = N("identity"), DecisionId = N("decision_id"),
        };
    }
}

/// The copy rules in one place: every sentence the app shows about a record.
public static class Copy
{
    /// A command as its program's name only, never the command line.
    public static string Program(string cmd)
    {
        foreach (var w in cmd.Split(new[] { ' ', '\t', '\n' }, StringSplitOptions.RemoveEmptyEntries))
        {
            if (w.Contains('=')) continue;                    // VAR=value: values can be secrets
            var b = Paths.Last(w);
            var clean = new string(b.Where(c => !"\"'`$();|&".Contains(c)).ToArray());
            if (clean.Length > 0) return clean.Length > 40 ? clean[..40] : clean;
        }
        return "a command";
    }

    /// "read of .env", "command (npm)", "change to app.py", "prompt".
    public static string What(AuditEvent e)
    {
        var obj = e.Object;
        return e.ActionLabel switch
        {
            "Prompt" => "prompt",
            "File read" => obj.Length > 0 ? $"read of {obj}" : "read",
            "File edit" => obj.Length > 0 ? $"change to {obj}" : "change",
            "Command" => obj.Length > 0 ? $"command ({obj})" : "command",
            "File search" => "file search",
            "Tool call" => "tool call",
            "Connection" => obj.Length > 0 ? $"connection to {obj}" : "connection",
            "File access" => obj.Length > 0 ? $"use of {obj}" : "file access",
            _ => "request",
        };
    }

    static string Possessive(string name) => name.EndsWith('s') ? name + "'" : name + "'s";

    /// The one sentence for a record. Kai is the subject when Kai acted.
    public static string Sentence(AuditEvent e)
    {
        var who = e.AgentName;
        if (e.IsGrant)
        {
            var t = e.Target ?? "";
            return e.Event switch
            {
                "approved" => $"You allowed {who} to use {t}.",
                "used" => $"{who} used its permission for {t}.",
                "denied" => $"You kept {t} blocked for {who}.",
                "revoked" => $"The permission for {t} was removed.",
                "expired" => $"The permission for {t} ended.",
                "rejected" => $"Kai ignored a permission for {t} that Kai didn't sign.",
                _ => $"Permission {e.Event} for {t}.",
            };
        }
        if (e.IsWatch && e.IsNetwork)
        {
            if (e.IsTelemetry) return $"Kai saw {Possessive(who)} telemetry to {Host(e)}.";
            if (e.IsUnknownHost) return $"Kai saw {who} connect to {e.Target}, host unknown.";
            return $"Kai saw {who} connect to {e.Target}.";
        }
        if (e.IsWatch && e.IsStorage)
            return $"Kai saw {who} open {Paths.Last(e.Target ?? "a protected file")} outside its hooks.";
        if (e.Decision is "redact" or "replace")
            return $"Kai removed a secret from {Possessive(who)} {(e.IsPrompt ? "prompt" : "request")}.";
        if (e.IsBlock && e.IsBuiltinRule)
            return $"Kai stopped {Possessive(who)} {(e.ActionLabel == "File read" ? "read of" : "change to")} Kai's own settings.";
        if (e.IsBlock) return $"Kai stopped {Possessive(who)} {What(e)}.";
        if (e.IsAsk) return $"Kai asked you about {Possessive(who)} {What(e)}.";
        if (e.Decision == "exempt") return $"Kai allowed {Possessive(who)} {What(e)}: your exception.";
        if (e.Decision == "warn") return $"Kai warned about {Possessive(who)} {What(e)}.";
        return $"Kai noted {Possessive(who)} {What(e)}.";
    }

    static string Host(AuditEvent e)
    {
        var d = e.Detail;
        const string p = "telemetry to ";
        if (!d.StartsWith(p, StringComparison.Ordinal)) return e.Target ?? "a host";
        var rest = d[p.Length..];
        int sp = rest.IndexOf(' ');
        return sp > 0 ? rest[..sp] : rest;
    }

    /// The outcome word on an Activity row.
    public static string Outcome(AuditEvent e) =>
        e.IsWatch ? "Seen" : e.IsBlock ? "Stopped" : e.IsAsk ? "Asked you"
        : e.Decision is "redact" or "replace" ? "Cleaned" : e.Decision == "exempt" ? "Allowed by your exception"
        : e.IsGrant ? "Allowed" : "Noted";

    /// The reason, in plain words: what follows "...: " up to the advice to the agent.
    public static string Why(string detail)
    {
        var d = detail;
        int c = d.IndexOf(": ", StringComparison.Ordinal);
        if (c >= 0) d = d[(c + 2)..];
        foreach (var cut in new[] { " Don't retry", " (Kai decision", " If this was intended" })
        {
            int i = d.IndexOf(cut, StringComparison.Ordinal);
            if (i >= 0) d = d[..i];
        }
        d = d.Trim();
        return d.EndsWith('.') ? d[..^1] : d;
    }

    /// The brief a card's copy button puts on the clipboard. No secret values,
    /// no file contents, nothing the scanner hid.
    public static string Brief(AuditEvent e, string? sessionName)
    {
        var where = string.Join(" · ", new[] { e.AgentName, sessionName ?? "", e.Cwd ?? "" }.Where(s => s.Length > 0));
        var todo = e.IsBlock || e.IsAsk ? "allow it in Kai if it was intended, or leave it stopped" : "nothing is needed";
        var lines = new List<string> { "What happened: " + Sentence(e), "Where: " + where };
        var w = Why(e.Detail);
        if (w.Length > 0 && !e.IsWatch) lines.Add("Why: " + w);
        lines.Add($"Decision ID: {e.DecisionId ?? "none"} · {e.Date?.ToLocalTime().ToString("yyyy-MM-dd HH:mm") ?? e.Ts}");
        lines.Add("Evidence: " + EvidenceWords.Label(e.Evidence));
        lines.Add("What you can do: " + todo);
        return string.Join("\n", lines.Where(l => !l.Contains("REDACTED", StringComparison.Ordinal)));
    }
}

/// Scanner findings in plain words (records written before the CLI said
/// them that way). Mirrors kai_rule_plain in src/scan.c.
public static class PlainDetail
{
    static readonly Dictionary<string, string> Words = new()
    {
        ["private_key_block"] = "a private key", ["aws_access_key"] = "an AWS access key",
        ["aws_secret_key"] = "an AWS secret key", ["github_token"] = "a GitHub token", ["gitlab_token"] = "a GitLab token",
        ["slack_token"] = "a Slack token", ["stripe_key"] = "a Stripe key", ["google_api_key"] = "a Google API key",
        ["openai_key"] = "an OpenAI API key", ["anthropic_key"] = "an Anthropic API key",
        ["openrouter_key"] = "an OpenRouter API key", ["jwt"] = "a login token (JWT)",
        ["db_url_with_password"] = "a database address with its password", ["password_assign"] = "a password",
        ["generic_secret_assign"] = "a password-like secret",
    };
    const string Finding = @"(?:secret" + @":([A-Za-z0-9_.\-]+)|term:([^,]+?)|([A-Za-z0-9_.\-]+)) x[0-9]+ \((?:redact|block|warn|replace|none)\)";
    static readonly Regex Run = new($"{Finding}(?:, {Finding})*");
    static readonly Regex One = new(Finding);

    static string Word(Match m)
    {
        if (m.Groups[2].Success) return $"the company term \"{m.Groups[2].Value}\"";
        var id = m.Groups[1].Success ? m.Groups[1].Value : m.Groups[3].Value;
        return Words.TryGetValue(id, out var w) ? w : $"a secret your rule \"{id}\" looks for";
    }

    static string Findings(string run) =>
        Names.Joined(One.Matches(run).Select(Word).Distinct().ToList());

    public static string Text(string raw, string source, string decision, bool isPrompt)
    {
        if (!raw.Contains(" x", StringComparison.Ordinal) || !raw.Contains('(')) return raw;
        var runs = Run.Matches(raw);
        if (runs.Count == 0) return raw;
        if (isPrompt && decision == "block" && runs.Count == 1 && runs[0].Length == raw.Length)
            return $"Prompt blocked: it contained {Findings(raw)}. {Names.Agent(source)} can't redact prompts, so Kai blocked it.";
        var s = raw;
        for (int i = runs.Count - 1; i >= 0; i--)
            s = s[..runs[i].Index] + Findings(runs[i].Value) + s[(runs[i].Index + runs[i].Length)..];
        return s;
    }
}

/// Reads the audit log's notable records (newest first), from its tail.
public static class AuditReader
{
    public static List<AuditEvent> ReadRecent(string path, int keep = 400, long maxBytes = 1_000_000)
    {
        var list = new List<AuditEvent>();
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return list;
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        long start = Math.Max(0, fs.Length - maxBytes);
        fs.Seek(start, SeekOrigin.Begin);
        using var sr = new StreamReader(fs);
        if (start > 0) sr.ReadLine();   // a partial first line
        string? line;
        while ((line = sr.ReadLine()) is not null)
            if (AuditEvent.Parse(line) is { IsNotable: true } e) list.Add(e);
        list.Reverse();
        return list.Count > keep ? list.GetRange(0, keep) : list;
    }
}
