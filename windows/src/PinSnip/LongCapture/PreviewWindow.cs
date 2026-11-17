using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Gdi = System.Drawing;

namespace PinSnip;

/// <summary>Side panel shown while a long screenshot is being stitched. It shows
/// the real stitched image, offers the automatic scroll toggle and finishes
/// with copy or save.</summary>
internal sealed class PreviewWindow : Window
{
    private readonly Image _image;
    private readonly TextBlock _status;
    private readonly Button _autoButton;
    private readonly Button _doneButton;
    private readonly Button _saveButton;
    private readonly Gdi.Rectangle _screen;
    private readonly Gdi.Rectangle _region;

    private LongCaptureRunner? _runner;
    private Platform.SessionKeys? _keys;
    private BitmapSource? _current;
    private bool _finished;

    public PreviewWindow(Gdi.Rectangle screen, Gdi.Rectangle region)
    {
        _screen = screen;
        _region = region;

        Title = "长截图";
        Icon = Platform.AppImages.WindowIcon;
        Width = 460;
        Height = 620;
        MinWidth = 320;
        MinHeight = 300;
        WindowStartupLocation = WindowStartupLocation.Manual;
        ShowInTaskbar = false;
        Topmost = true;
        Background = new SolidColorBrush(Color.FromRgb(0x1A, 0x1A, 0x1C));

        _image = new Image
        {
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Center,
            MaxWidth = 420,
            Margin = new Thickness(12)
        };
        RenderOptions.SetBitmapScalingMode(_image, BitmapScalingMode.HighQuality);

        var scroller = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Background = new SolidColorBrush(Color.FromRgb(0x10, 0x10, 0x12)),
            Content = _image
        };

        _status = new TextBlock
        {
            Foreground = new SolidColorBrush(Color.FromRgb(0xDD, 0xDD, 0xDD)),
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(12, 8, 12, 6),
            Text = "正在等待页面滚动…"
        };

