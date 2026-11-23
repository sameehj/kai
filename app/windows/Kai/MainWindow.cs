// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// The Kai window: Now, Activity and Ask Kai, with Settings at the bottom
// (MainWindow.swift). Mica behind it, Fluent navigation. Pages are rebuilt
// from KaiRecords on each refresh, so they never disagree.
using Kai.Core;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Kai;

public sealed class MainWindow : Window
{
    readonly NavigationView _nav = new();
    readonly ContentControl _content = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    string _page = "now";
    public NowPage Now { get; } = new();
    public ActivityPage Activity { get; } = new();
    public AskPage Ask { get; } = new();
    public SettingsPage Settings { get; } = new();

    public MainWindow()
    {
        Title = "Kai";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Kai.ico"));
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1100, 760));

        var title = Ui.H(10, Ui.T("Kai", 13, Ui.Purple, bold: true, wrap: false));
        title.Margin = new Thickness(16, 10, 0, 0);
        title.Height = 32;
        SetTitleBar(title);

        foreach (var (tag, text, glyph) in new[] { ("now", "Now", ""), ("activity", "Activity", ""), ("ask", "Ask Kai", "") })
            _nav.MenuItems.Add(new NavigationViewItem { Content = text, Tag = tag, Icon = new FontIcon { Glyph = glyph } });
        _nav.IsSettingsVisible = true;
        _nav.IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed;
        _nav.PaneDisplayMode = NavigationViewPaneDisplayMode.Left;
        _nav.OpenPaneLength = 200;
        _nav.Content = _content;
        _nav.SelectionChanged += (_, e) =>
        {
            var tag = e.IsSettingsSelected ? "settings" : (e.SelectedItem as NavigationViewItem)?.Tag as string ?? "now";
            Show(tag);
        };
        var root = new Grid();
        // Mica where Windows has it; a solid background elsewhere (and in --snapshot, which can't draw Mica)
        if (!Microsoft.UI.Composition.SystemBackdrops.MicaController.IsSupported() || Environment.GetCommandLineArgs().Contains("--snapshot"))
            root.Background = Ui.Ink;
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(40) });
        root.RowDefinitions.Add(new RowDefinition());
        root.Children.Add(title);
        Grid.SetRow(_nav, 1);
        root.Children.Add(_nav);
        Content = root;

        App.Me.Records.Changed += OnChanged;
        Closed += (_, _) => App.Me.Records.Changed -= OnChanged;
        Go("now");
    }

    void OnChanged() => App.Me.UI.TryEnqueue(() => Render());

    public void BringToFront()
    {
        if (AppWindow.Presenter is OverlappedPresenter p && p.State == OverlappedPresenterState.Minimized) p.Restore();
        AppWindow.Show();
    }

    public void Go(string page)
    {
        if (page == "settings") _nav.SelectedItem = _nav.SettingsItem;
        else if (page.StartsWith("settings:", StringComparison.Ordinal))
        {
            Settings.Section = page["settings:".Length..];
            _nav.SelectedItem = _nav.SettingsItem;
        }
        else _nav.SelectedItem = _nav.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(i => (string)i.Tag == page);
        Show(page.StartsWith("settings", StringComparison.Ordinal) ? "settings" : page);
    }

    void Show(string page)
    {
        _page = page;
        Render();
    }

    void Render()
    {
        var d = App.Me.Records.Data;
        try
        {
            _content.Content = _page switch
            {
                "activity" => Activity.Build(d),
                "ask" => Ask.Build(d),
                "settings" => Settings.Build(d),
                _ => Now.Build(d),
            };
        }
        catch (Exception e)
        {
            // never a blank page: say what failed
            App.Log($"page {_page}: {e}");
            _content.Content = Ui.Page(_page, "Kai couldn't draw this page.", Ui.T(e.GetType().Name + ": " + e.Message, 12.5, Ui.Amber));
        }
    }

    public void ShowActivity(string? session = null, string? agent = null, TimelineFilter filter = TimelineFilter.All)
    {
        Activity.SessionFilter = session;
        Activity.AgentFilter = agent;
        Activity.Filter = filter;
        Go("activity");
    }

    public void AskAbout(string question, ActivityItem? focus = null, SessionFocus? session = null)
    {
        Ask.Focus = focus;
        Ask.Session = session;
        Go("ask");
        if (question.Length > 0) _ = Ask.SendAsync(question);
    }

    public async void ShowOnboarding()
    {
        await Task.Delay(300);   // the window's XamlRoot first
        if (Content.XamlRoot is null) return;
        await Onboarding.ShowAsync(this);
    }

    public XamlRoot? Root => Content.XamlRoot;
    public string CurrentPage => _page;
}
