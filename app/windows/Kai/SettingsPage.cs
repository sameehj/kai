// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Settings (SettingsView.swift, adapted): Agents (one switch per agent,
// health, Repair, the Codex /hooks step), Internet (Off or Watch, Kai Watch's
// real state, Restart, the protected-file watch), Ask Kai model, Advanced
// (Start with Windows, activity recording, pause, the policy file, the audit
// log, the version). Every change goes through kai.exe or Kai Watch's pipe;
// one that turns protection down asks the owner first.
using Kai.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Kai;

public sealed class SettingsPage
{
    public string Section { get; set; } = "agents";

    public UIElement Build(Snapshot0 d)
    {
        var tabs = new SelectorBar();
        foreach (var (tag, text) in new[] { ("agents", "Agents"), ("internet", "Internet"), ("model", "Ask Kai model"), ("advanced", "Advanced") })
        {
            var i = new SelectorBarItem { Text = text, Tag = tag, IsSelected = tag == Section };
            tabs.Items.Add(i);
        }
        // the bar reports a selection when it first appears too: redraw only on a real switch
        tabs.SelectionChanged += (s, _) =>
        {
            if (s.SelectedItem?.Tag is not string tag || tag == Section) return;
            Section = tag;
            App.Me.Main?.Go("settings");
        };
        UIElement body = Section switch
        {
            "internet" => Internet(d),
            "model" => Model(),
            "advanced" => Advanced(d),
            _ => Agents(d),
        };
        return Ui.Page("Settings", "Kai's settings live in your Kai folder; changes go through kai.exe.", Banners.All(d), tabs, body);
    }

    // -------------------------------------------------------------- Agents

    static UIElement Agents(Snapshot0 d)
    {
        var v = Ui.V(10, Ui.T("Kai connects every agent it finds, and leaves alone the ones you turn off.", 12.5, Ui.Muted));
        foreach (var key in new[] { "claude", "cursor", "codex" })
        {
            var st = d.Status?.Agents.GetValueOrDefault(key);
            var row = d.Sessions?.Agents.FirstOrDefault(a => a.Name == key);
            bool detected = (row?.Detected ?? false) || (st?.Detected ?? false);
            bool on = st?.Installed ?? false;
            string state = !detected && !on ? "Not found on this computer"
                         : !on ? "Not connected"
                         : st!.Working == false ? "Not working: " + (st.Problem is { Length: > 0 } p ? p : "its hook didn't answer")
                         : key == "codex" && st.LastHook == 0 ? "Connected · not checked until you trust it in Codex (/hooks)"
                         : "Connected";
            var color = state == "Connected" ? Ui.Teal : !on ? Ui.Muted : Ui.Amber;
            var toggle = new ToggleSwitch { IsOn = on, IsEnabled = detected || on, OnContent = "On", OffContent = "Off" };
            toggle.Toggled += async (_, _) =>
            {
                var r = await App.Me.SetAgentAsync(key, toggle.IsOn);
                if (!r.Ok) Toast.Say("Kai couldn't change it: " + r.Message);
            };
            var info = Ui.V(2, Ui.H(8, Ui.AgentLogo(key, 22), Ui.T(Names.Agent(key), 14, bold: true, wrap: false)),
                            Ui.H(6, Ui.Dot(color), Ui.T(state, 12.5, color)),
                            Ui.T(AgentReports.Coverage(key), 12, Ui.Muted));
            if (key == "codex" && on) info.Children.Add(Ui.T("Codex runs Kai's checks only after you trust them: open Codex, run /hooks, and trust Kai's entries (again after each reinstall).", 12, Ui.Muted));
            var right = Ui.H(8, toggle);
            if (on && st!.Working == false) right.Children.Insert(0, Ui.Primary("Repair", async () =>
            {
                var r = await KaiCli.RunAsync("install", key);
                await App.Me.RefreshAsync();
                Toast.Say(r.Ok ? $"{Names.Agent(key)} is connected again." : "Repair didn't work: " + r.Message);
            }));
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.Children.Add(info);
            Grid.SetColumn(right, 1);
            right.VerticalAlignment = VerticalAlignment.Center;
            g.Children.Add(right);
            v.Children.Add(Ui.Card(g));
        }
        return v;
    }