        _autoButton = MakeButton("自动滚动", () => ToggleAuto());
        _doneButton = MakeButton("完成", FinishOrCopy);
        _doneButton.Background = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF));
        _saveButton = MakeButton("保存…", Save);
        _saveButton.IsEnabled = false;
        Button cancel = MakeButton("取消", CancelSession);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(8, 0, 8, 10)
        };
        buttons.Children.Add(_autoButton);
        buttons.Children.Add(_doneButton);
        buttons.Children.Add(_saveButton);
        buttons.Children.Add(cancel);

        var layout = new DockPanel();
        DockPanel.SetDock(_status, Dock.Top);
        DockPanel.SetDock(buttons, Dock.Bottom);
        layout.Children.Add(_status);
        layout.Children.Add(buttons);
        layout.Children.Add(scroller);
        Content = layout;

        SourceInitialized += (_, _) => Platform.Native.ExcludeFromCapture(this);
        Loaded += (_, _) => Place();
        Closing += (_, _) => _runner?.Abandon();
        Closed += (_, _) =>
        {
            _keys?.Dispose();
            _keys = null;
        };
    }

    private static Button MakeButton(string text, Action click)
    {
        var button = new Button
        {
            Content = text,
            MinWidth = 84,
            Height = 30,
            Margin = new Thickness(4, 0, 4, 0),
            Background = new SolidColorBrush(Color.FromRgb(0x33, 0x33, 0x36)),
            Foreground = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromRgb(0x50, 0x50, 0x55))
        };
        button.Click += (_, _) => click();
        return button;
    }

    public void Attach(LongCaptureRunner runner)
    {
        _runner = runner;
        runner.Preview += OnPreview;
        runner.Finished += OnFinished;
        runner.Notice += OnNotice;
        Show();
        Activate();
        // Enter and Esc have to work while the page being scrolled has the
        // keyboard. The preview itself is not focused then.
        _keys = new Platform.SessionKeys(FinishOrCopy, CancelSession);
    }

    /// <summary>Puts the panel in the largest free area that does not cover
    /// the captured region. A panel on top of the region steals the wheel and
    /// gets stitched into the picture.</summary>
    private void Place()
    {
        IntPtr handle = new System.Windows.Interop.WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero) return;

        double scale = Platform.Native.ScaleAt(_screen.Left + _screen.Width / 2, _screen.Top + _screen.Height / 2);
        int margin = (int)Math.Round(12 * scale);
        int desiredW = (int)Math.Round(420 * scale);
        int desiredH = (int)Math.Round(520 * scale);
        int minW = (int)Math.Round(200 * scale);
        int minH = (int)Math.Round(160 * scale);

        Gdi.Rectangle screen = _screen;
        Gdi.Rectangle region = _region;
        int bestArea = 0;
        int bestX = 0, bestY = 0, bestW = 0, bestH = 0;
        bool beside = false;

        void Consider(int x, int y, int w, int h, bool isBeside)
        {
            if (w < minW || h < minH) return;
            var slot = new Gdi.Rectangle(x, y, w, h);
            if (slot.IntersectsWith(region)) return;
            int area = w * h;
            if (area <= bestArea) return;
            bestArea = area;
            bestX = x;
            bestY = y;
            bestW = Math.Min(desiredW, w);
            bestH = Math.Min(desiredH, h);
            beside = isBeside;
        }

        Consider(region.Right + margin, screen.Top + margin,
            screen.Right - margin - (region.Right + margin), screen.Height - margin * 2, true);
        Consider(screen.Left + margin, screen.Top + margin,
            region.Left - margin - (screen.Left + margin), screen.Height - margin * 2, true);
        Consider(screen.Left + margin, region.Bottom + margin,
            screen.Width - margin * 2, screen.Bottom - margin - (region.Bottom + margin), false);
        Consider(screen.Left + margin, screen.Top + margin,
            screen.Width - margin * 2, region.Top - margin - (screen.Top + margin), false);

        int xPos;
        int yPos;
        int width;
        int height;
        if (bestArea > 0)
        {
            width = bestW;
            height = bestH;
            if (beside)
            {
                xPos = bestX;
                yPos = Math.Max(screen.Top + margin, Math.Min(region.Top, screen.Bottom - height - margin));
            }
            else
            {
                yPos = bestY;
                xPos = Math.Max(screen.Left + margin, Math.Min(region.Left, screen.Right - width - margin));
            }
            var placed = new Gdi.Rectangle(xPos, yPos, width, height);
            if (placed.IntersectsWith(region))
            {
                xPos = bestX;
                yPos = bestY;
            }
        }
        else
        {
            width = Math.Min(desiredW, Math.Max(screen.Width / 5, minW));
            height = Math.Min(desiredH, Math.Max(screen.Height / 5, minH));
            xPos = screen.Left + margin;
            yPos = screen.Top + margin;
        }

        Width = Math.Max(160, width / scale);
        Height = Math.Max(120, height / scale);
        Platform.Native.PlaceTopmost(this, xPos, yPos, width, height);
    }

    private void OnPreview(BitmapSource image, int height)
    {
        _image.Source = image;
        _current = image;
        _status.Text = $"正在拼接… 当前高度 {height} px\n拖动页面或滚动滚轮即可继续，回车完成，Esc 取消。";
    }

    private void OnNotice(string text)
    {
        _status.Text = text;
    }

    private void OnFinished(BitmapSource? image, LongCaptureEnd reason)
    {
        _finished = true;
        _autoButton.IsEnabled = false;
        _saveButton.IsEnabled = image != null;

        if (image != null)
        {
            _image.Source = image;
            _current = image;
        }

        string why = reason switch
        {
            LongCaptureEnd.BottomReached => "已到页面底部",
            LongCaptureEnd.UserStop => "已停止",
            LongCaptureEnd.UserDone => "已完成",
            LongCaptureEnd.Misaligned => "页面变化太快，没能接上，已停止",
            LongCaptureEnd.LimitReached => "已达总高度上限，保留已拼接部分",
            LongCaptureEnd.ManualLimit => "已达手动高度上限，已停止",
            _ => "已停止"
        };
        _status.Text = image == null
            ? why
            : $"{why} · 最终高度 {image.PixelHeight} px\n回车复制，或点击保存。";
    }

    private void ToggleAuto()
    {
        if (_runner == null || _finished) return;
        _runner.ToggleAutoScroll();
        _autoButton.Content = _runner.IsAuto ? "停止滚动" : "自动滚动";
        _status.Text = _runner.IsAuto
            ? "正在自动向下滚动…按「停止滚动」回到手动。"
            : "手动模式：拖动页面或滚动滚轮，工具只追加新出现的行。";
    }

    private void FinishOrCopy()
    {
        if (_finished)
        {
            Copy();
            Close();
            return;
        }
        _runner?.RequestFinish();
        _status.Text = "正在结束…";
    }

    private void Copy()
    {
        if (_current == null) return;
        if (ClipboardHelper.SetImage(_current))
        {
            App.Current.Notify("长截图已复制", $"{_current.PixelWidth} × {_current.PixelHeight}");
        }
        else
        {
            MessageBox.Show(this, "剪切板被其他程序占用，请稍后再试。", "复制失败",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void Save()
    {
        if (_current == null) return;
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = "保存长截图",
            Filter = "PNG 图片 (*.png)|*.png",
            FileName = $"PinSnip-long-{DateTime.Now:yyyyMMdd-HHmmss}.png",
            AddExtension = true,
            DefaultExt = ".png"
        };
        if (dialog.ShowDialog(this) == true)
        {
            try
            {
                Imaging.SavePng(_current, dialog.FileName);
                App.Current.Notify("已保存", dialog.FileName);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "保存失败", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }
    }

    private void CancelSession()
    {
        _runner?.Abandon();
        Close();
    }

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        base.OnPreviewKeyDown(e);
        if (e.Key == Key.Enter)
        {
            FinishOrCopy();
            e.Handled = true;
        }
        else if (e.Key == Key.Escape)
        {
            CancelSession();
            e.Handled = true;
        }
    }
}
