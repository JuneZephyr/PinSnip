using System;
using System.Windows.Forms;

namespace PinSnip;

/// <summary>Notification-area icon and its menu. The icon is the one embedded
/// in the assembly, not whatever the shell can extract from the exe.</summary>
internal sealed class TrayIcon : IDisposable
{
    private readonly App _app;
    private readonly NotifyIcon _icon;
    private readonly ToolStripMenuItem _captureItem;
    private readonly ToolStripMenuItem _pinItem;
    private readonly ToolStripMenuItem _toggleItem;

    public TrayIcon(App app)
    {
        _app = app;

        _captureItem = new ToolStripMenuItem("区域截图", null, (_, _) => _app.BeginCapture());
        _pinItem = new ToolStripMenuItem("贴剪切板", null, (_, _) => _app.PinClipboard());
        _toggleItem = new ToolStripMenuItem("隐藏 / 显示贴图", null, (_, _) => _app.TogglePins());

        var destroy = new ToolStripMenuItem("销毁全部贴图", null, (_, _) => _app.DestroyPins());
        var settings = new ToolStripMenuItem("偏好设置…", null, (_, _) => _app.OpenSettings());
        var quit = new ToolStripMenuItem("退出 PinSnip", null, (_, _) => _app.Quit());

        var menu = new ContextMenuStrip();
        menu.Items.Add(_captureItem);
        menu.Items.Add(_pinItem);
        menu.Items.Add(_toggleItem);
        menu.Items.Add(destroy);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(settings);
        menu.Items.Add(quit);

        _icon = new NotifyIcon
        {
            Icon = Platform.AppImages.TrayIcon(),
            Text = "PinSnip",
            Visible = true,
            ContextMenuStrip = menu
        };
        _icon.DoubleClick += (_, _) => _app.BeginCapture();

        Refresh();
    }

    public void Refresh()
    {
        _captureItem.Text = $"区域截图 ({_app.Settings.CaptureHotkey})";
        _pinItem.Text = $"贴剪切板 ({_app.Settings.PinHotkey})";
        _toggleItem.Text = $"隐藏 / 显示贴图 ({_app.Settings.TogglePinsHotkey})";
        // The native tooltip is 127 characters. A longer string throws and
        // the icon never appears.
        string tip = $"PinSnip — {_app.Settings.CaptureHotkey} 截图，{_app.Settings.PinHotkey} 贴图";
        _icon.Text = tip.Length <= 127 ? tip : tip.Substring(0, 127);
    }

    public void Notify(string title, string text)
    {
        try
        {
            _icon.BalloonTipTitle = title;
            _icon.BalloonTipText = text;
            _icon.ShowBalloonTip(3000);
        }
        catch
        {
        }
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
