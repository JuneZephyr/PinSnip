using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Gdi = System.Drawing;

namespace PinSnip;

/// <summary>The full-monitor overlay: frozen screenshot, region selection,
/// annotation toolbar and the commands that finish the capture.</summary>
internal sealed class SelectionWindow : Window
{
    private static readonly Color[] Inks =
    {
        Color.FromRgb(0xFF, 0x3B, 0x30),
        Color.FromRgb(0xFF, 0xD6, 0x0A),
        Color.FromRgb(0x0A, 0x84, 0xFF),
        Color.FromRgb(0x34, 0xC7, 0x59),
        Color.FromRgb(0xFF, 0xFF, 0xFF),
        Color.FromRgb(0x1C, 0x1C, 0x1E)
    };

    private readonly App _app;
    private readonly ScreenShot _shot;
    private readonly SelectionView _view;
    private readonly Canvas _barLayer;
    private readonly Border _toolbar;
    private readonly TextBlock _sizeText;
    private readonly Dictionary<MarkKind, Button> _toolButtons = new();
    private readonly Dictionary<Color, Button> _inkButtons = new();
    private readonly Button _longButton;
    private readonly Button _pinButton;
    private readonly Button _saveButton;
    private readonly Button _confirmButton;
    private readonly Button _undoButton;
    private TextBox? _textEditor;
    private Point _textPoint;
    private Mark? _editingText;
    private bool _disposed;

    public SelectionWindow(App app, ScreenShot shot)
    {
        _app = app;
        _shot = shot;

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Background = Brushes.Black;
        WindowStartupLocation = WindowStartupLocation.Manual;
        ShowActivated = true;
        // No layout rounding: the view must keep the exact fractional DIP size
        // of the monitor, otherwise a 150% screen crops a pixel off at the edge.
        UseLayoutRounding = false;
        SnapsToDevicePixels = true;

        double scale = Platform.Native.ScaleAt(
            shot.Bounds.Left + shot.Bounds.Width / 2,
            shot.Bounds.Top + shot.Bounds.Height / 2);
        Width = Math.Max(200, shot.Bounds.Width / Math.Max(0.5, scale));
        Height = Math.Max(200, shot.Bounds.Height / Math.Max(0.5, scale));

        _view = new SelectionView(shot.Bitmap, Imaging.ToSource(shot.Bitmap));
        _view.HorizontalAlignment = HorizontalAlignment.Stretch;
        _view.VerticalAlignment = VerticalAlignment.Stretch;
        _view.SelectionChanged += OnSelectionChanged;
        _view.ConfirmRequested += Confirm;
        _view.CancelRequested += _app.CloseOverlays;
        _view.TextRequested += AskForText;
        _view.Focusable = true;

        var grid = new Grid();
        grid.Children.Add(_view);

        _sizeText = new TextBlock
        {
            Foreground = Brushes.White,
            FontSize = 12,
            Margin = new Thickness(12, 8, 12, 8),
            VerticalAlignment = VerticalAlignment.Center
        };

        _toolbar = new Border
        {
            Background = new SolidColorBrush(Color.FromRgb(0x22, 0x22, 0x24)),
            BorderBrush = new SolidColorBrush(Color.FromRgb(0x44, 0x44, 0x48)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(6),
            Visibility = Visibility.Collapsed,
            Effect = new DropShadowEffect
            {
                BlurRadius = 16,
                ShadowDepth = 2,
                Opacity = 0.55,
                Color = Colors.Black
            }
        };

        var toolRow = new StackPanel { Orientation = Orientation.Horizontal };
        AddTool(toolRow, MarkKind.Rectangle, Glyphs.Rectangle(), "矩形");
        AddTool(toolRow, MarkKind.Ellipse, Glyphs.Ellipse(), "椭圆");
        AddTool(toolRow, MarkKind.Arrow, Glyphs.Arrow(), "箭头");
        AddTool(toolRow, MarkKind.Pen, Glyphs.Pen(), "画笔");
        AddTool(toolRow, MarkKind.Text, Glyphs.Text(), "文字");
        AddTool(toolRow, MarkKind.Mosaic, Glyphs.Mosaic(), "马赛克");

        toolRow.Children.Add(Separator());
        foreach (Color ink in Inks)
        {
            var swatch = new Button
            {
                Width = 18,
                Height = 18,
                Margin = new Thickness(2, 0, 2, 0),
                Background = new SolidColorBrush(ink),
                BorderBrush = Brushes.White,
                BorderThickness = new Thickness(1),
                ToolTip = "颜色"
            };
            swatch.Click += (_, _) => SetInk(ink);
            _inkButtons[ink] = swatch;
            toolRow.Children.Add(swatch);
        }

        toolRow.Children.Add(Separator());
        foreach ((string label, double width) in new[] { ("细", 2.0), ("中", 3.5), ("粗", 6.0) })
        {
            double value = width;
            Button button = ToolButton(label, "线条粗细", () => SetThickness(value));
            toolRow.Children.Add(button);
        }

        var actionRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 6, 0, 0)
        };

