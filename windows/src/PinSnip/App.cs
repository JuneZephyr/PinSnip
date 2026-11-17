using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Media.Imaging;
using Gdi = System.Drawing;
using WinForms = System.Windows.Forms;

namespace PinSnip;

/// <summary>The tray application: hotkeys, the capture session, pinned windows,
/// the long-capture session and quitting.</summary>
internal sealed class App : Application
{
    private const int CaptureHotkeyId = 1;
    private const int PinHotkeyId = 2;
    private const int TogglePinsHotkeyId = 3;

    private readonly List<SelectionWindow> _overlays = new();
    private Platform.HotkeyManager? _hotkeys;
    private TrayIcon? _tray;
    private PinManager? _pins;
    private SettingsWindow? _settingsWindow;
    private PreviewWindow? _preview;
    private LongCaptureRunner? _longRunner;
    private Platform.EscapeWatcher? _escapeWatcher;
    private bool _quitting;

    public new static App Current => (App)Application.Current;

    public AppSettings Settings { get; private set; } = new AppSettings();

    public static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(AppSettings.Folder);
            File.AppendAllText(
                Path.Combine(AppSettings.Folder, "pin-snip.log"),
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
        }
        catch
        {
        }
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnExplicitShutdown;

        DispatcherUnhandledException += (_, args) =>
        {
            Log($"unhandled: {args.Exception}");
            args.Handled = true;
            Notify("PinSnip 出了点问题", args.Exception.Message);
        };

