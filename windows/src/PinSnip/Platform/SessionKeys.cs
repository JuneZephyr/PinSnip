using System;
using System.Runtime.InteropServices;

namespace PinSnip.Platform;

/// <summary>Enter finishes a long screenshot and Esc cancels it, even while the
/// page being scrolled owns the keyboard. Both keys are swallowed so they do
/// not also land in that page.</summary>
internal sealed class SessionKeys : IDisposable
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int VK_RETURN = 0x0D;
    private const int VK_ESCAPE = 0x1B;

    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc callback, IntPtr module, uint threadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int nCode, IntPtr wParam, IntPtr lParam);

    private readonly Action _onEnter;
    private readonly Action _onEscape;
    private readonly HookProc _proc;
    private IntPtr _hook;

    public SessionKeys(Action onEnter, Action onEscape)
    {
        _onEnter = onEnter;
        _onEscape = onEscape;
        _proc = Handle;
        _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, IntPtr.Zero, 0);
        if (_hook == IntPtr.Zero)
        {
            App.Log($"session keys failed: {Marshal.GetLastWin32Error()}");
        }
    }

    private IntPtr Handle(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && (wParam == (IntPtr)WM_KEYDOWN || wParam == (IntPtr)WM_SYSKEYDOWN))
        {
            int virtualKey = Marshal.ReadInt32(lParam);
            var dispatcher = System.Windows.Application.Current?.Dispatcher;
            if (virtualKey == VK_RETURN)
            {
                dispatcher?.BeginInvoke(_onEnter);
                return (IntPtr)1;
            }
            if (virtualKey == VK_ESCAPE)
            {
                dispatcher?.BeginInvoke(_onEscape);
                return (IntPtr)1;
            }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (_hook == IntPtr.Zero) return;
        UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }
}
