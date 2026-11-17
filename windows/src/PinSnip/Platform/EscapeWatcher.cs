using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace PinSnip.Platform;

/// <summary>Watches for Shift+Esc without blocking it, so a key press still
/// reaches the program the user is typing in. Installed only while at least one
/// pin is on screen.</summary>
internal sealed class EscapeWatcher : IDisposable
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int VK_SHIFT = 0x10;
    private const int VK_ESCAPE = 0x1B;

    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc callback, IntPtr module, uint threadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern short GetKeyState(int virtualKey);

    // The delegate must stay reachable while the hook is installed.
    private static HookProc? _callback;
    private static EscapeWatcher? _active;

    private IntPtr _hook;
    private readonly Action _onEscape;
    private readonly HookProc _proc;

    private EscapeWatcher(Action onEscape)
    {
        _onEscape = onEscape;
        _proc = Handle;
        _callback = _proc;
        _active = this;
        _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, IntPtr.Zero, 0);
        if (_hook == IntPtr.Zero)
        {
            App.Log($"keyboard hook failed: {Marshal.GetLastWin32Error()}");
            _callback = null;
            _active = null;
        }
    }

    public static EscapeWatcher? Start(Action onEscape)
    {
        _active?.Dispose();
        var watcher = new EscapeWatcher(onEscape);
        return watcher._hook == IntPtr.Zero ? null : watcher;
    }

    private IntPtr Handle(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN))
        {
            int virtualKey = Marshal.ReadInt32(lParam);
            bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
            if (virtualKey == VK_ESCAPE && shift)
            {
                var dispatcher = System.Windows.Application.Current?.Dispatcher;
                Action action = _onEscape;
                if (dispatcher != null)
                {
                    dispatcher.BeginInvoke(action);
                }
            }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
        if (ReferenceEquals(_active, this))
        {
            _active = null;
            _callback = null;
        }
    }
}
