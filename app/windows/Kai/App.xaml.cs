// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Kai.exe: one instance per user, a tray icon with a flyout, the main window
// (Now, Activity, Ask Kai, Settings), first-run onboarding. Every number
// comes from kai.exe and the audit log through KaiRecords; every change goes
// through kai.exe, Kai Watch's pipe, or (pause, a confirmed held change) the
// same libkai calls the macOS app makes. Works with no agent installed.
using System.Windows.Input;
using H.NotifyIcon;
using Kai.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Kai;

public partial class App : Application
{
    public static App Me { get; private set; } = null!;
    public KaiRecords Records { get; } = new();
    public AppSettings Settings { get; } = AppSettings.Load();
    public DispatcherQueue UI { get; private set; } = null!;
    public MainWindow? Main { get; private set; }
    FlyoutWindow? _flyout;
    TaskbarIcon? _tray;
    DispatcherQueueTimer? _timer;
    static Mutex? _single;
    static EventWaitHandle? _show;
    bool _connecting;

    public App()
    {
        Me = this;
        // One Kai per user: a second start asks the first to show its window.
        bool snapshot = Environment.GetCommandLineArgs().Contains("--snapshot");   // read-only: may run beside Kai
        _single = new Mutex(true, snapshot ? @"Local\Kai.App.Snapshot" + Environment.ProcessId : @"Local\Kai.App", out bool first);
        _show = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Kai.App.Show");
        if (!first)
        {
            _show.Set();
            Environment.Exit(0);
        }
        InitializeComponent();
        UnhandledException += (_, e) => { Log("unhandled: " + e.Exception); e.Handled = true; };
    }

    /// %LOCALAPPDATA%\Kai\app.log: errors only, never records or paths from them.
    public static void Log(string text)
    {
        var p = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Kai", "app.log");
        Directory.CreateDirectory(Path.GetDirectoryName(p)!);
        File.AppendAllText(p, $"{DateTimeOffset.Now:u} {text}\n");
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        UI = DispatcherQueue.GetForCurrentThread();
        var argv = Environment.GetCommandLineArgs();
        int si = Array.IndexOf(argv, "--snapshot");
        if (si > 0 && si + 1 < argv.Length) { _ = Snapshot.RunAsync(argv[si + 1]); return; }
        bool background = argv.Contains("--background");
        CreateTray();
        new Thread(() => { while (_show!.WaitOne()) UI.TryEnqueue(() => ShowMain()); }) { IsBackground = true }.Start();
        Records.Changed += () => UI.TryEnqueue(UpdateTray);
        _timer = UI.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(5);
        _timer.Tick += async (_, _) => await RefreshAsync();
        _timer.Start();
        _ = StartAsync(background);
    }

    async Task StartAsync(bool background)
    {
        await RefreshAsync();
        await AutoConnectAsync();
        if (!Settings.OnboardingDone) ShowMain(onboarding: true);
        else if (!background) ShowMain();
    }

    public async Task RefreshAsync()
    {
        try { await Records.RefreshAsync(); }
        catch (Exception e) when (e is IOException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            Records.Load(Records.Data with { Problems = new() { "Kai couldn't read its records: " + e.Message } });
        }
    }

    // ---------------------------------------------------------- windows

    public void ShowMain(string? page = null, bool onboarding = false)
    {
        _flyout?.Hide();
        if (Main is null)
        {
            Main = new MainWindow();
            Main.Closed += (_, _) => Main = null;
        }
        Main.Activate();
        Main.BringToFront();
        if (page is not null) Main.Go(page);
        if (onboarding) Main.ShowOnboarding();
    }

    public void ToggleFlyout()
    {
        _flyout ??= new FlyoutWindow();
        if (_flyout.IsShown) _flyout.Hide(); else _flyout.ShowNearTray();
    }

    public void Quit()
    {
        _tray?.Dispose();
        Main?.Close();
        _flyout?.Close();
        Exit();
    }

    // ------------------------------------------------------------- tray

    sealed class Command(Action a) : ICommand
    {
        public event EventHandler? CanExecuteChanged { add { } remove { } }
        public bool CanExecute(object? p) => true;
        public void Execute(object? p) => a();
    }

    static bool LightTaskbar()
    {
        using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return k?.GetValue("SystemUsesLightTheme") is int v && v == 1;
    }

    static System.Drawing.Icon TrayIcon(bool paused) =>
        new(Path.Combine(AppContext.BaseDirectory, "Assets", $"tray-{(paused ? "off-" : "")}{(LightTaskbar() ? "dark" : "light")}.ico"));

