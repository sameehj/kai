// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// `Kai.exe --snapshot <dir>` (Snapshot.swift): render Now, Activity, Ask
// Kai, each Settings section and the flyout with live data into PNGs, then
// quit. For reviews and release checks. Read-only: one refresh, no agent is
// connected, nothing is written but the PNGs.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Storage.Streams;

namespace Kai;

public static class Snapshot
{
    public static async Task RunAsync(string dir)
    {
        Directory.CreateDirectory(dir);
        await App.Me.RefreshAsync();
        var w = new MainWindow();
        w.Activate();
        await Task.Delay(1500);
        foreach (var page in new[] { "now", "activity", "ask", "settings:agents", "settings:internet", "settings:model", "settings:advanced" })
        {
            w.Go(page);
            await Task.Delay(1200);
            await Save(w.Content, Path.Combine(dir, "window-" + page.Replace(':', '-') + ".png"));
        }
        var f = new FlyoutWindow();
        f.ShowNearTray();
        await Task.Delay(1500);
        if (f.Content is not null) await Save(f.Content, Path.Combine(dir, "flyout.png"));
        f.Close();
        w.Close();
        App.Me.Exit();
    }

    static async Task Save(UIElement e, string path)
    {
        var rtb = new RenderTargetBitmap();
        await rtb.RenderAsync(e);
        var px = await rtb.GetPixelsAsync();
        using var ras = new InMemoryRandomAccessStream();
        var enc = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, ras);
        enc.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)rtb.PixelWidth, (uint)rtb.PixelHeight, 96, 96, px.ToArray());
        await enc.FlushAsync();
        ras.Seek(0);
        await using var fs = File.Create(path);
        await ras.AsStreamForRead().CopyToAsync(fs);
    }
}