        _longButton = ToolButton("长截图", "拼接可滚动区域 (L)", StartLongCapture);
        _saveButton = ToolButton("保存", "保存为 PNG (Ctrl+S)", Save);
        _pinButton = ToolButton("贴图", "贴到屏幕上 (Ctrl+T)", Pin);
        _confirmButton = ToolButton("✓ 完成", "复制到剪切板 (Enter)", Confirm);
        _confirmButton.Background = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF));
        _undoButton = ToolButton("撤销", "撤销上一步 (Ctrl+Z)", UndoStep);
        _undoButton.IsEnabled = false;
        Button cancel = ToolButton("✗ 取消", "取消 (Esc)", _app.CloseOverlays);

        actionRow.Children.Add(_longButton);
        actionRow.Children.Add(_saveButton);
        actionRow.Children.Add(_pinButton);
        actionRow.Children.Add(new Border { Width = 10 });
        actionRow.Children.Add(_confirmButton);
        actionRow.Children.Add(_undoButton);
        actionRow.Children.Add(cancel);
        actionRow.Children.Add(_sizeText);

        var toolbarContent = new StackPanel();
        toolbarContent.Children.Add(toolRow);
        toolbarContent.Children.Add(actionRow);
        _toolbar.Child = toolbarContent;
        _toolbar.SizeChanged += (_, _) => PositionToolbar();
        _view.SizeChanged += (_, _) => PositionToolbar();

        // A canvas with no background is not hit-tested, so drags still reach
        // the frozen screen. The bar itself stays a child and keeps its clicks.
        _barLayer = new Canvas { IsHitTestVisible = true };
        _barLayer.Children.Add(_toolbar);
        grid.Children.Add(_barLayer);

        Content = grid;

        SetInk(Inks[0]);
        SetThickness(3.5);
        _view.HistoryChanged += () => _undoButton.IsEnabled = _view.CanUndo;

        Loaded += (_, _) =>
        {
            PlaceOnMonitor();
            Activate();
            _view.Focus();
            Keyboard.Focus(_view);
            // One more pass after layout: moving the window to a monitor with a
            // different scale can resize it through WM_DPICHANGED.
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background,
                new Action(PlaceOnMonitor));
        };
        DpiChanged += (_, _) => PlaceOnMonitor();
    }

    public ScreenShot Shot => _shot;

    private void PlaceOnMonitor()
    {
        Platform.Native.PlaceTopmost(this, _shot.Bounds.Left, _shot.Bounds.Top,
            _shot.Bounds.Width, _shot.Bounds.Height);
    }

    private static Button ToolButton(string text, string tip, Action click)
    {
        var button = new Button
        {
            Content = text,
            ToolTip = tip,
            MinWidth = 30,
            Height = 30,
            Margin = new Thickness(2, 0, 2, 0),
            Padding = new Thickness(7, 0, 7, 0),
            FontSize = 13,
            Background = new SolidColorBrush(Color.FromRgb(0x33, 0x33, 0x36)),
            Foreground = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromRgb(0x50, 0x50, 0x55)),
            BorderThickness = new Thickness(1)
        };
        button.Click += (_, _) => click();
        return button;
    }

    private static Border Separator()
    {
        return new Border
        {
            Width = 1,
            Height = 20,
            Margin = new Thickness(6, 5, 6, 5),
            Background = new SolidColorBrush(Color.FromRgb(0x55, 0x55, 0x5A))
        };
    }

    private void AddTool(Panel row, MarkKind kind, UIElement glyph, string tip)
    {
        Button button = IconButton(glyph, tip, () =>
        {
            _view.SetTool(_view.Tool == kind ? null : kind);
            RefreshToolButtons();
        });
        _toolButtons[kind] = button;
        row.Children.Add(button);
    }

    private static Button IconButton(UIElement glyph, string tip, Action click)
    {
        var button = new Button
        {
            Content = glyph,
            ToolTip = tip,
            Width = 30,
            Height = 30,
            Margin = new Thickness(2, 0, 2, 0),
            Padding = new Thickness(0),
            Background = new SolidColorBrush(Color.FromRgb(0x33, 0x33, 0x36)),
            BorderBrush = new SolidColorBrush(Color.FromRgb(0x50, 0x50, 0x55)),
            BorderThickness = new Thickness(1)
        };
        button.Click += (_, _) => click();
        return button;
    }

    private void RefreshToolButtons()
    {
        foreach ((MarkKind kind, Button button) in _toolButtons)
        {
            bool active = _view.Tool == kind;
            button.Background = new SolidColorBrush(active
                ? Color.FromRgb(0x0A, 0x84, 0xFF)
                : Color.FromRgb(0x33, 0x33, 0x36));
        }
    }

    private void SetInk(Color ink)
    {
        _view.Ink = ink;
        _view.RestyleSelected(ink, null);
        foreach ((Color color, Button button) in _inkButtons)
        {
            button.BorderThickness = new Thickness(color == ink ? 2 : 1);
            button.BorderBrush = new SolidColorBrush(color == ink ? Colors.White : Color.FromRgb(0x88, 0x88, 0x88));
        }
    }

    private void SetThickness(double width)
    {
        _view.InkThickness = width;
        _view.RestyleSelected(null, width);
    }

    private void OnSelectionChanged()
    {
        _toolbar.Visibility = _view.HasSelection ? Visibility.Visible : Visibility.Collapsed;
        PositionToolbar();
        UpdateSizeText();
        // The bar's height is only known after this visibility change has been
        // measured. A second pass keeps it from landing on the selection.
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, PositionToolbar);
    }

    private void UpdateSizeText()
    {
        if (!_view.HasSelection)
        {
            _sizeText.Text = "";
            return;
        }
        Gdi.Rectangle px = _view.SelectionPixels();
        _sizeText.Text = $"{px.Width} × {px.Height}";
    }

    private void PositionToolbar()
    {
        if (!_view.HasSelection || _barLayer.ActualWidth < 8 || _barLayer.ActualHeight < 8) return;
        _toolbar.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        double barWidth = Math.Max(_toolbar.DesiredSize.Width, _toolbar.ActualWidth);
        double barHeight = Math.Max(_toolbar.DesiredSize.Height, _toolbar.ActualHeight);
        if (barWidth < 1 || barHeight < 1) return;

        Rect selection = _view.Selection;
        // The bar lives in its own layer. Take the selection's corners in that
        // layer, so a resize cannot leave the bar sitting on the selection.
        Point topLeft = _view.TranslatePoint(new Point(selection.Left, selection.Top), _barLayer);
        Point bottomRight = _view.TranslatePoint(new Point(selection.Right, selection.Bottom), _barLayer);
        if (double.IsNaN(topLeft.Y) || double.IsNaN(bottomRight.Y)) return;

        double layerWidth = _barLayer.ActualWidth;
        double layerHeight = _barLayer.ActualHeight;
        const double gap = 12;
        const double edge = 8;

        double x = topLeft.X + (bottomRight.X - topLeft.X - barWidth) / 2.0;
        x = Math.Max(edge, Math.Min(x, Math.Max(edge, layerWidth - barWidth - edge)));

        double below = bottomRight.Y + gap;
        double above = topLeft.Y - gap - barHeight;
        bool belowFits = below >= edge && below + barHeight <= layerHeight - edge;
        bool aboveFits = above >= edge && above + barHeight <= layerHeight - edge;

        double y;
        if (belowFits)
        {
            y = below;
        }
        else if (aboveFits)
        {
            y = above;
        }
        else
        {
            // The selection is almost the whole screen. Use whichever margin
            // is larger so the bar covers as little of the selection as it can.
            double roomBelow = layerHeight - edge - bottomRight.Y;
            double roomAbove = topLeft.Y - edge;
            y = roomBelow >= roomAbove
                ? Math.Max(edge, layerHeight - barHeight - edge)
                : edge;
        }

        Canvas.SetLeft(_toolbar, x);
        Canvas.SetTop(_toolbar, y);
    }

    private void AskForText(Point point)
    {
        CommitText();
        Mark? existing = _view.TakeTextAt(point);
        Point anchor = existing is { Points.Count: > 0 } ? existing.Points[0] : point;
        Point origin = _view.TranslatePoint(anchor, _barLayer);
        if (double.IsNaN(origin.X) || double.IsNaN(origin.Y)) origin = anchor;

        Color color = existing?.Color ?? _view.Ink;
        double fontSize = existing?.FontSize ?? 18;
        var ink = new SolidColorBrush(color);
        var box = new TextBox
        {
            Text = existing?.Text ?? "",
            FontFamily = new FontFamily("Segoe UI, Microsoft YaHei UI"),
            FontSize = fontSize,
            Foreground = ink,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            CaretBrush = ink,
            Padding = new Thickness(0),
            MinWidth = 12,
            AcceptsReturn = false,
            AcceptsTab = false
        };
        Canvas.SetLeft(box, origin.X);
        Canvas.SetTop(box, origin.Y);
        box.TextChanged += (_, _) => SizeTextBox(box);
        box.LostFocus += (_, _) => CommitText();
        SizeTextBox(box);
        box.CaretIndex = box.Text.Length;

        _textPoint = anchor;
        _editingText = existing;
        _textEditor = box;
        _barLayer.Children.Add(box);
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Input, () =>
        {
            if (!ReferenceEquals(_textEditor, box)) return;
            box.Focus();
            Keyboard.Focus(box);
            box.CaretIndex = box.Text.Length;
        });
    }

    private static void SizeTextBox(TextBox box)
    {
        var text = new FormattedText(
            box.Text.Length == 0 ? " " : box.Text,
            System.Globalization.CultureInfo.CurrentUICulture,
            FlowDirection.LeftToRight,
            new Typeface(box.FontFamily, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal),
            box.FontSize,
            Brushes.White,
            1.0);
        box.Width = Math.Max(12, text.WidthIncludingTrailingWhitespace + 2);
    }

    private void CommitText()
    {
        TextBox? box = _textEditor;
        if (box == null) return;
        _textEditor = null;
        Mark? editing = _editingText;
        _editingText = null;
        _barLayer.Children.Remove(box);
        _view.AddText(_textPoint, box.Text, editing?.Color, editing?.FontSize);
    }

    private void CancelText()
    {
        TextBox? box = _textEditor;
        if (box == null) return;
        _textEditor = null;
        Mark? editing = _editingText;
        _editingText = null;
        _barLayer.Children.Remove(box);
        if (editing != null) _view.RestoreText(editing);
    }

    private void UndoStep()
    {
        CommitText();
        _view.Undo();
    }

    private void Confirm()
    {
        CommitText();
        if (!_view.HasSelection) return;
        BitmapSource image = _view.Render(includeAnnotations: true, out _);
        _app.CloseOverlays();
        _app.CopyToClipboard(image);
    }

    private void Pin()
    {
        CommitText();
        if (!_view.HasSelection) return;
        BitmapSource image = _view.Render(includeAnnotations: true, out _);
        Gdi.Rectangle screen = _shot.Bounds;
        _app.CloseOverlays();
        _app.PinImage(image, screen);
    }

    private void Save()
    {
        CommitText();
        if (!_view.HasSelection) return;
        BitmapSource image = _view.Render(includeAnnotations: true, out _);
        var dialog = new SaveFileDialog
        {
            Title = "保存截图",
            Filter = "PNG 图片 (*.png)|*.png",
            FileName = $"PinSnip-{DateTime.Now:yyyyMMdd-HHmmss}.png",
            AddExtension = true,
            DefaultExt = ".png"
        };
        if (dialog.ShowDialog(this) == true)
        {
            try
            {
                Imaging.SavePng(image, dialog.FileName);
                _app.Notify("已保存", dialog.FileName);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "保存失败", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }
        Activate();
        _view.Focus();
    }

    private void StartLongCapture()
    {
        CommitText();
        if (!_view.HasSelection) return;
        Gdi.Rectangle pixels = _view.SelectionPixels();
        var region = new Gdi.Rectangle(
            _shot.Bounds.Left + pixels.X,
            _shot.Bounds.Top + pixels.Y,
            pixels.Width,
            pixels.Height);
        Gdi.Bitmap seed = Imaging.Crop(_shot.Bitmap, pixels);
        Gdi.Rectangle screen = _shot.Bounds;
        _app.CloseOverlays();
        _app.StartLongCapture(region, seed, screen);
    }

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        base.OnPreviewKeyDown(e);
        if (_textEditor != null)
        {
            if (e.Key == Key.Enter)
            {
                CommitText();
                e.Handled = true;
            }
            else if (e.Key == Key.Escape)
            {
                CancelText();
                _view.Focus();
                e.Handled = true;
            }
            return;
        }

        switch (e.Key)
        {
            case Key.Escape:
                _app.CloseOverlays();
                e.Handled = true;
                break;
            case Key.Enter:
                Confirm();
                e.Handled = true;
                break;
            case Key.L:
                StartLongCapture();
                e.Handled = true;
                break;
            case Key.Z when Keyboard.Modifiers == ModifierKeys.Control:
                UndoStep();
                e.Handled = true;
                break;
            case Key.S when Keyboard.Modifiers == ModifierKeys.Control:
                Save();
                e.Handled = true;
                break;
            case Key.T when Keyboard.Modifiers == ModifierKeys.Control:
                Pin();
                e.Handled = true;
                break;
        }
    }

    protected override void OnClosed(EventArgs e)
    {
        base.OnClosed(e);
        if (_disposed) return;
        _disposed = true;
        _shot.Bitmap.Dispose();
    }
}

