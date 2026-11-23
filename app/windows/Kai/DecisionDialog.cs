// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// One stop (DecisionDetailSheet in MainWindow.swift): what Kai stopped and
// why, what a retry would get now (kai why), technical details, and for an
// eligible file read the only allow the app offers: one agent, one exact
// file, reads only, 5 minutes, after the owner confirms. Never a private
// key, never Kai's own settings.
using Kai.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Kai;

public static class NarrowAllow
{
    public enum Eligibility { Eligible, TerminalOnly, NotApplicable }

    public static string? Path_(AuditEvent e)
    {
        if (e.Excerpt is not { } p || p.Contains("REDACTED", StringComparison.Ordinal)) return null;
        p = p.Replace('\\', '/');
        bool abs = p.Length > 2 && p[1] == ':' || p.StartsWith("//", StringComparison.Ordinal) || p.StartsWith('~');
        if (!abs)
        {
            if (string.IsNullOrEmpty(e.Cwd)) return null;
            p = e.Cwd.Replace('\\', '/').TrimEnd('/') + "/" + p;
        }
        if (p.StartsWith('~')) p = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile).Replace('\\', '/') + p[1..];
        return p;
    }

    public static bool IsPrivateKey(string p)
    {
        var l = p.ToLowerInvariant();
        var name = Paths.Last(l);
        return l.Contains("/.ssh/") || l.Contains("/.gnupg/") || name.StartsWith("id_rsa") || name.StartsWith("id_ed25519")
               || name.StartsWith("id_ecdsa") || name.StartsWith("id_dsa")
               || new[] { ".pem", ".key", ".p12", ".pfx", ".keystore", ".jks", ".ppk" }.Any(name.EndsWith);
    }

    public static bool IsKaiSettings(AuditEvent e, string p) =>
        e.IsBuiltinRule || p.Contains("/.kai/", StringComparison.OrdinalIgnoreCase) || p.EndsWith("/.kai", StringComparison.OrdinalIgnoreCase)
        || p.Contains("/Kai/", StringComparison.OrdinalIgnoreCase) && p.Contains("Program", StringComparison.OrdinalIgnoreCase);

    public static (Eligibility Kind, string Why) Check(AuditEvent e)
    {
        if (!e.IsBlock || e.IsNetwork || e.IsStorage || e.Source is not ("claude" or "cursor") || e.Tool != "Read" || Path_(e) is not { } p)
            return (Eligibility.NotApplicable, "");
        if (IsPrivateKey(p)) return (Eligibility.TerminalOnly, "Kai never allows private keys from the app.");
        if (IsKaiSettings(e, p)) return (Eligibility.TerminalOnly, "Kai's own settings can't be allowed from the app.");
        return (Eligibility.Eligible, "");
    }
}

public static class DecisionDialog
{
    public static async Task ShowAsync(AuditEvent e, string? workspace)
    {
        if (App.Me.Main?.Root is not { } root) { App.Me.ShowMain(); return; }
        WhyRecord? why = null;
        if (e.DecisionId is { } id)
        {
            var r = await KaiCli.RunAsync("why", id, "--json");
            if (r.Ok) why = WhyRecord.Parse(r.Out);
        }
        var item = ActivityFeed.StopItem(e, workspace);
        var v = Ui.V(10, Ui.T(Names.Sentence(e.Detail), 13));
        if (why?.RetryLine is { } rl) v.Children.Add(Ui.T(Names.Sentence(rl), 13, Ui.Muted));
        v.Children.Add(Ui.T("Evidence: " + EvidenceWords.Label(e.Evidence) + ". " + EvidenceWords.Explain(e.Evidence), 12, Ui.Muted));
        var details = Ui.V(4);
        void Row(string k, string val) => details.Children.Add(Ui.H(10, Ui.T(k, 12, Ui.Muted, wrap: false), Ui.T(val, 12, wrap: true)));
        Row("Agent", e.AgentName);
        Row("Checked by", why?.Component ?? (e.IsNetwork ? "Kai Watch" : "agent hook"));
        Row("Rule", e.Rule);
        Row("Tool", e.Tool ?? "—");
        Row("Target", e.Excerpt is { } x ? (e.ActionLabel == "Command" ? Copy.Program(x) : x) : "—");   // never a command line
        Row("Session", why?.Attribution ?? e.Session ?? "—");
        Row("Decision", e.DecisionId ?? "—");
        Row("Time", e.Date?.ToLocalTime().ToString("g") ?? e.Ts);
        v.Children.Add(new Expander { Header = "Technical details", Content = details, HorizontalAlignment = HorizontalAlignment.Stretch });

        var (kind, whyNot) = NarrowAllow.Check(e);
        var result = Ui.T("", 12, Ui.Muted);
        v.Children.Add(result);
        if (kind == NarrowAllow.Eligibility.TerminalOnly) v.Children.Add(Ui.T(whyNot + " Run it in your own terminal.", 12, Ui.Muted));

        var dlg = new ContentDialog
        {
            XamlRoot = root, Title = Copy.Sentence(e).TrimEnd('.'), Content = Ui.Scroll(v), CloseButtonText = "Done",
            SecondaryButtonText = "Ask about this →", DefaultButton = ContentDialogButton.Close,
            PrimaryButtonText = kind == NarrowAllow.Eligibility.Eligible ? "Allow for 5 minutes…" : "",
        };
        dlg.PrimaryButtonClick += async (s, args) =>
        {
            args.Cancel = true;   // the dialog stays open to show the result
            var def = args.GetDeferral();
            result.Text = await AllowAsync(e);
            dlg.IsPrimaryButtonEnabled = false;
            def.Complete();
        };
        var r2 = await dlg.ShowAsync();
        if (r2 == ContentDialogResult.Secondary) App.Me.Main?.AskAbout("Why did Kai stop this?", focus: item);
    }

    /// Confirm with the owner, then `kai allow-file <path> --read --agent X --for 5m`.
    static async Task<string> AllowAsync(AuditEvent e)
    {
        if (NarrowAllow.Check(e).Kind != NarrowAllow.Eligibility.Eligible || NarrowAllow.Path_(e) is not { } p)
            return "This can't be allowed from the app.";
        if (App.Me.Main is not { } w) return "";
        var shown = Paths.Shown(p, null);
        if (!await OwnerAuth.ConfirmAsync(w, $"Allow {e.AgentName} to read {shown} with its file tool for 5 minutes. Other files, other agents, shell commands such as `type`, and uploads stay checked."))
            return "Not allowed: you didn't confirm.";
        var r = await KaiCli.RunAsync("allow-file", p, "--read", "--agent", e.Source, "--for", "5m");
        if (!r.Ok) return "Kai couldn't save the allow: " + r.Message;
        await App.Me.RefreshAsync();
        return $"Allowed for 5 minutes: {e.AgentName} may read this file with its file tool. Ask it to retry.";
    }
}
