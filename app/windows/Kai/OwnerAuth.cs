// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// The owner confirms before Kai turns protection down or allows a stopped
// file (OwnerAuth.swift: Touch ID or the login password). Windows Hello when
// it's set up, else the Windows account password, checked by Windows. One
// confirmation covers 30 minutes, as on macOS.
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Windows.Security.Credentials.UI;

namespace Kai;

public static partial class OwnerAuth
{
    static DateTimeOffset _until = DateTimeOffset.MinValue;

    public static async Task<bool> ConfirmAsync(Window w, string reason)
    {
        if (DateTimeOffset.Now < _until) return true;
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(w);
        bool ok;
        if (await UserConsentVerifier.CheckAvailabilityAsync() == UserConsentVerifierAvailability.Available)
        {
            var r = await UserConsentVerifierInterop.RequestVerificationForWindowAsync(hwnd, "Kai: " + reason);
            ok = r == UserConsentVerificationResult.Verified;
        }
        else
        {
            ok = await Task.Run(() => PasswordPrompt(hwnd, reason));
        }
        if (ok) _until = DateTimeOffset.Now.AddMinutes(30);
        return ok;
    }

    // ------------------------------------------------ password fallback (CredUI)

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDUI_INFO
    {
        public int cbSize; public IntPtr hwndParent; public string pszMessageText; public string pszCaptionText; public IntPtr hbmBanner;
    }

    [DllImport("credui.dll", CharSet = CharSet.Unicode)]
    static extern int CredUIPromptForWindowsCredentialsW(ref CREDUI_INFO info, int authError, ref uint package, IntPtr inBuf,
                                                         uint inSize, out IntPtr outBuf, out uint outSize, ref bool save, int flags);
    [DllImport("credui.dll", CharSet = CharSet.Unicode)]
    static extern bool CredUnPackAuthenticationBufferW(int flags, IntPtr buf, uint size, char[] user, ref int userLen,
                                                       char[] domain, ref int domainLen, char[] pass, ref int passLen);
    [DllImport("ole32.dll")] static extern void CoTaskMemFree(IntPtr p);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool LogonUserW(string user, string? domain, string pass, int type, int provider, out IntPtr token);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    const int CREDUIWIN_ENUMERATE_CURRENT_USER = 0x200;
    const int LOGON32_LOGON_INTERACTIVE = 2;

    /// Windows' own credential prompt for the signed-in account; the password
    /// is checked by Windows (LogonUser) and never kept.
    static bool PasswordPrompt(IntPtr hwnd, string reason)
    {
        var info = new CREDUI_INFO { cbSize = Marshal.SizeOf<CREDUI_INFO>(), hwndParent = hwnd, pszCaptionText = "Kai", pszMessageText = reason };
        uint pkg = 0;
        bool save = false;
        if (CredUIPromptForWindowsCredentialsW(ref info, 0, ref pkg, IntPtr.Zero, 0, out var buf, out var size, ref save,
                                               CREDUIWIN_ENUMERATE_CURRENT_USER) != 0) return false;
        var user = new char[256]; var dom = new char[256]; var pass = new char[256];
        int ul = 256, dl = 256, pl = 256;
        try
        {
            if (!CredUnPackAuthenticationBufferW(0, buf, size, user, ref ul, dom, ref dl, pass, ref pl)) return false;
            var u = new string(user, 0, Math.Max(0, ul - 1));
            string? d = null;
            int slash = u.IndexOf('\\');
            if (slash > 0) { d = u[..slash]; u = u[(slash + 1)..]; }
            if (!string.Equals(u, Environment.UserName, StringComparison.OrdinalIgnoreCase)) return false;   // only the signed-in user
            if (!LogonUserW(u, d, new string(pass, 0, Math.Max(0, pl - 1)), LOGON32_LOGON_INTERACTIVE, 0, out var tok)) return false;
            CloseHandle(tok);
            return true;
        }
        finally
        {
            Array.Clear(pass);
            CoTaskMemFree(buf);
        }
    }
}
