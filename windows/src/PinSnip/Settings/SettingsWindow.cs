using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace PinSnip;

/// <summary>A read-only box that records the next key combination pressed into
/// it. Only F-keys, letters and digits make sense as global shortcuts.</summary>
internal sealed class HotkeyBox : TextBox
{
    public HotkeyBox(string value)
    {
        Text = value;
        IsReadOnly = true;
        IsReadOnlyCaretVisible = false;
        Cursor = Cursors.Hand;
        MinWidth = 150;
        Height = 28;
        Padding = new Thickness(6, 4, 6, 4);
        Background = new SolidColorBrush(Color.FromRgb(0x2E, 0x2E, 0x32));
        Foreground = Brushes.White;
        BorderBrush = new SolidColorBrush(Color.FromRgb(0x55, 0x55, 0x5A));
        Focusable = true;
        ToolTip = "点击后按下想用的快捷键";
    }

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        Key key = e.Key == Key.System ? e.SystemKey : e.Key;

        if (key == Key.Tab)
        {
            base.OnPreviewKeyDown(e);
            return;
        }

        e.Handled = true;

        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftShift or Key.RightShift
            or Key.LeftAlt or Key.RightAlt or Key.LWin or Key.RWin or Key.None)
        {
            return;
        }

        if (key == Key.Back || key == Key.Delete)
        {
            Text = "";
            return;
        }

        uint modifiers = 0;
        if ((Keyboard.Modifiers & ModifierKeys.Control) != 0) modifiers |= Platform.Native.MOD_CONTROL;
        if ((Keyboard.Modifiers & ModifierKeys.Alt) != 0) modifiers |= Platform.Native.MOD_ALT;
        if ((Keyboard.Modifiers & ModifierKeys.Shift) != 0) modifiers |= Platform.Native.MOD_SHIFT;
        if ((Keyboard.Modifiers & ModifierKeys.Windows) != 0) modifiers |= Platform.Native.MOD_WIN;

        uint virtualKey = (uint)KeyInterop.VirtualKeyFromKey(key);
        if (virtualKey == 0) return;
        Text = Platform.Hotkey.Describe(modifiers, virtualKey);
    }
}

internal sealed class SettingsWindow : Window
{
    private readonly App _app;
    private readonly HotkeyBox _capture;
    private readonly HotkeyBox _pin;
    private readonly HotkeyBox _toggle;
    private readonly CheckBox _launch;

    public SettingsWindow(App app)
    {
        _app = app;

        Title = "PinSnip 偏好设置";
        Icon = Platform.AppImages.WindowIcon;
        Width = 480;
        Height = 400;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(Color.FromRgb(0x20, 0x20, 0x22));
        Foreground = Brushes.White;
        ShowInTaskbar = true;

        _capture = new HotkeyBox(app.Settings.CaptureHotkey);
        _pin = new HotkeyBox(app.Settings.PinHotkey);
        _toggle = new HotkeyBox(app.Settings.TogglePinsHotkey);

        _launch = new CheckBox
        {
            Content = "登录 Windows 时自动启动 PinSnip",
            IsChecked = LoginItem.IsEnabled(),
            Foreground = Brushes.White,
            Margin = new Thickness(0, 14, 0, 0)
        };

        var panel = new StackPanel { Margin = new Thickness(20) };
        panel.Children.Add(Heading("快捷键"));
        panel.Children.Add(Row("区域截图", _capture));
        panel.Children.Add(Row("贴剪切板", _pin));
        panel.Children.Add(Row("隐藏 / 显示贴图", _toggle));
        panel.Children.Add(_launch);

        panel.Children.Add(new TextBlock
        {
            Text = "回车或双击复制；Esc 取消；长截图里回车完成。\n所有截图只在内存与剪切板中，不会写入磁盘。",
            Foreground = new SolidColorBrush(Color.FromRgb(0xAA, 0xAA, 0xAA)),
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 18, 0, 0)
        });

        panel.Children.Add(new TextBlock
        {
            Text = "PinSnip 1.0.0 · Windows 版 · MIT 许可",
            Foreground = new SolidColorBrush(Color.FromRgb(0x77, 0x77, 0x77)),
            FontSize = 12,
            Margin = new Thickness(0, 8, 0, 0)
        });

        var save = new Button
        {
            Content = "保存",
            MinWidth = 90,
            Height = 30,
            Margin = new Thickness(0, 0, 8, 0),
            Background = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)),
            Foreground = Brushes.White,
            BorderBrush = Brushes.Transparent
        };
        save.Click += (_, _) => SaveSettings();

        var cancel = new Button
        {
            Content = "取消",
            MinWidth = 90,
            Height = 30,
            Background = new SolidColorBrush(Color.FromRgb(0x33, 0x33, 0x36)),
            Foreground = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromRgb(0x50, 0x50, 0x55))
        };
        cancel.Click += (_, _) => Close();

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 18, 0, 0)
        };
        buttons.Children.Add(save);
        buttons.Children.Add(cancel);
        panel.Children.Add(buttons);

        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private static TextBlock Heading(string text)
    {
        return new TextBlock
        {
            Text = text,
            FontSize = 15,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brushes.White,
            Margin = new Thickness(0, 0, 0, 10)
        };
    }

    private static Grid Row(string label, FrameworkElement field)
    {
        var grid = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(140) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var text = new TextBlock
        {
            Text = label,
            Foreground = new SolidColorBrush(Color.FromRgb(0xDD, 0xDD, 0xDD)),
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(field, 1);
        grid.Children.Add(text);
        grid.Children.Add(field);
        return grid;
    }

    private void SaveSettings()
    {
        string capture = _capture.Text.Trim();
        string pin = _pin.Text.Trim();
        string toggle = _toggle.Text.Trim();

        var errors = new List<string>();
        foreach ((string label, string spec) in new[]
                 {
                     ("区域截图", capture), ("贴剪切板", pin), ("隐藏 / 显示贴图", toggle)
                 })
        {
            if (!Platform.Hotkey.TryParse(spec, out _, out string error))
            {
                errors.Add($"{label}：{error}");
            }
        }

        if (Platform.Hotkey.Same(capture, pin) || Platform.Hotkey.Same(capture, toggle) || Platform.Hotkey.Same(pin, toggle))
        {
            errors.Add("两个快捷键不能相同");
        }

        if (errors.Count > 0)
        {
            MessageBox.Show(this, string.Join("\n", errors), "快捷键设置有误",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        _app.Settings.CaptureHotkey = capture;
        _app.Settings.PinHotkey = pin;
        _app.Settings.TogglePinsHotkey = toggle;
        _app.Settings.LaunchAtLogin = _launch.IsChecked == true;
        _app.Settings.Save();
        LoginItem.Set(_app.Settings.LaunchAtLogin);
        _app.ApplyHotkeys();
        Close();
    }
}
