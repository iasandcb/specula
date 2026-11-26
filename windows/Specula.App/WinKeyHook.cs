using System.Runtime.InteropServices;

namespace Specula;

/// <summary>
/// Low-level hook installed while the session is connected. It runs before the IME, so Shift and
/// the other modifiers are forwarded as raw scan codes. Swallowing the key keeps the Windows
/// key, Alt+Tab, and Ctrl+Esc inside the remote session.
/// </summary>
public sealed class WinKeyHook : IDisposable
{
    const int WhKeyboardLl = 13;
    const int WmKeyDown = 0x0100;
    const int WmSysKeyDown = 0x0104;
    const uint LlkhfUp = 0x80;
    const uint LlkhfExtended = 0x01;

    HookProc? _proc;
    IntPtr _hook;

    /// <summary>Return true to swallow the key. Arguments are vk, scan code, extended, and down.</summary>
    public Func<int, int, bool, bool, bool>? Capture { get; set; }

    public void Install()
    {
        if (_hook != IntPtr.Zero) return;
        _proc = Proc;
        _hook = SetWindowsHookEx(WhKeyboardLl, _proc, IntPtr.Zero, 0);
    }

    public void Uninstall()
    {
        if (_hook == IntPtr.Zero) return;
        UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }

    public void Dispose() => Uninstall();

    IntPtr Proc(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && Capture != null)
        {
            try
            {
                var data = Marshal.PtrToStructure<KbdLl>(lParam);
                var message = (int)wParam;
                var down = (message == WmKeyDown || message == WmSysKeyDown) && (data.flags & LlkhfUp) == 0;
                var extended = (data.flags & LlkhfExtended) != 0;
                if (Capture((int)data.vkCode, (int)data.scanCode, extended, down))
                    return (IntPtr)1;
            }
            catch
            {
                /* a hook must not take down the desktop */
            }
        }
        return CallNextHookEx(_hook, code, wParam, lParam);
    }

    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    struct KbdLl
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public nint dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    static extern IntPtr CallNextHookEx(IntPtr hhk, int code, IntPtr wParam, IntPtr lParam);
}
