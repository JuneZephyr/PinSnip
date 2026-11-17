using System;
using System.Collections.Generic;
using System.Text;
using System.Windows.Input;
using System.Windows.Interop;

namespace PinSnip.Platform;

/// <summary>A global shortcut written as text, for example "F1" or "Shift+F3".</summary>
internal readonly struct Hotkey
{
    public uint Modifiers { get; }
    public uint VirtualKey { get; }
    public string Display { get; }

    private Hotkey(uint modifiers, uint virtualKey, string display)
    {
        Modifiers = modifiers;
        VirtualKey = virtualKey;
        Display = display;
    }

    public static bool TryParse(string text, out Hotkey hotkey, out string error)
    {
        hotkey = default;
        error = "";

        if (string.IsNullOrWhiteSpace(text))
        {
            error = "快捷键不能为空";
            return false;
        }

        uint modifiers = 0;
        uint virtualKey = 0;
        int keys = 0;

        foreach (string raw in text.Split('+', StringSplitOptions.RemoveEmptyEntries))
        {
            string token = raw.Trim();
            if (token.Length == 0) continue;

            switch (token.ToLowerInvariant())
            {
                case "ctrl":
                case "control":
                    modifiers |= Native.MOD_CONTROL;
                    continue;
                case "alt":
                case "shift":
                    modifiers |= token.Equals("alt", StringComparison.OrdinalIgnoreCase) ? Native.MOD_ALT : Native.MOD_SHIFT;
                    continue;
                case "win":
                case "windows":
                    modifiers |= Native.MOD_WIN;
                    continue;
            }

            if (!TryParseKey(token, out Key key))
            {
                error = $"无法识别的按键“{token}”";
                return false;
            }
            virtualKey = (uint)KeyInterop.VirtualKeyFromKey(key);
            keys++;
        }

        if (keys != 1 || virtualKey == 0)
        {
            error = "一个快捷键只能有一个主按键";
            return false;
        }

        hotkey = new Hotkey(modifiers, virtualKey, Describe(modifiers, virtualKey));
        return true;
    }

    private static bool TryParseKey(string token, out Key key)
    {
        if (token.Length == 1 && char.IsDigit(token[0]))
        {
            key = (Key)((int)Key.D0 + (token[0] - '0'));
            return true;
        }
        if (token.Length == 1 && char.IsLetter(token[0]))
        {
            key = (Key)((int)Key.A + (char.ToUpperInvariant(token[0]) - 'A'));
            return true;
        }
        if (token.Equals("PrintScreen", StringComparison.OrdinalIgnoreCase))
        {
            key = Key.Snapshot;
            return true;
        }
        return Enum.TryParse(token, ignoreCase: true, out key) && key != Key.None;
    }

    public static string Describe(uint modifiers, uint virtualKey)
    {
        var text = new StringBuilder();
        if ((modifiers & Native.MOD_CONTROL) != 0) text.Append("Ctrl+");
        if ((modifiers & Native.MOD_ALT) != 0) text.Append("Alt+");
        if ((modifiers & Native.MOD_SHIFT) != 0) text.Append("Shift+");
        if ((modifiers & Native.MOD_WIN) != 0) text.Append("Win+");

        Key key = KeyInterop.KeyFromVirtualKey((int)virtualKey);
        string name;
        if (virtualKey >= 0x30 && virtualKey <= 0x39)
        {
            name = ((char)virtualKey).ToString();
        }
        else if (virtualKey >= 0x41 && virtualKey <= 0x5A)
        {
            name = ((char)virtualKey).ToString();
        }
        else if (key == Key.Snapshot)
        {
            name = "PrintScreen";
        }
        else
        {
            name = key.ToString();
        }
        text.Append(name);
        return text.ToString();
    }

    /// <summary>True when two specs would fight over the same key.</summary>
    public static bool Same(string a, string b)
    {
        if (!TryParse(a, out Hotkey first, out _)) return false;
        if (!TryParse(b, out Hotkey second, out _)) return false;
        return first.VirtualKey == second.VirtualKey && first.Modifiers == second.Modifiers;
    }
}

/// <summary>Owns the message-only window that receives WM_HOTKEY.</summary>
internal sealed class HotkeyManager : IDisposable
{
    private readonly Dictionary<int, Action> _actions = new();
    private HwndSource? _source;

    private void EnsureSource()
    {
        if (_source != null) return;
        var parameters = new HwndSourceParameters("PinSnipHotkeys")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0,
            ParentWindow = Native.HWND_MESSAGE
        };
        _source = new HwndSource(parameters);
        _source.AddHook(WndProc);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WM_HOTKEY)
        {
            int id = wParam.ToInt32();
            if (_actions.TryGetValue(id, out Action? action))
            {
                handled = true;
                try
                {
                    action();
                }
                catch (Exception ex)
                {
                    App.Log($"hotkey {id} failed: {ex}");
                }
            }
        }
        return IntPtr.Zero;
    }

    public bool Register(int id, string spec, Action action, out string error)
    {
        Unregister(id);
        if (!Hotkey.TryParse(spec, out Hotkey hotkey, out error)) return false;

        EnsureSource();
        if (!Native.RegisterHotKey(_source!.Handle, id, hotkey.Modifiers | Native.MOD_NOREPEAT, hotkey.VirtualKey))
        {
            int code = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
            error = $"“{hotkey.Display}”已被其他程序占用（错误 {code}）";
            return false;
        }
        _actions[id] = action;
        error = "";
        return true;
    }

    public void Unregister(int id)
    {
        if (!_actions.ContainsKey(id)) return;
        if (_source != null) Native.UnregisterHotKey(_source.Handle, id);
        _actions.Remove(id);
    }

    public void UnregisterAll()
    {
        foreach (int id in new List<int>(_actions.Keys)) Unregister(id);
    }

    public void Dispose()
    {
        UnregisterAll();
        _source?.Dispose();
        _source = null;
    }
}
