// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// The tray flyout (MenuView.swift's popover): "Kai · N working", today's
// numbers, the sessions, the latest stop, Ask, Open Kai, Pause, Settings.
// Every number is the Now page's (KaiRecords). It hides when it loses focus.
using Kai.Core;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Kai;

public sealed class FlyoutWindow : Window
{
    public bool IsShown { get; private set; }
    string? _note;   // the result of the last action taken here
    const int W = 360, H = 520;

    public FlyoutWindow()
    {
        SystemBackdrop = new DesktopAcrylicBackdrop();
        if (AppWindow.Presenter is OverlappedPresenter p)
        {
            p.IsResizable = false; p.IsMaximizable = false; p.IsMinimizable = false; p.IsAlwaysOnTop = true;
            p.SetBorderAndTitleBar(true, false);
        }
        AppWindow.IsShownInSwitchers = false;
        Activated += (_, e) => { if (e.WindowActivationState == WindowActivationState.Deactivated) Hide(); };
        App.Me.Records.Changed += () => App.Me.UI.TryEnqueue(() => { if (IsShown) Render(); });
    }

    public void ShowNearTray()
    {
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var scale = (Content?.XamlRoot?.RasterizationScale) ?? 1.0;
        int w = (int)(W * scale), h = (int)(H * scale);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + area.Width - w - 12, area.Y + area.Height - h - 12, w, h));
        Render();
        AppWindow.Show();
        Activate();
        IsShown = true;
        _ = App.Me.RefreshAsync();
    }

    public void Hide()
    {
        AppWindow.Hide();
        IsShown = false;
    }

    void Render()
    {
        var d = App.Me.Records.Data;
        var paused = Native.Available && Native.Paused;
        var internet = KaiRecords.Internet(d);
        var off = d.Status is null || KaiRecords.Agents(d).All(a => !a.Connected);
        var dot = off ? Ui.Red : paused || internet == AskInternet.Stopped || d.Problems.Count > 0 ? Ui.Amber : Ui.Teal;
        var summary = KaiRecords.Summary(d);
        var v = Ui.V(10);
        v.Padding = new Thickness(16);
        v.Children.Add(Ui.H(8, Ui.Dot(dot, 10), Ui.T("Kai · " + (paused ? "paused" : summary.Text), 14, bold: true, wrap: false)));
        if (off) v.Children.Add(Ui.T(d.Status is null ? "Kai can't read its status right now." : "Kai is off: no agent is connected to its checks.", 12.5, Ui.Red));
        if (internet == AskInternet.Stopped)
            v.Children.Add(Ui.H(8, Ui.T("Internet watching stopped", 12.5, Ui.Amber),
                                Ui.Link("Restart", async () => { _note = await App.Me.RestartWatchingAsync(); Render(); })));
        if (_note is not null) v.Children.Add(Ui.T(_note, 12, Ui.Muted));
        var (sessions, stops, conns) = KaiRecords.Today(d);
        var today = $"Today: {Names.N(stops, "stop")}" + (internet != AskInternet.Off ? $" · {Names.N(conns, "connection")} seen" : "")
                    + $" · {Names.N(sessions, "session")}";
        v.Children.Add(Ui.T(today, 12, Ui.Muted));

        var cards = KaiRecords.Sections(d).SelectMany(s => s.Cards).ToList();
        foreach (var c in cards.Take(3))
        {
            var row = Ui.V(2, Ui.H(6, Ui.AgentLogo(c.AgentKey, 16), Ui.T($"{c.Session.DisplayAgent} · {c.Project}", 12.5, wrap: false),
                                   Ui.Pill(c.StatePill(d.Now), c.Working ? Ui.Teal : Ui.Muted)));
            if (c.LastLine(d.Now) is { } l) row.Children.Add(Ui.T(l, 11.5, Ui.Muted, wrap: false));
            v.Children.Add(Ui.Card(row, null, 8));
        }
        if (cards.Count > 3) v.Children.Add(Ui.T($"+ {cards.Count - 3} more in Now", 11, Ui.Muted));
        if (cards.Count == 0) v.Children.Add(Ui.T("No session running.", 12, Ui.Muted));

        if (KaiRecords.LatestStop(d) is { } e)
            v.Children.Add(Ui.Link("Latest stop: " + Copy.Sentence(e), () => { App.Me.ShowMain(); _ = DecisionDialog.ShowAsync(e, null); }));

        var ask = new TextBox { PlaceholderText = "Ask Kai…" };
        ask.KeyDown += (_, k) =>
        {
            if (k.Key != Windows.System.VirtualKey.Enter || ask.Text.Trim().Length == 0) return;
            var q = ask.Text;
            ask.Text = "";
            App.Me.ShowMain();
            App.Me.Main?.AskAbout(q);
        };
        v.Children.Add(ask);
        var open = Ui.Primary("Open Kai", () => App.Me.ShowMain());
        open.HorizontalAlignment = HorizontalAlignment.Stretch;
        v.Children.Add(open);
        var pauseMenu = new MenuFlyout();
        foreach (var (t, m) in new[] { ("15 minutes", 15), ("1 hour", 60) })
        {
            var i = new MenuFlyoutItem { Text = "Pause checks for " + t };
            i.Click += (_, _) => App.Me.Pause(m);
            pauseMenu.Items.Add(i);
        }
        UIElement pause = paused ? Ui.Ghost("Resume", () => App.Me.Pause(0))
                                 : new DropDownButton { Content = "Pause", Flyout = pauseMenu, CornerRadius = new CornerRadius(8) };
        v.Children.Add(Ui.H(8, pause, Ui.Ghost("Settings", () => App.Me.ShowMain("settings")), Ui.Ghost("Quit", App.Me.Quit)));
        Content = new Border { Child = Ui.Scroll(v), Background = Environment.GetCommandLineArgs().Contains("--snapshot") ? Ui.Ink : new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
    }


}
