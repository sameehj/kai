// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Where the app meets Windows and Kai's other programs: kai.exe (every
// record and every policy change goes through it, as on macOS), Kai Watch's
// pipe (status, start, stop, mode), kaicore.dll (the in-process calls the
// macOS app makes too: pause, daily counts), Start with Windows (a per-user
// Run entry) and the agents' real icons.
using System.Diagnostics;
using System.IO.Compression;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace Kai.Core;

public sealed record CommandResult(int Code, string Out, string Err)
{
    public bool Ok => Code == 0;
    /// The most useful line to show when a command fails.
    public string Message => ((Err.Length > 0 ? Err : Out).Split('\n').FirstOrDefault(l => l.Trim().Length > 0) ?? $"exit code {Code}").Trim();
}

public static class KaiCli
{
    /// kai.exe from the same install as the app (bin\kai.exe beside Kai.exe),
    /// so the app never reads output from a different version. KAI_BIN overrides.
    public static string? Executable { get; set; } = Find();

    static string? Find()
    {
        var env = Environment.GetEnvironmentVariable("KAI_BIN");
        var dir = AppContext.BaseDirectory;
        var candidates = new List<string?>
        {
            env,
            Path.Combine(dir, "bin", "kai.exe"),
            Path.Combine(dir, "kai.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Kai", "bin", "kai.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Kai", "kai.exe"),
        };
        return candidates.FirstOrDefault(c => !string.IsNullOrEmpty(c) && File.Exists(c) && !c.EndsWith("Kai.exe", StringComparison.Ordinal));
    }

    public static async Task<CommandResult> RunAsync(params string[] args)
    {
        if (Executable is null) return new CommandResult(127, "", "Kai's command-line tool (kai.exe) wasn't found");
        var psi = new ProcessStartInfo(Executable)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            RedirectStandardInput = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi);
        if (p is null) return new CommandResult(126, "", "kai.exe didn't start");
        p.StandardInput.Close();
        var o = p.StandardOutput.ReadToEndAsync();
        var e = p.StandardError.ReadToEndAsync();
        await p.WaitForExitAsync();
        return new CommandResult(p.ExitCode, await o, await e);
    }
}

/// Kai Watch's pipe: status, start, stop, mode off|watch. Only SYSTEM and
/// the signed-in user can open it.
public static class WatchPipe
{
    public static async Task<string?> AskAsync(string command, int timeoutMs = 3000)
    {
        using var p = new NamedPipeClientStream(".", "kai-watch", PipeDirection.InOut, PipeOptions.Asynchronous);
        using var cts = new CancellationTokenSource(timeoutMs);
        try { await p.ConnectAsync(cts.Token); }
        catch (OperationCanceledException) { return null; }   // Kai Watch isn't running: the caller says so
        catch (IOException) { return null; }
        var b = Encoding.UTF8.GetBytes(command + "\n");
        await p.WriteAsync(b, cts.Token);
        await p.FlushAsync(cts.Token);
        using var ms = new MemoryStream();
        var buf = new byte[4096];
        int n;
        while ((n = await p.ReadAsync(buf, cts.Token)) > 0) ms.Write(buf, 0, n);
        return Encoding.UTF8.GetString(ms.ToArray());
    }
}

/// kaicore.dll (libkai): the calls the macOS app makes in-process. Pause has
/// no kai command on purpose, so an agent can't pause Kai through it.
public static partial class Native
{
    const string Dll = "kaicore.dll";

    [LibraryImport(Dll, StringMarshalling = StringMarshalling.Utf8)]
    private static partial int kai_wall_pause_write(string wall, long minutes);
    [LibraryImport(Dll, StringMarshalling = StringMarshalling.Utf8)]
    private static partial int kai_wall_paused(string wall, long now);
    [LibraryImport(Dll, StringMarshalling = StringMarshalling.Utf8)]
    private static partial int kai_daily_counts(string? date, out int secrets, out int other);
    [LibraryImport(Dll, StringMarshalling = StringMarshalling.Utf8)]
    private static partial int kai_audit(string source, string evt, string decision, string rule, string detail);

    public static bool Available => NativeLibrary.TryLoad(Path.Combine(AppContext.BaseDirectory, Dll), out _);