    void CreateTray()
    {
        var menu = new MenuFlyout();
        void Item(string text, Action a) { var i = new MenuFlyoutItem { Text = text }; i.Click += (_, _) => a(); menu.Items.Add(i); }
        Item("Open Kai", () => ShowMain());
        Item("Ask Kai", () => ShowMain("ask"));
        menu.Items.Add(new MenuFlyoutSeparator());
        Item("Pause checks for 15 minutes", () => Pause(15));
        Item("Pause checks for 1 hour", () => Pause(60));
        Item("Resume", () => Pause(0));
        menu.Items.Add(new MenuFlyoutSeparator());
        Item("Settings", () => ShowMain("settings"));
        Item("Quit Kai", Quit);
        _tray = new TaskbarIcon
        {
            ToolTipText = "Kai", Icon = TrayIcon(false), NoLeftClickDelay = true,
            LeftClickCommand = new Command(ToggleFlyout), ContextMenuMode = ContextMenuMode.SecondWindow, ContextFlyout = menu,
        };
        _tray.ForceCreate(false);
    }

    bool _trayPaused;

    void UpdateTray()
    {
        if (_tray is null) return;
        var d = Records.Data;
        bool paused = Native.Available && Native.Paused;
        if (paused != _trayPaused) { _tray.UpdateIcon(TrayIcon(paused)); _trayPaused = paused; }
        var head = paused ? "Kai · paused" : "Kai · " + KaiRecords.Summary(d).Text;
        if (KaiRecords.Internet(d) == AskInternet.Stopped) head += " · Internet watching stopped";
        _tray.ToolTipText = head;
    }

    // ---------------------------------------------------------- actions

    public void Pause(int minutes)
    {
        if (!Native.Available) return;
        Native.Pause(minutes);
        UpdateTray();
        _ = RefreshAsync();
    }

    /// Connect every detected agent the user hasn't turned off (first run, an
    /// update, a newly installed agent), as the macOS app does.
    public async Task AutoConnectAsync()
    {
        if (_connecting) return;
        _connecting = true;
        try
        {
            var d = Records.Data;
            foreach (var a in d.Sessions?.Agents ?? new())
            {
                if (!a.Detected || a.Hooks == "installed" || a.Hooks == "untrusted") continue;
                if (a.Name is not ("claude" or "cursor" or "codex") || Settings.AgentsOff.Contains(a.Name)) continue;
                await KaiCli.RunAsync("install", a.Name);
            }
            await RefreshAsync();
        }
        finally { _connecting = false; }
    }

    public async Task<CommandResult> SetAgentAsync(string agent, bool on)
    {
        if (on) Settings.AgentsOff.Remove(agent); else Settings.AgentsOff.Add(agent);
        Settings.Save();
        var r = await KaiCli.RunAsync(on ? "install" : "uninstall", agent);
        await RefreshAsync();
        return r;
    }

    /// A kai policy change; one that turns protection down is held by kai.exe
    /// and applied only after the owner confirms here.
    public async Task<string?> SetSwitchAsync(string key, string value, string reason)
    {
        var before = PendingPolicyStore.Load().Select(p => p.Id).ToHashSet();
        var r = await KaiCli.RunAsync("policy", "set", key, value);
        if (!r.Ok) return r.Message;
        // only the change this call made; anything else waiting stays held
        foreach (var c in PendingPolicyStore.Load().Where(p => !before.Contains(p.Id) && p.Summary.StartsWith($"set {key} ", StringComparison.Ordinal)))
        {
            if (Main is not null && await OwnerAuth.ConfirmAsync(Main, "Turn protection down: " + reason))
                PendingPolicyStore.Apply(c);
            else
            {
                PendingPolicyStore.Reject(c);
                await RefreshAsync();
                return "Not changed: you didn't confirm.";
            }
        }
        await RefreshAsync();
        var after = KaiRecords.Recording(Records.Data);
        return key == "record_activity" && after != (value == "on") ? "the setting still reads differently after the change" : null;
    }

    /// Kai Watch: start again after it stopped (the "Restart" button).
    public async Task<string> RestartWatchingAsync()
    {
        var r = await WatchPipe.AskAsync("start");
        await RefreshAsync();
        if (r is null) return "Kai Watch isn't running. Reinstall Kai to put its service back.";
        var o = J.Parse(r);
        return J.B(o, "ok") ? "Internet watching is on again." : "Kai Watch couldn't restart watching: " + J.S(o, "error", J.S(o, "message"));
    }
}

/// The app's own preferences (%LOCALAPPDATA%\Kai\app.json): onboarding seen,
/// agents the user turned off, the Ask Kai model choice.
public sealed class AppSettings
{
    public bool OnboardingDone { get; set; }
    public HashSet<string> AgentsOff { get; set; } = new();
    public string AskModel { get; set; } = "";

    static string File_ => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Kai", "app.json");

    public static AppSettings Load()
    {
        if (!File.Exists(File_)) return new AppSettings();
        try { return System.Text.Json.JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(File_)) ?? new AppSettings(); }
        catch (System.Text.Json.JsonException) { return new AppSettings(); }   // a damaged file: start from the defaults
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(File_)!);
        File.WriteAllText(File_, System.Text.Json.JsonSerializer.Serialize(this));
    }
}