/// <summary>Toolbar marks drawn as shapes. The Unicode stand-ins (▭ ✎ ▦) are
/// missing from the Windows UI font, so those buttons were blank.</summary>
internal static class Glyphs
{
    public static UIElement Rectangle() => Stroke("M2,3 H14 V13 H2 Z");
    public static UIElement Ellipse() => Stroke("M8,3.2 A4.8,4.8 0 1 0 8,12.8 A4.8,4.8 0 1 0 8,3.2");
    public static UIElement Arrow() => Stroke("M3.5,12.5 L12.5,3.5 M12.5,3.5 H7.2 M12.5,3.5 V8.8");
    public static UIElement Pen() => Stroke("M3,13.5 L10.2,6.3 L12.2,8.3 L5,15.5 Z M10.2,6.3 L12.4,4.1 L14.4,6.1 L12.2,8.3");
    public static UIElement Undo() => Stroke("M6,8 H12.5 A3.5,3.5 0 1 1 9,14.2 M6,8 L9,5 M6,8 L9,11");

    public static UIElement Text()
    {
        return new TextBlock
        {
            Text = "A",
            Foreground = Brushes.White,
            FontSize = 15,
            FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
    }

    public static UIElement Mosaic()
    {
        var canvas = new Canvas { Width = 16, Height = 16 };
        AddBlock(canvas, 1, 1, 255);
        AddBlock(canvas, 9, 1, 150);
        AddBlock(canvas, 1, 9, 150);
        AddBlock(canvas, 9, 9, 255);
        return new Viewbox { Width = 16, Height = 16, Child = canvas };
    }

    private static void AddBlock(Canvas canvas, double x, double y, byte alpha)
    {
        var block = new System.Windows.Shapes.Rectangle
        {
            Width = 6,
            Height = 6,
            Fill = new SolidColorBrush(Color.FromArgb(alpha, 255, 255, 255))
        };
        Canvas.SetLeft(block, x);
        Canvas.SetTop(block, y);
        canvas.Children.Add(block);
    }

    private static Viewbox Stroke(string data)
    {
        return new Viewbox
        {
            Width = 16,
            Height = 16,
            Stretch = Stretch.Uniform,
            Child = new System.Windows.Shapes.Path
            {
                Data = Geometry.Parse(data),
                Stroke = Brushes.White,
                StrokeThickness = 1.4,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
                StrokeLineJoin = PenLineJoin.Round,
                Fill = Brushes.Transparent,
                Stretch = Stretch.Uniform
            }
        };
    }
}