    static long Now => DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    /// "Pause Kai for N minutes" (0 resumes): the hooks let soft stops through,
    /// recorded, and resume by themselves. Kai's own settings stay protected.
    public static bool Pause(int minutes)
    {
        int rc = kai_wall_pause_write("storage", minutes) | kai_wall_pause_write("network", minutes);
        kai_audit("pause", "pause", minutes > 0 ? "paused" : "resumed", "",
                  minutes > 0 ? $"Kai paused {minutes}m by user" : "Kai resumed by user");
        return rc == 0;
    }

    /// Paused until (Unix seconds), or null. Windows has no Files wall to
    /// confirm the pause: the hooks read this marker themselves.
    public static bool Paused => kai_wall_paused("storage", Now) != 0;

    /// One audit record written by the app itself (a confirm, a pause).
    public static void Audit(string source, string evt, string decision, string rule, string detail) =>
        kai_audit(source, evt, decision, rule, detail);

    public static (int Secrets, int Other) TodayCounts()
    {
        kai_daily_counts(null, out var s, out var o);
        return (s, o);
    }
}

/// Start with Windows: a per-user Run entry.
public static class StartWithWindows
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "Kai";

    public static bool IsOn
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(Key);
            return k?.GetValue(Name) is string;
        }
    }

    public static void Set(bool on, string exePath)
    {
        using var k = Registry.CurrentUser.CreateSubKey(Key);
        if (on) k.SetValue(Name, $"\"{exePath}\" --background");
        else k.DeleteValue(Name, false);
    }
}

/// The agents' real icons, read from the installed program, with bundled
/// fallbacks (the same marks the macOS app ships) so every agent has one.
public static class AgentIcons
{
    /// The installed program for an agent, if Kai finds one.
    public static string? InstalledExe(string agent, string? home = null, string? localAppData = null)
    {
        home ??= Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        localAppData ??= Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        IEnumerable<string> c = agent switch
        {
            "claude" => new[] { Path.Combine(home, ".local", "bin", "claude.exe") }
                        .Concat(Newest(Path.Combine(localAppData, "Claude-Data"), "claude.exe")),
            "cursor" => new[] { Path.Combine(localAppData, "Programs", "cursor", "Cursor.exe") },
            "codex" => new[] { Path.Combine(localAppData, "Programs", "OpenAI", "Codex", "bin", "codex.exe") },
            _ => Array.Empty<string>(),
        };
        return c.FirstOrDefault(File.Exists);
    }

    static IEnumerable<string> Newest(string root, string name)
    {
        if (!Directory.Exists(root)) return Array.Empty<string>();
        var e = new EnumerationOptions { RecurseSubdirectories = true, MaxRecursionDepth = 5, IgnoreInaccessible = true };
        return Directory.EnumerateFiles(root, name, e).OrderByDescending(File.GetLastWriteTimeUtc).Take(1).ToList();
    }

    /// PNG bytes for an agent: the installed program's icon, else the bundled
    /// mark. Never empty for claude, cursor and codex.
    public static byte[] Png(string agent, bool dark = false, string? home = null, string? localAppData = null)
    {
        var exe = InstalledExe(agent, home, localAppData);
        // a program with no icon of its own (codex.exe) would show Windows' generic one
        if (exe is not null && IconPng.HasOwnIcon(exe) && IconPng.FromFile(exe) is { Length: > 0 } png) return png;
        return Bundled(agent, dark);
    }

    public static byte[] Bundled(string agent, bool dark)
    {
        var name = agent switch
        {
            "claude" => "claude-spark@2x.png",
            "cursor" => dark ? "cursor-cube-dark@2x.png" : "cursor-cube-light@2x.png",
            "codex" => dark ? "openai-blossom-white@2x.png" : "openai-blossom-black@2x.png",
            _ => "",
        };
        if (name.Length == 0) return Array.Empty<byte>();
        using var s = typeof(AgentIcons).Assembly.GetManifestResourceStream("Kai.Core.Assets." + name);
        if (s is null) return Array.Empty<byte>();
        using var ms = new MemoryStream();
        s.CopyTo(ms);
        return ms.ToArray();
    }
}

