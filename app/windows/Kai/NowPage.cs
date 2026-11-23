// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Now (NowPage.swift): one card per live agent session, grouped by agent.
// Each card: the project and host, Working or Idle, its counts (or "not
// reported by"), the last thing it did, Kai's latest stop in it, and Ask
// about this / Open in Activity.
using Kai.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Kai;

public sealed class NowPage
{
    public UIElement Build(Snapshot0 d)
    {
        var sections = KaiRecords.Sections(d);
        var summary = KaiRecords.Summary(d);
        var body = new List<UIElement> { Banners.All(d) };
        if (!KaiRecords.Recording(d) && d.Status is not null)
            body.Add(Banners.Recording());
        if (sections.Count == 0)
        {
            var connected = KaiRecords.Agents(d).Where(a => a.Connected).Select(a => a.Key).ToList();
            body.Add(Ui.Card(Ui.V(8, Ui.T(NowBuilder.EmptyText(connected), 14),
                                  Ui.T("Earlier sessions are in Activity.", 12, Ui.Muted),
                                  Ui.Link("Settings → Agents", () => App.Me.ShowMain("settings:agents")))));
        }
        foreach (var s in sections)
        {
            body.Add(Ui.H(8, Ui.AgentLogo(s.Agent, 20), Ui.T(s.Line, 14, bold: true, wrap: false)));
            foreach (var c in s.Cards) body.Add(Card(c, d));
            if (AgentReports.Footnote(s.Agent) is { } f) body.Add(Ui.T(char.ToUpperInvariant(f[0]) + f[1..] + ".", 11.5, Ui.Muted));
        }
        var pill = Ui.Pill(summary.Text, summary.Working > 0 ? Ui.Teal : Ui.Muted);
        pill.HorizontalAlignment = HorizontalAlignment.Left;
        body.Insert(0, pill);
        return Ui.Page("Now", "Your agent sessions, across all projects.", body.ToArray());
    }

    static UIElement Card(NowCard c, Snapshot0 d)
    {
        var s = c.Session;
        var where = string.Join(" · ", new[] { c.Project, s.HostApp }.Where(x => x.Length > 0 && x != "—"));
        var state = c.StatePill(d.Now);
        var top = Ui.H(8, Ui.AgentLogo(c.AgentKey, 22), Ui.T(s.DisplayAgent, 13.5, bold: true, wrap: false),
                       Ui.T("· " + where, 13, Ui.Soft, wrap: false), Ui.Pill(state, c.Working ? Ui.Teal : Ui.Muted));
        var v = Ui.V(6, top);
        if (s.Topic.Trim().Length > 0) v.Children.Add(Ui.T("“" + s.Topic.Trim().Split('\n')[0] + "”", 12, Ui.Soft, wrap: false));
        if (c.Started(d.Now) is { Length: > 0 } st) v.Children.Add(Ui.T(st, 11.5, Ui.Muted));
        v.Children.Add(Ui.T(string.Join(" · ", c.Counts.Select(x => x.Text)), 12.5));
        if (c.LastLine(d.Now) is { } last) v.Children.Add(Ui.T(last, 13));
        if (c.LatestStop is { } e)
        {
            var line = Ui.Link(NowCard.StopLine(e) + " · " + LastAction.Ago((d.Now - (e.Date ?? d.Now)).TotalSeconds),
                               () => _ = DecisionDialog.ShowAsync(e, s.Project));
            v.Children.Add(line);
        }
        foreach (var x in c.Children)
            v.Children.Add(Ui.T("↳ " + (x.Kind == "nested" ? "Nested session" : "Background service"), 11.5, Ui.Muted));
        v.Children.Add(Ui.H(10,
            Ui.Ghost("Ask about this", () => App.Me.Main?.AskAbout("What is this session doing?", session: KaiRecords.Focus(c, d))),
            Ui.Ghost("Open →", () => App.Me.Main?.ShowActivity(session: c.Id, agent: c.AgentKey))));
        return Ui.Card(v, c.Working ? Ui.Teal : null);
    }
}

/// The lines at the top of every page that say when something needs you.
public static class Banners
{
    public static UIElement All(Snapshot0 d)
    {
        var p = Ui.V(8);
        foreach (var prob in d.Problems) p.Children.Add(Ui.Card(Ui.T(prob, 12.5, Ui.Amber), Ui.Amber, 10));
        if (Native.Available && Native.Paused)
            p.Children.Add(Ui.Card(Ui.H(10, Ui.T("Kai is paused: soft stops are let through and recorded. Kai's own settings stay protected.", 12.5, Ui.Amber),
                                        Ui.Link("Resume", () => App.Me.Pause(0))), Ui.Amber, 10));
        if (KaiRecords.Internet(d) == AskInternet.Stopped)
        {
            var why = d.Status?.NetworkProblem is { Length: > 0 } w ? w : "Kai Watch isn't running";
            p.Children.Add(Ui.Card(Ui.H(10, Ui.T("Internet watching stopped: " + why + ".", 12.5, Ui.Amber),
                                        Ui.Primary("Restart", async () => Toast.Say(await App.Me.RestartWatchingAsync()))), Ui.Amber, 10));
        }
        foreach (var a in KaiRecords.Agents(d).Where(a => a.Untrusted))
            p.Children.Add(Ui.Card(Ui.T("Codex runs Kai's checks only after you trust them once: open Codex, run /hooks, and trust Kai's entries.", 12.5, Ui.Amber), Ui.Amber, 10));
        if (d.Status is { PolicyOk: false } s)
            p.Children.Add(Ui.Card(Ui.T("Kai's policy has an error: " + s.PolicyError, 12.5, Ui.Red), Ui.Red, 10));
        return p;
    }

    public static UIElement Recording() =>
        Ui.Card(Ui.H(10, Ui.T("Recording is off: Kai keeps only stops.", 12.5),
                     Ui.Link("Turn on", async () => Toast.Say(await App.Me.SetSwitchAsync("record_activity", "on", "turn activity recording on") ?? "Activity recording is on."))), null, 10);
}

/// A short message at the bottom of the window.
public static class Toast
{
    public static void Say(string text)
    {
        var w = App.Me.Main;
        if (w?.Root is null) return;
        var tip = new TeachingTip { Title = text, IsLightDismissEnabled = true, PreferredPlacement = TeachingTipPlacementMode.Bottom };
        if (w.Content is Panel p)
        {
            p.Children.Add(tip);
            tip.Closed += (_, _) => p.Children.Remove(tip);
        }
        tip.IsOpen = true;
    }
}
