using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Gdi = System.Drawing;

namespace PinSnip;

/// <summary>A screenshot pinned above other windows. It never takes keyboard
/// focus, can be dragged, zoomed with the wheel and closed with a double
/// click.</summary>
internal sealed class PinWindow : Window
{
    private const double MinimumZoom = 0.08;
    private const double MaximumZoom = 8.0;

    private readonly Gdi.Rectangle _screen;
    private readonly int _baseWidth;
    private readonly int _baseHeight;

    private double _zoom = 1.0;
    private int _left;
    private int _top;
    private int _width;
    private int _height;

    private bool _dragging;
    private bool _dragMoved;
    private bool _lastClickMoved;
    private DateTime _lastClick = DateTime.MinValue;
    private Platform.Native.POINT _dragStart;
    private int _dragWindowLeft;
    private int _dragWindowTop;

    public PinWindow(BitmapSource image, Gdi.Rectangle screen)
    {
        Image = image;
        _screen = screen;
        _baseWidth = Math.Max(1, image.PixelWidth);
        _baseHeight = Math.Max(1, image.PixelHeight);

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        WindowStartupLocation = WindowStartupLocation.Manual;
        UseLayoutRounding = true;

        var picture = new Image
        {
            Source = image,
            Stretch = Stretch.Fill,
            ToolTip = "拖动移动 · 滚轮缩放 · 点右上角 × 关闭 · 右键更多"
        };
        RenderOptions.SetBitmapScalingMode(picture, BitmapScalingMode.HighQuality);

        var close = new Button
        {
            Content = "×",
            Width = 22,
            Height = 22,
            FontSize = 14,
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 6, 6, 0),
            Background = new SolidColorBrush(Color.FromArgb(210, 28, 28, 30)),
            Foreground = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromArgb(180, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            Cursor = Cursors.Hand,
            ToolTip = "关闭贴图"
        };
        close.PreviewMouseLeftButtonDown += (_, args) =>
        {
            Close();
            args.Handled = true;
        };

        var body = new Grid
        {
            Background = Brushes.White,
            ToolTip = picture.ToolTip
        };
        body.Children.Add(picture);
        body.Children.Add(close);

        var frame = new Border
        {
            Background = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x60, 0, 0, 0)),
            BorderThickness = new Thickness(1),
            SnapsToDevicePixels = true,
            Child = body
        };
        Content = frame;

        double fit = Math.Min(
            screen.Width * 0.8 / _baseWidth,
            screen.Height * 0.8 / _baseHeight);
        _zoom = Math.Min(1.0, Math.Max(MinimumZoom, fit));

        SourceInitialized += (_, _) =>
        {
            Platform.Native.MakeNonActivating(this);
            Platform.Native.ExcludeFromCapture(this);
        };
        Loaded += (_, _) => ApplyInitialGeometry();
        Closed += (_, _) => PinManager?.OnPinClosed(this);
    }

    internal PinManager? PinManager { get; set; }

    public BitmapSource Image { get; }

    private void ApplyInitialGeometry()
    {
        int width = (int)Math.Round(_baseWidth * _zoom);
        int height = (int)Math.Round(_baseHeight * _zoom);
        int left = _screen.Left + (_screen.Width - width) / 2;
        int top = _screen.Top + (_screen.Height - height) / 2;
        _zoom = Math.Min(_zoom, MaximumZoom);
        SetGeometry(left, top, width, height);
    }

    private void SetGeometry(int left, int top, int width, int height)
    {
        _left = left;
        _top = top;
        _width = Math.Max(24, width);
        _height = Math.Max(24, height);
        IntPtr handle = Platform.Native.Handle(this);
        if (handle == IntPtr.Zero) return;
        Platform.Native.SetWindowPos(handle, Platform.Native.HWND_TOPMOST,
            _left, _top, _width, _height,
            Platform.Native.SWP_NOACTIVATE | Platform.Native.SWP_SHOWWINDOW);
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        if (e.OriginalSource is Button) return;

        DateTime now = DateTime.UtcNow;
        if (!_lastClickMoved && (e.ClickCount >= 2 || (now - _lastClick).TotalMilliseconds < 400))
        {
            Close();
            return;
        }
        _lastClick = now;
        _lastClickMoved = false;

        _dragging = true;
        _dragMoved = false;
        _dragStart = Platform.Native.CursorPosition();
        Platform.Native.RECT rect = Platform.Native.WindowRect(this);
        _dragWindowLeft = rect.Left;
        _dragWindowTop = rect.Top;
        CaptureMouse();
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (!_dragging) return;
        Platform.Native.POINT cursor = Platform.Native.CursorPosition();
        int dx = cursor.X - _dragStart.X;
        int dy = cursor.Y - _dragStart.Y;
        // A click that has not moved yet must stay put, or the second click
        // of a double-click lands beside the window and never closes it.
        if (!_dragMoved && dx * dx + dy * dy < 16) return;
        _dragMoved = true;
        SetGeometry(_dragWindowLeft + dx, _dragWindowTop + dy, _width, _height);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        _lastClickMoved = _dragMoved;
        _dragging = false;
        ReleaseMouseCapture();
    }

    protected override void OnMouseRightButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseRightButtonUp(e);
        var menu = new ContextMenu();
        menu.Items.Add(Item("关闭贴图", () => Close()));
        menu.Items.Add(Item("隐藏全部贴图", () => PinManager?.HideAll()));
        menu.Items.Add(Item("销毁全部贴图", () => PinManager?.DestroyAll()));
        menu.PlacementTarget = this;
        menu.Placement = PlacementMode.MousePoint;
        menu.IsOpen = true;
        e.Handled = true;
    }

    private static MenuItem Item(string title, Action action)
    {
        var item = new MenuItem { Header = title };
        item.Click += (_, _) => action();
        return item;
    }

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        base.OnMouseWheel(e);
        double factor = e.Delta > 0 ? 1.1 : 1 / 1.1;
        double zoom = Math.Max(MinimumZoom, Math.Min(MaximumZoom, _zoom * factor));
        if (Math.Abs(zoom - _zoom) < 0.0001) return;

        // Keep the window's centre fixed while it grows or shrinks.
        int centerX = _left + _width / 2;
        int centerY = _top + _height / 2;
        _zoom = zoom;
        int width = (int)Math.Round(_baseWidth * _zoom);
        int height = (int)Math.Round(_baseHeight * _zoom);
        SetGeometry(centerX - width / 2, centerY - height / 2, width, height);
        e.Handled = true;
    }
}
