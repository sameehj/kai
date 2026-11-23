// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Activity (NowPage.swift's timeline): today's records in one list grouped
// by session, filtered by kind (All · Files · Commands · Connections · Stops),
// agent or session. Each group's numbers are its Now card's numbers. Every row
// says how Kai knows it: Requested, Seen or Confirmed.
using Kai.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Kai;

public sealed class ActivityPage
{
    public TimelineFilter Filter { get; set; } = TimelineFilter.All;
    public string? AgentFilter { get; set; }
    public string? SessionFilter { get; set; }

    public UIElement Build(Snapshot0 d)
    {
        var groups = KaiRecords.Groups(d)
            .Where(g => SessionFilter is null || g.SessionId == SessionFilter)
            .Where(g => AgentFilter is null || g.Agent == AgentFilter || g.Id == "seen")
            .Select(g => g with { Events = g.Events.Where(e => Filter.Matches(e.Kind) && (AgentFilter is null || e.Agent == AgentFilter)).ToList() })
            .Where(g => g.Events.Count > 0).ToList();

        var filters = Ui.H(6);
        foreach (var f in Enum.GetValues<TimelineFilter>())
        {
            var b = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = f.ToString(), IsChecked = f == Filter, CornerRadius = new CornerRadius(14) };
            b.Click += (_, _) => { Filter = f; App.Me.Main?.Go("activity"); };
            filters.Children.Add(b);
        }
        if (AgentFilter is not null) filters.Children.Add(Ui.Ghost(Names.Agent(AgentFilter) + " ×", () => { AgentFilter = null; App.Me.Main?.Go("activity"); }));
        if (SessionFilter is not null) filters.Children.Add(Ui.Ghost("This session ×", () => { SessionFilter = null; App.Me.Main?.Go("activity"); }));

        var body = new List<UIElement> { Banners.All(d), filters };
        if (!KaiRecords.Recording(d) && d.Status is not null) body.Add(Banners.Recording());
        if (KaiRecords.Internet(d) == AskInternet.Off && Filter == TimelineFilter.Connections)
            body.Add(Ui.T("Connections appear when Internet watching is on (Settings → Internet).", 12.5, Ui.Muted));
        if (groups.Count == 0)
            body.Add(Ui.Card(Ui.T(!KaiRecords.Recording(d) ? "Recording is off, so Kai keeps only its stops, and none matches."
                                  : Filter == TimelineFilter.All && AgentFilter is null && SessionFilter is null ? "No agent activity today."
                                  : "Nothing Kai recorded today matches these filters.", 13)));
        foreach (var g in groups) body.Add(Group(g, d));
        return Ui.Page("Activity", "What Kai recorded today, across all projects.", body.ToArray());
    }

    static UIElement Group(TimelineGroup g, Snapshot0 d)
    {
        var head = Ui.H(8);
        if (g.Agent.Length > 0) head.Children.Add(Ui.AgentLogo(g.Agent, 18));
        head.Children.Add(Ui.T(g.Header, 13.5, bold: true, wrap: false));
        var v = Ui.V(4, head);
        if (g.SessionId is not null) v.Children.Add(Ui.T(string.Join(" · ", g.Counts.Select(c => c.Text)), 12, Ui.Muted));
        foreach (var e in g.Events.Take(60)) v.Children.Add(Row(e, g, d));
        if (g.Events.Count > 60) v.Children.Add(Ui.T($"+ {g.Events.Count - 60} older in this group", 11.5, Ui.Muted));
        return Ui.Card(v);
    }

    static UIElement Row(TimelineEvent e, TimelineGroup g, Snapshot0 d)
    {
        var clock = DateTimeOffset.FromUnixTimeSeconds((long)e.Ts).ToLocalTime().ToString("HH:mm");
        var color = e.Kind == TimelineKind.Stop ? Ui.Amber : e.Evidence == Evidence.Seen ? Ui.Teal : Ui.Muted;
        var grid = new Grid { ColumnSpacing = 10, Padding = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var when = Ui.T(clock, 12, Ui.Muted, wrap: false);
        var title = Ui.V(0, Ui.T(e.Title, 13, wrap: false));
        if (e.Object.Length > 0 && !e.Title.Contains(Paths.Last(e.Object), StringComparison.Ordinal))
            title.Children.Add(Ui.T(e.Object, 11.5, Ui.Muted, wrap: false));
        var tag = Ui.H(6, Ui.Pill(e.Outcome, color));
        if (EvidenceWords.Label(e.Evidence) != e.Outcome) tag.Children.Add(Ui.T(EvidenceWords.Label(e.Evidence), 11, Ui.Muted, wrap: false));
        Grid.SetColumn(title, 1);
        Grid.SetColumn(tag, 2);
        grid.Children.Add(when);
        grid.Children.Add(title);
        grid.Children.Add(tag);
        var b = new Button { Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                             Background = null, BorderThickness = new Thickness(0), Padding = new Thickness(4, 0, 4, 0) };
        b.Click += async (_, _) =>
        {
            var stop = e.StopEventId is null ? null : d.Events.FirstOrDefault(x => x.Id == e.StopEventId);
            if (stop is not null) await DecisionDialog.ShowAsync(stop, g.ProjectPath);
            else await Details(e);
        };
        return b;
    }

    /// One record's evidence: what it was, how Kai knows, what it doesn't show.
    static async Task Details(TimelineEvent e)
    {
        if (App.Me.Main?.Root is not { } root) return;
        var item = new ActivityItem
        {
            Id = e.Id, AgentKey = e.Agent, Agent = Names.Agent(e.Agent), Title = e.Title, Detail = e.Object, Outcome = e.Outcome,
            Evidence = e.Evidence, Source = e.Source, Explanation = e.What, Count = 1, CountText = "1",
            Kind = e.Kind switch { TimelineKind.Connection => ActivityItemKind.Connection, TimelineKind.Command => ActivityItemKind.Command,
                                   TimelineKind.Stop => ActivityItemKind.Stop, TimelineKind.File => ActivityItemKind.Read, _ => ActivityItemKind.Tool },
        };
        var grid = Ui.V(8, Ui.T(e.What, 13),
            Ui.T("Outcome: " + e.Outcome, 12.5, Ui.Soft),
            Ui.T("Evidence: " + EvidenceWords.Label(e.Evidence) + ". " + EvidenceWords.Explain(e.Evidence), 12.5, Ui.Soft),
            Ui.T("Source: " + e.Source, 12.5, Ui.Soft),
            Ui.T("Agent: " + Names.Agent(e.Agent), 12.5, Ui.Soft),
            Ui.T("Time: " + DateTimeOffset.FromUnixTimeSeconds((long)e.Ts).ToLocalTime().ToString("g"), 12.5, Ui.Soft));
        var dlg = new ContentDialog
        {
            XamlRoot = root, Title = e.Title, Content = grid, CloseButtonText = "Done", PrimaryButtonText = "Ask about this →",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dlg.ShowAsync() == ContentDialogResult.Primary) App.Me.Main?.AskAbout("Tell me about this", focus: item);
    }
}