    // ------------------------------------------------------------ Internet

    static UIElement Internet(Snapshot0 d)
    {
        var configured = d.Status?.NetworkConfigured ?? "off";
        var state = KaiRecords.Internet(d);
        var mode = new RadioButtons { Header = "Internet" };
        mode.Items.Add("Off");
        mode.Items.Add("Watch: list the hosts agents connect to");
        mode.SelectedIndex = configured == "off" ? 0 : 1;
        mode.SelectionChanged += async (_, _) =>
        {
            var want = mode.SelectedIndex == 0 ? "off" : "watch";
            if ((want == "off") == (configured == "off")) return;
            if (want == "off" && App.Me.Main is { } w && !await OwnerAuth.ConfirmAsync(w, "Turn Internet watching off"))
            {
                App.Me.Main?.Go("settings");
                return;
            }
            var before = PendingPolicyStore.Load().Select(c => c.Id).ToHashSet();
            var r = await WatchPipe.AskAsync("mode " + want);
            string msg;
            if (r is null)
                msg = await App.Me.SetSwitchAsync("egress", want == "off" ? "off" : "log", "turn Internet watching off")
                      ?? (want == "off" ? "Internet watching is off." : "Internet watching is on; Kai Watch isn't running, so nothing is watched yet.");
            else
            {
                var o = J.Parse(r);
                // Turning watching off is held by kai.exe; the owner confirmed it
                // above. Only the change this click made is applied: anything
                // else waiting (from an agent, say) stays held.
                foreach (var c in PendingPolicyStore.Load().Where(c => !before.Contains(c.Id) && c.Summary.StartsWith("set egress ", StringComparison.Ordinal)))
                    PendingPolicyStore.Apply(c);
                msg = J.B(o, "ok") ? (want == "off" ? "Internet watching is off." : "Internet watching is on.") : "Kai couldn't change it: " + J.S(o, "error");
            }
            await App.Me.RefreshAsync();
            Toast.Say(msg);
        };
        var stateLine = state switch
        {
            AskInternet.On => Ui.H(6, Ui.Dot(Ui.Teal), Ui.T("Watching. Kai Watch lists the hosts agents connect to; it doesn't read traffic or block anything.", 12.5)),
            AskInternet.Stopped => Ui.H(8, Ui.Dot(Ui.Amber), Ui.T("Internet watching stopped: " + (d.Status?.NetworkProblem is { Length: > 0 } p ? p : "Kai Watch isn't running") + ".", 12.5, Ui.Amber),
                                       Ui.Primary("Restart", async () => Toast.Say(await App.Me.RestartWatchingAsync()))),
            _ => Ui.H(6, Ui.Dot(Ui.Muted), Ui.T("Off: Kai keeps no list of destinations.", 12.5, Ui.Muted)),
        };
        var files = new ToggleSwitch
        {
            Header = "Also watch protected files: note when a program an agent runs opens one of your protected files outside its hooks",
            IsOn = d.Policy?.Switches.GetValueOrDefault("watch_files") == "on", OnContent = "On", OffContent = "Off",
        };
        files.Toggled += async (_, _) =>
            Toast.Say(await App.Me.SetSwitchAsync("watch_files", files.IsOn ? "on" : "off", "stop watching protected files")
                      ?? (files.IsOn ? "Kai Watch now notes protected files agents' programs open." : "Protected-file watching is off."));
        return Ui.V(14, Ui.Card(Ui.V(10, mode, stateLine)),
            Ui.Card(Ui.V(8, files, Ui.T("Recorded as Seen. This is watching only: Kai doesn't stop these opens, and can't tell what was read.", 12, Ui.Muted))),
            Ui.T("On Windows, Internet is Watch only: nothing is blocked at the system level. A connection through a proxy on this computer shows as the proxy, not the site.", 12, Ui.Muted));
    }

