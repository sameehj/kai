// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Ask Kai (AskKai.swift): chats on the left, the conversation, the question
// field and the model chip. Answers come from AskEngine (records only). The
// template answer shows at once; a local model's rewording replaces it only
// if it keeps every number. Limits and "Based on" are Kai's own footer, never
// the model's text. Buttons come from the answer's actions, never from text.
using Kai.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Kai;

public sealed class AskPage
{
    readonly ChatStore _store = new();
    List<ChatThread> _threads;
    string? _current;
    bool _thinking;
    string? _modelStatus;
    readonly HashSet<string> _warm = new();
    public ActivityItem? Focus { get; set; }
    public SessionFocus? Session { get; set; }
    public static ModelState Model { get; } = new();

    public AskPage() => _threads = _store.Load();

    ChatThread? Current => _threads.FirstOrDefault(t => t.Id == _current);

    public UIElement Build(Snapshot0 d)
    {
        var grid = new Grid { ColumnSpacing = 0 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());

        var list = Ui.V(4, Ui.Primary("New chat", () => { _current = null; Focus = null; Session = null; Rebuild(); }));
        list.Padding = new Thickness(12, 20, 8, 12);
        foreach (var t in _threads.Take(40))
        {
            var b = new Button { Content = Ui.T(t.Title, 12.5, wrap: false), HorizontalAlignment = HorizontalAlignment.Stretch,
                                 HorizontalContentAlignment = HorizontalAlignment.Left, Background = t.Id == _current ? Ui.Raised : null,
                                 BorderThickness = new Thickness(0) };
            b.Click += (_, _) => { _current = t.Id; Rebuild(); };
            var del = new MenuFlyout();
            var di = new MenuFlyoutItem { Text = "Delete chat" };
            di.Click += (_, _) => { _store.Delete(t); _threads.Remove(t); if (_current == t.Id) _current = null; Rebuild(); };
            del.Items.Add(di);
            b.ContextFlyout = del;
            list.Children.Add(b);
        }
        list.Children.Add(Ui.T($"Chats stay on this computer for {ChatStore.KeepDays} days.", 11, Ui.Muted));
        grid.Children.Add(Ui.Scroll(list));

        var main = new Grid { Padding = new Thickness(24, 20, 24, 16), RowSpacing = 10 };
        main.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        main.RowDefinitions.Add(new RowDefinition());
        main.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var header = Ui.H(10, Ui.Title("Ask Kai"), Model.Chip());
        main.Children.Add(header);

        var conv = Ui.V(12);
        var cur = Current;
        if (cur is null || cur.Messages.Count == 0)
        {
            conv.Children.Add(Ui.T("Ask about what your agents did. Answers come from Kai's own records on this computer.", 13, Ui.Muted));
            var chips = Ui.V(6);
            foreach (var q in AskEngine.SuggestionsList) chips.Children.Add(Ui.Ghost(q, () => _ = SendAsync(q)));
            conv.Children.Add(chips);
        }
        else foreach (var m in cur.Messages) conv.Children.Add(Bubble(m));
        if (_thinking) conv.Children.Add(Ui.T(_modelStatus ?? "Kai is looking at its records…", 12, Ui.Muted));
        var sv = Ui.Scroll(conv);
        Grid.SetRow(sv, 1);
        main.Children.Add(sv);
        sv.Loaded += (_, _) => sv.ChangeView(null, sv.ScrollableHeight, null, true);

        var box = new TextBox { PlaceholderText = Focus is not null ? $"Ask about “{Focus.Title}”…" : Session is not null ? $"Ask about {Session.AgentTitle} in {Session.Project}…" : "Ask Kai…" };
        box.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter && box.Text.Trim().Length > 0) { var q = box.Text; box.Text = ""; _ = SendAsync(q); } };
        var send = Ui.Primary("Ask", () => { if (box.Text.Trim().Length > 0) { var q = box.Text; box.Text = ""; _ = SendAsync(q); } });
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(box);
        Grid.SetColumn(send, 1);
        row.Children.Add(send);
        var bottom = Ui.V(4, row);
        if (Focus is not null || Session is not null)
            bottom.Children.Add(Ui.Link("Clear: " + (Focus?.Title ?? $"{Session!.AgentTitle} · {Session.Project}") + " ×", () => { Focus = null; Session = null; Rebuild(); }));
        Grid.SetRow(bottom, 2);
        main.Children.Add(bottom);
        Grid.SetColumn(main, 1);
        grid.Children.Add(main);
        box.Loaded += (_, _) => box.Focus(FocusState.Programmatic);
        return grid;
    }

    static void Rebuild() => App.Me.Main?.Go("ask");

    UIElement Bubble(ChatMessage m)
    {
        if (m.Role == "user")
        {
            var u = Ui.Card(Ui.T(m.Text, 13), null, 10);
            u.HorizontalAlignment = HorizontalAlignment.Right;
            u.Background = Ui.Raised;
            u.MaxWidth = 560;
            return u;
        }
        var v = Ui.V(6, Ui.T(m.Text, 13.5));
        foreach (var f in m.Footer) v.Children.Add(Ui.T(f, 11.5, Ui.Muted));
        if (m.Actions.Count > 0)
        {
            var acts = Ui.H(8);
            foreach (var a in m.Actions) acts.Children.Add(Ui.Ghost(a.Title, () => _ = PerformAsync(a)));
            v.Children.Add(acts);
        }
        if (m.Suggestions is { Count: > 0 } sug)
        {
            var chips = Ui.H(6);
            foreach (var q in sug) chips.Children.Add(Ui.Link(q, () => _ = SendAsync(q)));
            v.Children.Add(chips);
        }
        var card = Ui.Card(v, null, 12);
        card.MaxWidth = 680;
        card.HorizontalAlignment = HorizontalAlignment.Left;
        return card;
    }

    public async Task SendAsync(string question)
    {
        var q = question.Trim();
        if (q.Length == 0) return;
        var t = Current ?? new ChatThread { Title = q.Length > 48 ? q[..48] : q };
        if (Session is not null && !t.Title.StartsWith("About ", StringComparison.Ordinal)) t.Title = $"About {Session.AgentTitle} · {Session.Project}";
        t.Messages.Add(new ChatMessage { Role = "user", Text = q });
        Upsert(t);
        _thinking = true;
        Rebuild();
        var d = App.Me.Records.Data;
        var ctx = KaiRecords.AskContext(d, Focus, Session);
        foreach (var s in ctx.Stops.Take(3).Where(s => s.DecisionId is not null))
        {
            var r = await KaiCli.RunAsync("why", s.DecisionId!, "--json");
            if (r.Ok && WhyRecord.Parse(r.Out) is { } w) ctx.Why[s.DecisionId!] = w;
        }
        var phraser = Model.Phraser();
        bool modelOn = phraser.Kind != PhraserKind.Templates && phraser.IsAvailable;
        var intent = AskEngine.Route(q);
        // Model routing: only an unmatched question, only its text, only a label from the fixed list.
        if (intent.Kind == AskIntentKind.Unknown && Focus is null && Session is null && modelOn && _warm.Contains("local"))
        {
            try { intent = PhrasePrompts.IntentFromModel(await phraser.PhraseAsync(PhrasePrompts.Classify(q)), q); }
            catch (Exception e) when (e is InvalidOperationException or IOException) { intent = new(AskIntentKind.Unknown); }
        }
        var a = AskEngine.Answer(q, ctx, intent);
        var msg = new ChatMessage
        {
            Role = "kai", Text = a.Display, BasedOn = a.BasedOn, Actions = a.Actions,
            Suggestions = a.Suggestions.Count > 0 ? a.Suggestions : null, Limits = a.Limits.Count > 0 ? a.Limits.Select(AskAnswer.Untag).ToList() : null,
        };
        t.Messages.Add(msg);
        t.Updated = DateTimeOffset.Now;
        Upsert(t);
        Focus = null;
        Session = null;
        if (!modelOn || a.Intent.Kind is AskIntentKind.OutOfScope or AskIntentKind.Unknown)
        {
            _thinking = false;
            Rebuild();
            return;
        }
        _modelStatus = _warm.Contains("local") ? "Wording the answer…" : "Loading model…";
        Rebuild();
        string? reworded = null;
        try { reworded = await phraser.PhraseAsync(PhrasePrompts.Make(q, a.Text)); }
        catch (Exception e) when (e is InvalidOperationException or IOException or OperationCanceledException)
        {
            reworded = null;   // the template answer stands
        }
        _warm.Add("local");
        _thinking = false;
        _modelStatus = null;
        if (reworded is not null && Phrasers.Accept(reworded, a.Display) is { } ok)
        {
            msg.Text = ok;
            msg.PhrasedBy = "Qwen3.5 0.8B on this computer";
            _store.Save(t);
        }
        Rebuild();
    }

    void Upsert(ChatThread t)
    {
        var i = _threads.FindIndex(x => x.Id == t.Id);
        if (i >= 0) _threads[i] = t; else _threads.Insert(0, t);
        _current = t.Id;
        _store.Save(t);
    }

    /// An answer's button: the action it names, nothing else, only on a click.
    static async Task PerformAsync(AskAction a)
    {
        var w = App.Me.Main;
        switch (a.Kind)
        {
            case AskActionKind.OpenDecision:
                var e = App.Me.Records.Data.Events.FirstOrDefault(x => x.DecisionId == a.Ref || x.Id == a.Ref);
                if (e is not null) await DecisionDialog.ShowAsync(e, null);
                break;
            case AskActionKind.OpenActivity:
                if (a.Ref.StartsWith("session:", StringComparison.Ordinal)) w?.ShowActivity(session: a.Ref[8..]);
                else w?.ShowActivity(filter: a.Ref switch
                {
                    "stops" => TimelineFilter.Stops, "files" => TimelineFilter.Files, "connections" => TimelineFilter.Connections, _ => TimelineFilter.All,
                });
                break;
            case AskActionKind.Reconnect:
                var r = await App.Me.SetAgentAsync(a.Ref, true);
                Toast.Say(r.Ok ? $"{Names.Agent(a.Ref)} is connected." : "Kai couldn't connect it: " + r.Message);
                break;
            case AskActionKind.TurnOnRecording:
                Toast.Say(await App.Me.SetSwitchAsync("record_activity", "on", "turn activity recording on") ?? "Activity recording is on. From now on Kai keeps a list of reads, edits and commands.");
                break;
            case AskActionKind.RestartWatching:
                Toast.Say(await App.Me.RestartWatchingAsync());
                break;
            case AskActionKind.OpenInternet:
                w?.Go("settings:internet");
                break;
            case AskActionKind.OpenSettings:
                w?.Go("settings:" + a.Ref);
                break;
        }
    }
}

