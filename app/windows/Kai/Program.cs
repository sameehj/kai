// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Kai.exe's entry point. One Kai per user: a second start (the Start menu
// while Kai runs in the tray) asks the first to show its window and quits
// before WinUI starts; quitting from inside the WinUI app's constructor
// left the second copy hanging without a window.
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Kai;

public static class Program
{
    internal static EventWaitHandle? ShowSignal;
    static Mutex? _single;

    [STAThread]
    static int Main(string[] args)
    {
        if (!args.Contains("--snapshot"))   // a snapshot is read-only and may run beside Kai
        {
            _single = new Mutex(true, @"Local\Kai.App", out bool first);
            ShowSignal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Kai.App.Show");
            if (!first)
            {
                ShowSignal.Set();
                return 0;
            }
        }
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(p =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            new App();
        });
        return 0;
    }
}
