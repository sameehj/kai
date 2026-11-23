// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Kai's look on Windows, from the macOS app (Theme.swift, assets/BRAND.md):
// neutral greys that follow light and dark mode; teal for actions and fine
// states; purple for the brand only; amber when something needs you; red only
// when Kai is off. Fluent controls, Segoe UI, Mica behind the window. The
// pages are built in code from these helpers.
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;

namespace Kai;

public static class Ui
{
    public static Color Hex(uint h, byte a = 255) => Color.FromArgb(a, (byte)(h >> 16), (byte)(h >> 8), (byte)h);

    static bool Dark => Application.Current.RequestedTheme == ApplicationTheme.Dark;
    static SolidColorBrush B(uint light, uint dark) => new(Hex(Dark ? dark : light));

    public static Brush Teal => new SolidColorBrush(Hex(0x25C7B8));
    public static Brush OnTeal => new SolidColorBrush(Hex(0x0B1F1D));
    public static Brush Purple => new SolidColorBrush(Hex(0x7659E8));
    public static Brush Amber => B(0xAC752A, 0xE4AE66);
    public static Brush Red => B(0xB64F59, 0xEA888B);
    public static Brush Muted => B(0x737787, 0x989BA9);
    public static Brush Soft => B(0x4A4D5C, 0xC9CCD3);
    public static Brush Text => B(0x242532, 0xF4F3F7);
    public static Brush Surface => B(0xFFFFFF, 0x1A1C25);
    public static Brush Raised => B(0xEEEFF6, 0x262935);
    public static Brush Border => B(0xE2E4EB, 0x30323E);
    /// The window's own background where there is no Mica (and in snapshots).
    public static Brush Ink => B(0xFBFBFD, 0x111218);

    public static TextBlock T(string s, double size = 13, Brush? fg = null, bool bold = false, bool wrap = true) => new()
    {
        Text = s, FontSize = size, Foreground = fg ?? Text, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        TextWrapping = wrap ? TextWrapping.WrapWholeWords : TextWrapping.NoWrap,
        TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis, IsTextSelectionEnabled = false,
    };

    public static TextBlock Title(string s) => T(s, 22, bold: true);
    public static TextBlock Caps(string s) => new()
    {
        Text = s.ToUpperInvariant(), FontSize = 11, FontWeight = FontWeights.SemiBold, CharacterSpacing = 80, Foreground = Muted,
    };

    public static Border Card(UIElement child, Brush? stroke = null, double pad = 14) => new()
    {
        Child = child, Padding = new Thickness(pad), CornerRadius = new CornerRadius(12), Background = Surface,
        BorderBrush = stroke ?? Border, BorderThickness = new Thickness(1),
    };

    public static StackPanel V(double spacing = 8, params UIElement[] kids)
    {
        var p = new StackPanel { Spacing = spacing };
        foreach (var k in kids) p.Children.Add(k);
        return p;
    }

    public static StackPanel H(double spacing = 8, params UIElement[] kids)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = spacing };
        foreach (var k in kids) p.Children.Add(k);
        return p;
    }

    /// The primary action: filled teal.
    public static Button Primary(string text, Action click)
    {
        var b = new Button
        {
            Content = text, Background = Teal, Foreground = OnTeal, CornerRadius = new CornerRadius(8),
            Padding = new Thickness(14, 6, 14, 6), FontWeight = FontWeights.SemiBold,
        };
        b.Click += (_, _) => click();
        return b;
    }

    public static Button Ghost(string text, Action click)
    {
        var b = new Button { Content = text, CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 6, 12, 6) };
        b.Click += (_, _) => click();
        return b;
    }

    public static HyperlinkButton Link(string text, Action click)
    {
        var b = new HyperlinkButton { Content = new TextBlock { Text = text, TextWrapping = TextWrapping.WrapWholeWords }, Foreground = Teal, Padding = new Thickness(0) };
        b.Click += (_, _) => click();
        return b;
    }

    /// A small round state dot: teal fine, amber needs you, red Kai off.
    public static Microsoft.UI.Xaml.Shapes.Ellipse Dot(Brush b, double size = 8) => new() { Width = size, Height = size, Fill = b };

    public static Border Pill(string text, Brush fg) => new()
    {
        Child = T(text, 11.5, fg, bold: true, wrap: false), Padding = new Thickness(8, 2, 8, 2),
        CornerRadius = new CornerRadius(10), BorderBrush = fg, BorderThickness = new Thickness(1),
    };

    static readonly Dictionary<string, BitmapImage> Logos = new();

    /// The agent's real logo (its installed program's icon, else Kai's bundled mark).
    public static Image AgentLogo(string agent, double size = 22)
    {
        var key = agent + (Dark ? "-d" : "-l");
        if (!Logos.TryGetValue(key, out var bmp))
        {
            bmp = new BitmapImage();
            var png = Kai.Core.AgentIcons.Png(agent, Dark);
            if (png.Length > 0)
            {
                using var ms = new MemoryStream(png);
                bmp.SetSource(ms.AsRandomAccessStream());
            }
            Logos[key] = bmp;
        }
        return new Image { Source = bmp, Width = size, Height = size };
    }

    public static ScrollViewer Scroll(UIElement content) => new()
    {
        Content = content, HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
    };

    /// A page column: a title, a subtitle, then the content.
    public static ScrollViewer Page(string title, string subtitle, params UIElement[] content)
    {
        var p = V(14, Title(title), T(subtitle, 12, Muted));
        foreach (var c in content) p.Children.Add(c);
        p.Padding = new Thickness(28, 20, 28, 28);
        // One column, full width up to 900 px, anchored beside the menu.
        // (A centred column landed off-screen when the menu collapsed.)
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MaxWidth = 900 });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0, GridUnitType.Star) });
        g.Children.Add(p);
        return Scroll(g);
    }
}