/// The model chip's state, shared by Ask and Settings → Ask Kai model.
public sealed class ModelState
{
    public ModelStore Store { get; } = new();
    public ModelChip.State State { get; private set; }
    CancellationTokenSource? _dl;
    LlamaPhraser? _llama;

    public ModelState()
    {
        var installed = Store.IsInstalled(ModelStore.Default);
        State = ModelChip.For(Chosen, installed, null);
    }

    PhraserKind Chosen => App.Me.Settings.AskModel == "local" ? PhraserKind.Local : PhraserKind.Templates;

    public IAskPhraser Phraser()
    {
        if (State is ModelChip.State.Active { Kind: PhraserKind.Local } && Store.InstalledPath(ModelStore.Default) is { } path)
            return _llama ??= new LlamaPhraser(path);
        return new TemplatePhraser();
    }

    void Set(ModelChip.State s)
    {
        State = s;
        App.Me.Settings.AskModel = s is ModelChip.State.Active { Kind: PhraserKind.Local } ? "local" : "templates";
        App.Me.Settings.Save();
        App.Me.UI.TryEnqueue(() => App.Me.Main?.Go(App.Me.Main.CurrentPage));
    }

    public UIElement Chip()
    {
        var b = new DropDownButton { Content = ModelChip.Label(State).TrimEnd('▾', ' '), CornerRadius = new CornerRadius(14) };
        var m = new MenuFlyout();
        var installed = Store.IsInstalled(ModelStore.Default);
        foreach (var o in ModelChip.Options(State, installed))
        {
            var i = new MenuFlyoutItem { Text = $"{o.Title} · {o.Status}" + (o.Size.Length > 0 && !installed ? $" · {o.Size}" : "") };
            if (o.Kind == PhraserKind.Local && !installed && State is not ModelChip.State.Downloading)
            {
                i.Text = $"Download {o.Title} ({o.Size})…";
                i.Click += async (_, _) => await ConsentAndDownloadAsync();
            }
            else i.Click += (_, _) => Set(ModelChip.Reduce(State, new ModelChip.Event.Choose(o.Kind), installed));
            m.Items.Add(i);
        }
        if (installed)
        {
            m.Items.Add(new MenuFlyoutSeparator());
            var del = new MenuFlyoutItem { Text = "Delete the downloaded model" };
            del.Click += (_, _) => { _llama?.Dispose(); _llama = null; Store.Delete(ModelStore.Default); Set(ModelChip.Reduce(State, new ModelChip.Event.Delete(), false)); };
            m.Items.Add(del);
        }
        if (State is ModelChip.State.Downloading)
        {
            var c = new MenuFlyoutItem { Text = "Cancel the download" };
            c.Click += (_, _) => _dl?.Cancel();
            m.Items.Add(c);
        }
        b.Flyout = m;
        ToolTipService.SetToolTip(b, State is ModelChip.State.Failed f ? "The download failed: " + f.Why : "Who words Kai's answers");
        return b;
    }