        Settings = AppSettings.Load();
        _pins = new PinManager(this);
        _hotkeys = new Platform.HotkeyManager();
        _tray = new TrayIcon(this);
        ApplyHotkeys();
    }

    // MARK: - Hotkeys

    public void ApplyHotkeys()
    {
        if (_hotkeys == null) return;
        _hotkeys.UnregisterAll();

        var failures = new List<string>();
        if (!_hotkeys.Register(CaptureHotkeyId, Settings.CaptureHotkey, BeginCapture, out string captureError))
        {
            failures.Add("区域截图：" + captureError);
        }
        if (!_hotkeys.Register(PinHotkeyId, Settings.PinHotkey, PinClipboard, out string pinError))
        {
            failures.Add("贴剪切板：" + pinError);
        }
        if (!_hotkeys.Register(TogglePinsHotkeyId, Settings.TogglePinsHotkey, TogglePins, out string toggleError))
        {
            failures.Add("隐藏贴图：" + toggleError);
        }

        _tray?.Refresh();
        if (failures.Count > 0)
        {
            Notify("快捷键未生效", string.Join("\n", failures));
        }
    }

    // MARK: - Capture

    public void BeginCapture()
    {
        if (_overlays.Count > 0)
        {
            CloseOverlays();
            return;
        }

        if (_longRunner != null)
        {
            Notify("正在长截图", "先完成或取消当前的长截图");
            return;
        }

        if (_preview != null)
        {
            _preview.Close();
            _preview = null;
        }

        List<ScreenShot> shots;
        using (_pins!.SuspendForCapture())
        {
            try
            {
                shots = ScreenCapture.CaptureAll();
            }
            catch (Exception ex)
            {
                Log($"capture failed: {ex}");
                Notify("截图失败", ex.Message);
                return;
            }
        }

        if (shots.Count == 0)
        {
            Notify("截图失败", "没有可用的显示器");
            return;
        }

        foreach (ScreenShot shot in shots)
        {
            var window = new SelectionWindow(this, shot);
            _overlays.Add(window);
            window.Closed += (_, _) => _overlays.Remove(window);
            window.Show();
        }

        WinForms.Screen cursorScreen = ScreenCapture.ScreenAtCursor();
        SelectionWindow? active = _overlays.FirstOrDefault(w => w.Shot.Screen.DeviceName == cursorScreen.DeviceName)
                                  ?? _overlays.FirstOrDefault();
        if (active != null)
        {
            active.Activate();
            Platform.Native.SetForegroundWindow(Platform.Native.Handle(active));
            active.Focus();
        }
    }

    public void CloseOverlays()
    {
        foreach (SelectionWindow window in _overlays.ToList())
        {
            try
            {
                window.Close();
            }
            catch
            {
            }
        }
        _overlays.Clear();
    }

    public void CopyToClipboard(BitmapSource image)
    {
        if (ClipboardHelper.SetImage(image))
        {
            Notify("已复制到剪切板", $"{image.PixelWidth} × {image.PixelHeight}");
        }
        else
        {
            Notify("复制失败", "剪切板被其他程序占用，请再试一次");
        }
    }

    // MARK: - Pins

    public void PinImage(BitmapSource image, Gdi.Rectangle? screen)
    {
        _pins?.Add(image, screen);
    }

    public void PinClipboard()
    {
        if (ClipboardHelper.IsMarkedPrivate())
        {
            Notify("已跳过", "剪切板内容被密码管理器标记为隐藏，不读取");
            return;
        }

        if (ClipboardHelper.TryGetImage(out BitmapSource? image) && image != null)
        {
            PinImage(image, null);
            return;
        }

        string? text = ClipboardHelper.TryGetText();
        if (!string.IsNullOrEmpty(text))
        {
            PinImage(Imaging.RenderTextCard(text), null);
            return;
        }

        if (ClipboardHelper.TryGetFileImage(out image) && image != null)
        {
            PinImage(image, null);
            return;
        }

        Notify("剪切板里没有图片或文字", "先复制一张图片，或复制一段文字再按快捷键");
    }

    public void TogglePins()
    {
        _pins?.ToggleAll();
    }

    public void DestroyPins()
    {
        _pins?.DestroyAll();
    }

    /// <summary>Keeps the Shift+Esc watcher installed only while a pin exists.</summary>
    public void PinsChanged()
    {
        bool any = _pins is { Count: > 0 };
        if (any && _escapeWatcher == null)
        {
            _escapeWatcher = Platform.EscapeWatcher.Start(DestroyPins);
        }
        else if (!any && _escapeWatcher != null)
        {
            _escapeWatcher.Dispose();
            _escapeWatcher = null;
        }
    }

    // MARK: - Long capture

    public void StartLongCapture(Gdi.Rectangle region, Gdi.Bitmap seed, Gdi.Rectangle screen)
    {
        if (_longRunner != null)
        {
            seed.Dispose();
            return;
        }

        if (_preview != null)
        {
            _preview.Close();
            _preview = null;
        }

        int maxHeight = Math.Min(30000, Math.Max(2000, screen.Height * 20));
        int progressLimit = (int)Math.Min(maxHeight, Math.Max(seed.Height, 20L * seed.Height));

        var runner = new LongCaptureRunner(region, seed, maxHeight, progressLimit);
        var preview = new PreviewWindow(screen, region);
        _longRunner = runner;
        _preview = preview;

        runner.Finished += (_, _) =>
        {
            if (ReferenceEquals(_longRunner, runner)) _longRunner = null;
        };
        preview.Closed += (_, _) =>
        {
            if (ReferenceEquals(_preview, preview)) _preview = null;
            if (ReferenceEquals(_longRunner, runner))
            {
                runner.Abandon();
                _longRunner = null;
            }
        };

        preview.Attach(runner);
        runner.Start();
    }

    // MARK: - Settings and quitting

    public void OpenSettings()
    {
        if (_settingsWindow is { IsLoaded: true })
        {
            _settingsWindow.Activate();
            return;
        }
        _settingsWindow = new SettingsWindow(this);
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    public void Notify(string title, string text)
    {
        _tray?.Notify(title, text);
    }

    public void Quit()
    {
        if (_quitting) return;
        _quitting = true;

        CloseOverlays();
        _longRunner?.Abandon();
        _preview?.Close();
        _escapeWatcher?.Dispose();
        _escapeWatcher = null;
        _pins?.DestroyAll();
        _hotkeys?.Dispose();
        _hotkeys = null;
        _tray?.Dispose();
        _tray = null;

        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _hotkeys?.Dispose();
        _escapeWatcher?.Dispose();
        _tray?.Dispose();
        base.OnExit(e);
    }
}
