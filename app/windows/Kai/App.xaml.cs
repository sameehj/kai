// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
using Microsoft.UI.Xaml;

namespace Kai;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
    }
}