    public async Task ConsentAndDownloadAsync()
    {
        if (App.Me.Main?.Root is not { } root) return;
        var dlg = new ContentDialog
        {
            XamlRoot = root, Title = ModelChip.FirstRunLine,
            Content = Ui.V(8, Ui.T(ModelChip.ConsentLine, 13),
                           Ui.T($"{ModelStore.Default.Name} · {ModelStore.Default.License} · from huggingface.co/{ModelStore.Default.Repo} at a fixed commit. Saved in {Store.Directory}.", 12, Ui.Muted)),
            PrimaryButtonText = "Download", CloseButtonText = "Not now", DefaultButton = ContentDialogButton.Primary,
        };
        if (await dlg.ShowAsync() != ContentDialogResult.Primary) return;
        Set(ModelChip.Reduce(State, new ModelChip.Event.StartDownload(), false));
        _dl = new CancellationTokenSource();
        var progress = new Progress<double>(p => { if (State is ModelChip.State.Downloading d && (int)(p * 100) != (int)(d.Progress * 100)) Set(ModelChip.Reduce(State, new ModelChip.Event.Progress(p), false)); });
        try
        {
            await Store.DownloadAsync(ModelStore.Default, progress, _dl.Token);
            Set(ModelChip.Settle(ModelChip.Reduce(State, new ModelChip.Event.VerifiedOk(), true)));
            Toast.Say(ModelChip.NowAnswering("Qwen3.5 0.8B"));
        }
        catch (Exception e) when (e is ModelStoreException or HttpRequestException or IOException or OperationCanceledException)
        {
            Set(ModelChip.Reduce(State, new ModelChip.Event.Failed(e is OperationCanceledException ? "cancelled" : e.Message), false));
            Toast.Say(e is OperationCanceledException ? "Download cancelled." : "The download failed: " + e.Message);
        }
    }
}
