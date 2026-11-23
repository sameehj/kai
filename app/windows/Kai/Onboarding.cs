// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// First run (Onboarding.swift): three panes, Skip on every one, shown once.
// 1. Which agents Kai connected. 2. Internet watching (Kai Watch, installed
// with Kai: no system approval step on Windows). 3. Ask Kai and its model.
using Kai.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Kai;

public static class Onboarding
{
    public static async Task ShowAsync(MainWindow w)
    {
        if (w.Root is null) return;
        int pane = 0;
        var host = new ContentControl { MinHeight = 240, MinWidth = 440, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var dlg = new ContentDialog { XamlRoot = w.Root, CloseButtonText = "Skip", DefaultButton = ContentDialogButton.Primary };

        void Render()
        {
            var d = App.Me.Records.Data;
            dlg.Title = $"Kai · {pane + 1} of 3";
            dlg.PrimaryButtonText = pane == 2 ? "Open Kai" : "Continue";
            dlg.SecondaryButtonText = pane > 0 ? "Back" : "";
            host.Content = pane switch
            {
                0 => Connected(d),
                1 => Internet(d),
                _ => Ask(),
            };
        }

        dlg.Content = host;
        dlg.PrimaryButtonClick += (_, a) => { if (pane < 2) { a.Cancel = true; pane++; Render(); } };
        dlg.SecondaryButtonClick += (_, a) => { a.Cancel = true; pane = Math.Max(0, pane - 1); Render(); };
        Render();
        await dlg.ShowAsync();
        App.Me.Settings.OnboardingDone = true;   // finished or skipped: never again
        App.Me.Settings.Save();
        if (!StartWithWindows.IsOn) StartWithWindows.Set(true, Path.Combine(AppContext.BaseDirectory, "Kai.exe"));
        w.Go("now");
    }

    static UIElement Connected(Snapshot0 d)
    {
        var names = KaiRecords.Agents(d).Where(a => a.Connected).Select(a => a.Key).ToList();
        var v = Ui.V(12, Ui.T(names.Count == 0 ? "Kai didn't find a supported agent yet."
                                               : $"Kai connected {Names.Joined(names.Select(Names.Agent).ToList())}.", 20, bold: true));
        var logos = Ui.H(12);
        foreach (var n in names) logos.Children.Add(Ui.H(6, Ui.AgentLogo(n, 28), Ui.T(Names.Agent(n), 13, wrap: false)));
        v.Children.Add(logos);
        v.Children.Add(Ui.T(names.Count == 0
            ? "When you install Claude Code, Cursor or Codex, Kai connects it by itself. You can turn each one off in Settings → Agents."
            : "Kai checks what they read, edit and run, and keeps a list on this computer only (no file contents). Turn any of them off in Settings → Agents.",
            13, Ui.Muted));
        if (names.Contains("codex"))
            v.Children.Add(Ui.T("Codex runs Kai's checks only after you trust them once: open Codex, run /hooks, and trust Kai's entries.", 12.5, Ui.Amber));
        return v;
    }

    static UIElement Internet(Snapshot0 d)
    {
        var s = KaiRecords.Internet(d);
        return Ui.V(12,
            Ui.T(s switch
            {
                AskInternet.On => "Internet watching is on.",
                AskInternet.Stopped => "Internet watching stopped.",
                _ => "Internet watching is off.",
            }, 20, bold: true),
            Ui.T("Kai Watch, installed with Kai, lists the hosts your agents connect to, on this computer only. It watches: it doesn't read traffic and doesn't block anything.", 13, Ui.Muted),
            s == AskInternet.Stopped
                ? Ui.Primary("Restart", async () => await App.Me.RestartWatchingAsync())
                : Ui.Link("Change it in Settings → Internet", () => App.Me.Main?.Go("settings:internet")));
    }

    static UIElement Ask() => Ui.V(12,
        Ui.T("Ask Kai anything about what your agents did.", 20, bold: true),
        Ui.T("Answers come from Kai's own records. Kai's templates work right away; a small model that runs on this computer can word them better.", 13, Ui.Muted),
        Ui.H(8, Ui.T("Answers:", 12.5, Ui.Muted), AskPage.Model.Chip()));
}