    // --------------------------------------------------------------- Model

    static UIElement Model()
    {
        var m = AskPage.Model;
        var installed = m.Store.IsInstalled(ModelStore.Default);
        var v = Ui.V(10, Ui.T("Answers always come from Kai's records. A model only rewords them, on this computer, and never adds buttons or changes a setting.", 12.5, Ui.Muted),
                     Ui.H(8, Ui.T("Answers:", 12.5, Ui.Muted), m.Chip()));
        foreach (var o in ModelChip.Options(m.State, installed))
            v.Children.Add(Ui.Card(Ui.V(2, Ui.T(o.Title + (o.Size.Length > 0 ? " · " + o.Size : ""), 13.5, bold: true), Ui.T(o.Detail, 12, Ui.Muted), Ui.T(o.Status, 12, Ui.Soft))));
        if (!installed && m.State is not ModelChip.State.Downloading)
            v.Children.Add(Ui.Primary("Download the local model…", () => _ = m.ConsentAndDownloadAsync()));
        v.Children.Add(Ui.T(ModelChip.ConsentLine, 11.5, Ui.Muted));
        return v;
    }

    // ------------------------------------------------------------ Advanced

    static UIElement Advanced(Snapshot0 d)
    {
        var startup = new ToggleSwitch { Header = "Start Kai with Windows", IsOn = StartWithWindows.IsOn, OnContent = "On", OffContent = "Off" };
        startup.Toggled += (_, _) => StartWithWindows.Set(startup.IsOn, Path.Combine(AppContext.BaseDirectory, "Kai.exe"));
        var rec = new ToggleSwitch { Header = "Keep a list of what agents read, edit and run (on this computer only, no file contents)",
                                     IsOn = KaiRecords.Recording(d), OnContent = "On", OffContent = "Off" };
        rec.Toggled += async (_, _) =>
            Toast.Say(await App.Me.SetSwitchAsync("record_activity", rec.IsOn ? "on" : "off", "stop keeping a list of agent activity")
                      ?? (rec.IsOn ? "Activity recording is on." : "Activity recording is off."));
        var paused = Native.Available && Native.Paused;
        var pause = paused ? Ui.Ghost("Resume checks", () => App.Me.Pause(0))
                           : Ui.Ghost("Pause checks for 15 minutes", () => App.Me.Pause(15));
        var policyFile = d.Status?.PolicyFile ?? "";
        var policy = Ui.V(6, Ui.T("Policy file", 13.5, bold: true),
            Ui.T("What Kai protects, as text. After editing it, accept the change in your own terminal: kai policy accept.", 12, Ui.Muted),
            Ui.H(8, Ui.Ghost("Open in Notepad", async () =>
            {
                if (d.Status is { PolicyFileExists: false }) await KaiCli.RunAsync("init");
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("notepad.exe", $"\"{policyFile}\"") { UseShellExecute = false });
            })));
        var audit = Ui.V(6, Ui.T("Audit log", 13.5, bold: true),
            Ui.T(d.Status?.AuditIntact == false ? "The log's chain is broken: a record was changed or removed." : "Every decision Kai made, hash-chained.", 12,
                 d.Status?.AuditIntact == false ? Ui.Amber : Ui.Muted),
            Ui.Ghost("Verify the log", async () => { var r = await KaiCli.RunAsync("log", "verify"); Toast.Say(r.Message); }));
        var version = Ui.T($"Kai {d.Status?.Version ?? "?"} · commit {d.Status?.Commit ?? "?"} · kai.exe: {KaiCli.Executable ?? "not found"}", 12, Ui.Muted);
        return Ui.V(12, Ui.Card(Ui.V(10, startup, rec, pause)), Ui.Card(policy), Ui.Card(audit), version,
                    Ui.T("To uninstall Kai: Windows Settings → Apps → Installed apps → Kai. It removes Kai Watch and your agents' Kai hooks.", 12, Ui.Muted));
    }
}