/// A file's icon as PNG (32-bit, from SHGetFileInfo), with no imaging library.
internal static partial class IconPng
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEINFO
    {
        public IntPtr hIcon; public int iIcon; public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ICONINFO { public int fIcon; public int xHotspot; public int yHotspot; public IntPtr hbmMask; public IntPtr hbmColor; }
    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER
    {
        public int biSize; public int biWidth; public int biHeight; public short biPlanes; public short biBitCount;
        public int biCompression; public int biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter;
        public int biClrUsed; public int biClrImportant;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SHGetFileInfoW(string path, uint attr, ref SHFILEINFO info, uint size, uint flags);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetIconInfo(IntPtr h, out ICONINFO info);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr w, IntPtr dc);
    [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr dc, IntPtr bmp, uint start, uint lines, byte[]? bits, ref BITMAPINFOHEADER bi, uint usage);

    const uint SHGFI_ICON = 0x100, SHGFI_LARGEICON = 0x0;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern uint ExtractIconExW(string file, int index, IntPtr[]? large, IntPtr[]? small, uint n);

    /// Does the file carry an icon resource (not just Windows' default one)?
    public static bool HasOwnIcon(string path) => ExtractIconExW(path, -1, null, null, 0) > 0;

    public static byte[]? FromFile(string path)
    {
        var info = new SHFILEINFO();
        if (SHGetFileInfoW(path, 0, ref info, (uint)Marshal.SizeOf<SHFILEINFO>(), SHGFI_ICON | SHGFI_LARGEICON) == IntPtr.Zero
            || info.hIcon == IntPtr.Zero) return null;
        try
        {
            if (!GetIconInfo(info.hIcon, out var ii) || ii.hbmColor == IntPtr.Zero) return null;
            try
            {
                var bi = new BITMAPINFOHEADER { biSize = Marshal.SizeOf<BITMAPINFOHEADER>() };
                var dc = GetDC(IntPtr.Zero);
                try
                {
                    if (GetDIBits(dc, ii.hbmColor, 0, 0, null, ref bi, 0) == 0 || bi.biWidth <= 0) return null;
                    int w = bi.biWidth, h = Math.Abs(bi.biHeight);
                    bi.biBitCount = 32; bi.biCompression = 0; bi.biHeight = -h;   // top-down BGRA
                    var px = new byte[w * h * 4];
                    if (GetDIBits(dc, ii.hbmColor, 0, (uint)h, px, ref bi, 0) == 0) return null;
                    if (px.Where((_, i) => i % 4 == 3).All(a => a == 0))   // no alpha channel: opaque
                        for (int i = 3; i < px.Length; i += 4) px[i] = 255;
                    return Encode(w, h, px);
                }
                finally { ReleaseDC(IntPtr.Zero, dc); }
            }
            finally
            {
                DeleteObject(ii.hbmColor);
                if (ii.hbmMask != IntPtr.Zero) DeleteObject(ii.hbmMask);
            }
        }
        finally { DestroyIcon(info.hIcon); }
    }

    /// BGRA top-down pixels -> PNG (RGBA, filter 0).
    internal static byte[] Encode(int w, int h, byte[] bgra)
    {
        var raw = new byte[h * (w * 4 + 1)];
        for (int y = 0; y < h; y++)
        {
            int o = y * (w * 4 + 1);
            raw[o] = 0;
            for (int x = 0; x < w; x++)
            {
                int s = (y * w + x) * 4, d = o + 1 + x * 4;
                raw[d] = bgra[s + 2]; raw[d + 1] = bgra[s + 1]; raw[d + 2] = bgra[s]; raw[d + 3] = bgra[s + 3];
            }
        }
        using var z = new MemoryStream();
        using (var zs = new ZLibStream(z, CompressionLevel.Optimal, true)) zs.Write(raw);
        using var png = new MemoryStream();
        png.Write(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });
        var ihdr = new byte[13];
        BE(ihdr, 0, w); BE(ihdr, 4, h); ihdr[8] = 8; ihdr[9] = 6;
        Chunk(png, "IHDR", ihdr);
        Chunk(png, "IDAT", z.ToArray());
        Chunk(png, "IEND", Array.Empty<byte>());
        return png.ToArray();
    }

    static void BE(byte[] b, int o, int v) { b[o] = (byte)(v >> 24); b[o + 1] = (byte)(v >> 16); b[o + 2] = (byte)(v >> 8); b[o + 3] = (byte)v; }

    static void Chunk(Stream s, string type, byte[] data)
    {
        var len = new byte[4]; BE(len, 0, data.Length);
        s.Write(len);
        var td = Encoding.ASCII.GetBytes(type).Concat(data).ToArray();
        s.Write(td);
        var crc = new byte[4]; BE(crc, 0, (int)Crc(td));
        s.Write(crc);
    }

    static uint Crc(byte[] d)
    {
        uint c = 0xFFFFFFFF;
        foreach (var b in d)
        {
            c ^= b;
            for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
        }
        return c ^ 0xFFFFFFFF;
    }
}
