using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Interop;

namespace PinSnip.Platform;

/// <summary>Every Win32 call the app makes lives here, so the rest of the code
/// stays readable.</summary>
internal static class Native
{
    public const int WM_HOTKEY = 0x0312;
    public const int WM_MOUSEWHEEL = 0x020A;

    public const uint MOD_ALT = 0x0001;
    public const uint MOD_CONTROL = 0x0002;
    public const uint MOD_SHIFT = 0x0004;
    public const uint MOD_WIN = 0x0008;
    public const uint MOD_NOREPEAT = 0x4000;

    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int WS_EX_TOOLWINDOW = 0x00000080;

    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;

    public const uint WDA_NONE = 0x00000000;
    /// <summary>Windows 10 2004+: the window is left out of screen captures.
    /// On older builds the call fails and the app hides its own windows
    /// instead.</summary>
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;

    public const int SW_HIDE = 0;
    public const int SW_SHOWNA = 8;

    public static readonly IntPtr HWND_MESSAGE = new IntPtr(-3);
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;

        public POINT(int x, int y)
        {
            X = x;
            Y = y;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint count, INPUT[] inputs, int size);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint affinity);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT point);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int cmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr value);

    [DllImport("Shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(POINT point, uint flags);

    public static void AddExtendedStyle(IntPtr hWnd, int style)
    {
        if (hWnd == IntPtr.Zero) return;
        long current = GetWindowLongPtr(hWnd, GWL_EXSTYLE).ToInt64();
        SetWindowLongPtr(hWnd, GWL_EXSTYLE, new IntPtr(current | (uint)style));
    }

    public static IntPtr Handle(Window window)
    {
        return new WindowInteropHelper(window).Handle;
    }

    /// <summary>Per-monitor DPI of the monitor that contains a physical point.</summary>
    public static double ScaleAt(int x, int y)
    {
        try
        {
            IntPtr monitor = MonitorFromPoint(new POINT(x, y), 2 /* MONITOR_DEFAULTTONEAREST */);
            if (monitor != IntPtr.Zero && GetDpiForMonitor(monitor, 0 /* MDT_EFFECTIVE_DPI */, out uint dpiX, out _) == 0 && dpiX > 0)
            {
                return dpiX / 96.0;
            }
        }
        catch (DllNotFoundException)
        {
            // Shcore is missing before Windows 8.1.
        }
        catch (EntryPointNotFoundException)
        {
        }
        return 1.0;
    }

    public static POINT CursorPosition()
    {
        GetCursorPos(out POINT point);
        return point;
    }

    /// <summary>Gives a window no keyboard focus and keeps it out of Alt+Tab.</summary>
    public static void MakeNonActivating(Window window)
    {
        IntPtr hWnd = Handle(window);
        AddExtendedStyle(hWnd, WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
    }

    /// <summary>Best effort: stops our own windows appearing in captures of
    /// other apps. A no-op on Windows builds older than 2004.</summary>
    public static void ExcludeFromCapture(Window window)
    {
        IntPtr hWnd = Handle(window);
        if (hWnd != IntPtr.Zero) SetWindowDisplayAffinity(hWnd, WDA_EXCLUDEFROMCAPTURE);
    }

    /// <summary>Places a window in physical pixels, bypassing WPF's DIP
    /// translation so a 150% monitor gets exactly the monitor rectangle.</summary>
    public static void Place(Window window, int x, int y, int width, int height)
    {
        IntPtr hWnd = Handle(window);
        if (hWnd == IntPtr.Zero) return;
        SetWindowPos(hWnd, IntPtr.Zero, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
    }

    public static void PlaceTopmost(Window window, int x, int y, int width, int height)
    {
        IntPtr hWnd = Handle(window);
        if (hWnd == IntPtr.Zero) return;
        SetWindowPos(hWnd, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }

    public static RECT WindowRect(Window window)
    {
        RECT rect = default;
        IntPtr hWnd = Handle(window);
        if (hWnd != IntPtr.Zero) GetWindowRect(hWnd, out rect);
        return rect;
    }

    public static bool MoveWindow(Window window, int x, int y)
    {
        IntPtr hWnd = Handle(window);
        if (hWnd == IntPtr.Zero) return false;
        return SetWindowPos(hWnd, IntPtr.Zero, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    public static bool ResizeWindow(Window window, int width, int height)
    {
        IntPtr hWnd = Handle(window);
        if (hWnd == IntPtr.Zero) return false;
        return SetWindowPos(hWnd, IntPtr.Zero, 0, 0, width, height, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    /// <summary>Turns the wheel at a screen point, then puts the cursor back.
    /// Posted WM_MOUSEWHEEL is ignored by browsers; an injected wheel is not.
    /// The waits keep the wheel from landing on the cursor's old window.</summary>
    public static void ScrollAt(int x, int y, int delta)
    {
        GetCursorPos(out POINT previous);
        SetCursorPos(x, y);
        Thread.Sleep(40);

        var input = new INPUT
        {
            Type = 0, // INPUT_MOUSE
            Mouse = new MOUSEINPUT
            {
                mouseData = delta,
                dwFlags = 0x0800 // MOUSEEVENTF_WHEEL
            }
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
        Thread.Sleep(50);
        SetCursorPos(previous.X, previous.Y);
    }

    // x64 INPUT is 40 bytes: a 4-byte type, 4 bytes of padding, then the mouse
    // union. A packed struct is 32 bytes and the wheel never arrives.
    [StructLayout(LayoutKind.Explicit, Size = 40)]
    public struct INPUT
    {
        [FieldOffset(0)] public uint Type;
        [FieldOffset(8)] public MOUSEINPUT Mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public int mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
}
