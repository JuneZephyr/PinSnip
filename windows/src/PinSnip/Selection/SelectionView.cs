using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Gdi = System.Drawing;

namespace PinSnip;

internal enum SelectionHandle
{
    None,
    TopLeft,
    Top,
    TopRight,
    Right,
    BottomRight,
    Bottom,
    BottomLeft,
    Left
}

/// <summary>The frozen screen, the drag that defines the region and all the
/// annotation drawing for one monitor.</summary>
internal sealed class SelectionView : FrameworkElement
{
    private enum Mode
    {
        Idle,
        Creating,
        Moving,
        Resizing,
        Drawing,
        MovingMark
    }

    private const double HandleSize = 8;
    private const double MinimumSelection = 4;

    private readonly Gdi.Bitmap _bitmap;
    private BitmapSource? _pixelatedView;
    private double _pixelatedForWidth;

    private Mode _mode = Mode.Idle;
    private SelectionHandle _handle = SelectionHandle.None;
    private Point _anchor;
    private Rect _selectionBeforeDrag;
    private int? _selectedMark;
    private Point[] _markStart = System.Array.Empty<Point>();
    private bool _markMoved;
    private readonly List<Mark[]> _history = new();
    private Mark[]? _pendingMove;
    private Mark[]? _pendingText;
    private Rect _selection;

    public SelectionView(Gdi.Bitmap bitmap, BitmapSource snapshot)
    {
        _bitmap = bitmap;
        Snapshot = snapshot;
        Focusable = true;
        FocusVisualStyle = null;
        Cursor = Cursors.Cross;
        ClipToBounds = true;
        RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.NearestNeighbor);
    }

    public BitmapSource Snapshot { get; }

    public Rect Selection
    {
        get => _selection;
        private set
        {
            if (_selection == value) return;
            _selection = value;
            // The border is drawn in OnRender. Changing the rect without
            // invalidating leaves the drag invisible: the region exists, but
            // nothing on screen shows it.
            InvalidateVisual();
            SelectionChanged?.Invoke();
        }
    }

    public bool HasSelection => Selection.Width >= 1 && Selection.Height >= 1;

    public List<Mark> Marks { get; } = new();

    public Mark? Draft { get; private set; }

    public MarkKind? Tool { get; set; }

    public Color Ink { get; set; } = Color.FromRgb(0xFF, 0x3B, 0x30);

    public double InkThickness { get; set; } = 3;

    public string Hint { get; set; } = "拖选区域 · 回车复制 · Esc 取消";

    public event Action? SelectionChanged;
    public event Action? ConfirmRequested;
    public event Action<Point>? TextRequested;
    public event Action? CancelRequested;
    public event Action? HistoryChanged;

    public bool CanUndo => _history.Count > 0;

    // The default measure is 0×0. A Grid then has nothing to show and nothing
    // to hit, so F1 looks like a blank screen that will not start a drag.
    protected override Size MeasureOverride(Size availableSize)
    {
        double width = double.IsInfinity(availableSize.Width) ? 0 : Math.Max(0, availableSize.Width);
        double height = double.IsInfinity(availableSize.Height) ? 0 : Math.Max(0, availableSize.Height);
        return new Size(width, height);
    }

    // A FrameworkElement with only OnRender content can lose the hit test to
    // the window behind it. The whole frozen screen must start a drag.
    protected override HitTestResult HitTestCore(PointHitTestParameters hitTestParameters)
    {
        return new PointHitTestResult(this, hitTestParameters.HitPoint);
    }

    // MARK: - Drawing

    protected override void OnRender(DrawingContext dc)
    {
        var bounds = new Rect(0, 0, ActualWidth, ActualHeight);
        dc.DrawImage(Snapshot, bounds);

        bool hasSelection = HasSelection && Selection.Width > 0 && Selection.Height > 0;
        var dimBrush = new SolidColorBrush(Color.FromArgb(90, 0, 0, 0));
        if (hasSelection)
        {
            var dim = new CombinedGeometry(
                GeometryCombineMode.Exclude,
                new RectangleGeometry(bounds),
                new RectangleGeometry(Selection));
            dc.DrawGeometry(dimBrush, null, dim);
        }
        else
        {
            dc.DrawRectangle(dimBrush, null, bounds);
        }

        if (hasSelection)
        {
            dc.PushClip(new RectangleGeometry(Selection));
            foreach (Mark mark in Marks)
            {
                MarkPainter.Draw(dc, mark, point => point, 1, bounds.Size, PixelatedForView());
            }
            if (Draft != null)
            {
                MarkPainter.Draw(dc, Draft, point => point, 1, bounds.Size, PixelatedForView());
            }
            dc.Pop();

            if (_selectedMark is int selected && selected >= 0 && selected < Marks.Count)
            {
                Rect halo = MarkBounds(Marks[selected]);
                halo.Inflate(3, 3);
                dc.DrawRectangle(null, new Pen(new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)), 1.5), halo);
            }

            // The border sits entirely outside the selection so it is never
            // part of the crop.
            var border = new Pen(new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)), 2);
            dc.DrawRectangle(null, border, new Rect(
                Selection.X - 1, Selection.Y - 1, Selection.Width + 2, Selection.Height + 2));
            DrawHandles(dc);
            DrawSizeLabel(dc);
        }

        if (!hasSelection && !string.IsNullOrEmpty(Hint))
        {
            DrawHint(dc, bounds);
        }
    }

    private BitmapSource? PixelatedForView()
    {
        if (ActualWidth <= 0) return null;
        if (_pixelatedView != null && Math.Abs(_pixelatedForWidth - ActualWidth) < 0.5) return _pixelatedView;
        _pixelatedForWidth = ActualWidth;
        int block = Math.Max(2, (int)Math.Round(12 * Snapshot.PixelWidth / ActualWidth));
        _pixelatedView = Imaging.Pixelate(Snapshot, block);
        return _pixelatedView;
    }

    private void DrawHandles(DrawingContext dc)
    {
        var fill = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF));
        var pen = new Pen(Brushes.White, 1);
        foreach (Point point in HandleCenters())
        {
            dc.DrawRectangle(fill, pen, new Rect(
                point.X - HandleSize / 2, point.Y - HandleSize / 2, HandleSize, HandleSize));
        }
    }

    private IEnumerable<Point> HandleCenters()
    {
        Rect s = Selection;
        yield return new Point(s.Left, s.Top);
        yield return new Point(s.Left + s.Width / 2, s.Top);
        yield return new Point(s.Right, s.Top);
        yield return new Point(s.Right, s.Top + s.Height / 2);
        yield return new Point(s.Right, s.Bottom);
        yield return new Point(s.Left + s.Width / 2, s.Bottom);
        yield return new Point(s.Left, s.Bottom);
        yield return new Point(s.Left, s.Top + s.Height / 2);
    }

    private void DrawSizeLabel(DrawingContext dc)
    {
        Rect s = Selection;
        int width = (int)Math.Round(s.Width * (Snapshot.PixelWidth / Math.Max(1, ActualWidth)));
        int height = (int)Math.Round(s.Height * (Snapshot.PixelHeight / Math.Max(1, ActualHeight)));
        var text = new FormattedText(
            $"{width} × {height}",
            System.Globalization.CultureInfo.CurrentUICulture,
            FlowDirection.LeftToRight,
            new Typeface("Segoe UI"),
            12,
            Brushes.White,
            1.0);

        var box = new Rect(s.Left, s.Top - text.Height - 10, text.Width + 12, text.Height + 6);
        if (box.Top < 0)
        {
            box = new Rect(s.Left, Math.Min(ActualHeight - box.Height, s.Bottom + 4), box.Width, box.Height);
        }
        dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(190, 0, 0, 0)), null, box, 4, 4);
        dc.DrawText(text, new Point(box.Left + 6, box.Top + 3));
    }

    private void DrawHint(DrawingContext dc, Rect bounds)
    {
        var text = new FormattedText(
            Hint,
            System.Globalization.CultureInfo.CurrentUICulture,
            FlowDirection.LeftToRight,
            new Typeface("Segoe UI, Microsoft YaHei UI"),
            14,
            Brushes.White,
            1.0);
        double padding = 10;
        var box = new Rect(
            bounds.Width / 2 - text.Width / 2 - padding,
            bounds.Height / 2 - text.Height / 2 - padding,
            text.Width + padding * 2,
            text.Height + padding * 2);
        dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(190, 0, 0, 0)), null, box, 6, 6);
        dc.DrawText(text, new Point(box.Left + padding, box.Top + padding));
    }

    // MARK: - Mouse

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        Focus();
        Point point = e.GetPosition(this);

        if (HasSelection && Tool == null && e.ClickCount >= 2 && Selection.Contains(point))
        {
            ConfirmRequested?.Invoke();
            return;
        }

        if (HasSelection && Selection.Contains(point) && HitMark(point) is int markIndex)
        {
            BeginMovingMark(markIndex, point);
            return;
        }

        if (Tool is MarkKind kind && HasSelection)
        {
            _selectedMark = null;
            if (!Selection.Contains(point))
            {
                BeginCreating(point);
                return;
            }
            if (kind == MarkKind.Text)
            {
                TextRequested?.Invoke(point);
                return;
            }
            Draft = new Mark(kind) { Color = Ink, Thickness = InkThickness };
            Draft.Points.Add(point);
            if (kind != MarkKind.Pen)
            {
                Draft.Points.Add(point);
            }
            _mode = Mode.Drawing;
            CaptureMouse();
            InvalidateVisual();
            return;
        }

        if (HasSelection)
        {
            SelectionHandle handle = HitHandle(point);
            if (handle != SelectionHandle.None)
            {
                _handle = handle;
                _selectionBeforeDrag = Selection;
                _mode = Mode.Resizing;
                CaptureMouse();
                return;
            }
            if (Selection.Contains(point))
            {
                _mode = Mode.Moving;
                _anchor = point;
                _selectionBeforeDrag = Selection;
                CaptureMouse();
                return;
            }
        }

        BeginCreating(point);
    }

    private void BeginCreating(Point point)
    {
        _mode = Mode.Creating;
        _anchor = point;
        Marks.Clear();
        Draft = null;
        _selectedMark = null;
        ClearHistory();
        Selection = new Rect(0, 0, 0, 0);
        Selection = new Rect(point, point);
        CaptureMouse();
        InvalidateVisual();
        SelectionChanged?.Invoke();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        Point point = e.GetPosition(this);

        switch (_mode)
        {
            case Mode.Creating:
                Selection = Clamp(RectFrom(_anchor, point));
                break;

            case Mode.Moving:
            {
                double x = _selectionBeforeDrag.X + (point.X - _anchor.X);
                double y = _selectionBeforeDrag.Y + (point.Y - _anchor.Y);
                x = Math.Max(0, Math.Min(x, ActualWidth - _selectionBeforeDrag.Width));
                y = Math.Max(0, Math.Min(y, ActualHeight - _selectionBeforeDrag.Height));
                Selection = new Rect(x, y, _selectionBeforeDrag.Width, _selectionBeforeDrag.Height);
                break;
            }

            case Mode.Resizing:
                Selection = Clamp(Resize(_selectionBeforeDrag, _handle, point));
                break;

            case Mode.MovingMark:
                MoveSelectedMark(point);
                break;

            case Mode.Drawing:
                if (Draft != null)
                {
                    if (Draft.Kind == MarkKind.Pen)
                    {
                        if (Distance(Draft.Points[^1], point) >= 2)
                        {
                            Draft.Points.Add(point);
                        }
                    }
                    else if (Draft.Points.Count >= 2)
                    {
                        Draft.Points[1] = point;
                    }
                    InvalidateVisual();
                }
                break;

            case Mode.Idle:
                UpdateCursor(point);
                break;
        }
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        ReleaseMouseCapture();

        switch (_mode)
        {
            case Mode.Creating:
                if (Selection.Width < MinimumSelection || Selection.Height < MinimumSelection)
                {
                    Selection = new Rect(0, 0, 0, 0);
                }
                SelectionChanged?.Invoke();
                break;

            case Mode.MovingMark:
                if (_markMoved && _pendingMove != null)
                {
                    AcceptHistory(_pendingMove);
                }
                _pendingMove = null;
                if (!_markMoved && _selectedMark is int index && index < Marks.Count && Marks[index].Kind == MarkKind.Text)
                {
                    TextRequested?.Invoke(_anchor);
                }
                break;

            case Mode.Drawing:
                if (Draft != null && IsValid(Draft))
                {
                    Remember();
                    Marks.Add(Draft);
                    _selectedMark = Marks.Count - 1;
                }
                Draft = null;
                InvalidateVisual();
                break;
        }

        _mode = Mode.Idle;
        _handle = SelectionHandle.None;
    }

    protected override void OnMouseRightButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseRightButtonDown(e);
        CancelRequested?.Invoke();
    }

    private void UpdateCursor(Point point)
    {
        if (!HasSelection || Tool != null)
        {
            Cursor = Tool == MarkKind.Text && HasSelection && Selection.Contains(point) ? Cursors.IBeam : Cursors.Cross;
            return;
        }
        SelectionHandle handle = HitHandle(point);
        Cursor = handle switch
        {
            SelectionHandle.TopLeft or SelectionHandle.BottomRight => Cursors.SizeNWSE,
            SelectionHandle.TopRight or SelectionHandle.BottomLeft => Cursors.SizeNESW,
            SelectionHandle.Top or SelectionHandle.Bottom => Cursors.SizeNS,
            SelectionHandle.Left or SelectionHandle.Right => Cursors.SizeWE,
            _ => Selection.Contains(point) ? Cursors.SizeAll : Cursors.Cross
        };
    }

    private SelectionHandle HitHandle(Point point)
    {
        SelectionHandle[] order =
        {
            SelectionHandle.TopLeft, SelectionHandle.Top, SelectionHandle.TopRight,
            SelectionHandle.Right, SelectionHandle.BottomRight, SelectionHandle.Bottom,
            SelectionHandle.BottomLeft, SelectionHandle.Left
        };
        int index = 0;
        foreach (Point center in HandleCenters())
        {
            if (Math.Abs(point.X - center.X) <= HandleSize && Math.Abs(point.Y - center.Y) <= HandleSize)
            {
                return order[index];
            }
            index++;
        }
        return SelectionHandle.None;
    }

    private static Rect Resize(Rect start, SelectionHandle handle, Point point)
    {
        double left = start.Left;
        double top = start.Top;
        double right = start.Right;
        double bottom = start.Bottom;

        switch (handle)
        {
            case SelectionHandle.TopLeft:
                left = point.X; top = point.Y; break;
            case SelectionHandle.Top:
                top = point.Y; break;
            case SelectionHandle.TopRight:
                right = point.X; top = point.Y; break;
            case SelectionHandle.Right:
                right = point.X; break;
            case SelectionHandle.BottomRight:
                right = point.X; bottom = point.Y; break;
            case SelectionHandle.Bottom:
                bottom = point.Y; break;
            case SelectionHandle.BottomLeft:
                left = point.X; bottom = point.Y; break;
            case SelectionHandle.Left:
                left = point.X; break;
        }

        return new Rect(
            Math.Min(left, right),
            Math.Min(top, bottom),
            Math.Abs(right - left),
            Math.Abs(bottom - top));
    }

    private Rect Clamp(Rect rect)
    {
        double left = Math.Max(0, Math.Min(rect.Left, ActualWidth));
        double top = Math.Max(0, Math.Min(rect.Top, ActualHeight));
        double right = Math.Max(0, Math.Min(rect.Right, ActualWidth));
        double bottom = Math.Max(0, Math.Min(rect.Bottom, ActualHeight));
        return new Rect(left, top, Math.Max(0, right - left), Math.Max(0, bottom - top));
    }

    private static Rect RectFrom(Point a, Point b)
    {
        return new Rect(
            Math.Min(a.X, b.X),
            Math.Min(a.Y, b.Y),
            Math.Abs(a.X - b.X),
            Math.Abs(a.Y - b.Y));
    }

    private static double Distance(Point a, Point b)
    {
        return Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));
    }

    private static bool IsValid(Mark mark)
    {
        if (mark.Kind == MarkKind.Pen) return mark.Points.Count >= 2;
        if (mark.Points.Count < 2) return false;
        Rect box = MarkPainter.Normalize(mark.Points[0], mark.Points[1]);
        return box.Width >= 2 || box.Height >= 2;
    }

    // MARK: - Annotation editing

    public void Undo()
    {
        if (_history.Count == 0) return;
        Mark[] previous = _history[_history.Count - 1];
        _history.RemoveAt(_history.Count - 1);
        Marks.Clear();
        Marks.AddRange(previous);
        _selectedMark = null;
        _pendingMove = null;
        _pendingText = null;
        Draft = null;
        InvalidateVisual();
        HistoryChanged?.Invoke();
    }

    /// <summary>Removes the text under the point so it can be edited in place.
    /// The caller puts it back with <see cref="AddText"/> or
    /// <see cref="RestoreText"/>.</summary>
    public Mark? TakeTextAt(Point point)
    {
        for (int index = Marks.Count - 1; index >= 0; index--)
        {
            Mark mark = Marks[index];
            if (mark.Kind != MarkKind.Text || mark.Points.Count == 0) continue;
            if (!MarkPainter.TextBounds(mark).Contains(point)) continue;
            _pendingText = CopyMarks();
            if (_selectedMark == index) _selectedMark = null;
            else if (_selectedMark is int selected && selected > index) _selectedMark = selected - 1;
            Marks.RemoveAt(index);
            InvalidateVisual();
            return mark;
        }
        return null;
    }

    public void RestoreText(Mark mark)
    {
        _pendingText = null;
        Marks.Add(mark);
        InvalidateVisual();
    }

    public void RestyleSelected(Color? color, double? thickness)
    {
        if (_selectedMark is not int index || index < 0 || index >= Marks.Count) return;
        Mark mark = Marks[index];
        bool colorChanges = color is Color ink && mark.Color != ink;
        bool widthChanges = thickness is double width && mark.Kind != MarkKind.Text && Math.Abs(mark.Thickness - width) > 0.01;
        if (!colorChanges && !widthChanges) return;
        Remember();
        if (color is Color next) mark.Color = next;
        if (thickness is double nextWidth && mark.Kind != MarkKind.Text) mark.Thickness = nextWidth;
        InvalidateVisual();
    }

    public void AddText(Point point, string text, Color? color = null, double? fontSize = null)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            if (_pendingText != null)
            {
                AcceptHistory(_pendingText);
                _pendingText = null;
            }
            InvalidateVisual();
            return;
        }
        if (_pendingText != null)
        {
            AcceptHistory(_pendingText);
            _pendingText = null;
        }
        else
        {
            Remember();
        }
        var mark = new Mark(MarkKind.Text)
        {
            Color = color ?? Ink,
            FontSize = fontSize ?? 18,
            Text = text
        };
        mark.Points.Add(point);
        Marks.Add(mark);
        _selectedMark = Marks.Count - 1;
        InvalidateVisual();
    }

    private void BeginMovingMark(int index, Point point)
    {
        _selectedMark = index;
        _pendingMove = CopyMarks();
        _anchor = point;
        _markMoved = false;
        _markStart = Marks[index].Points.ToArray();
        _mode = Mode.MovingMark;
        CaptureMouse();
        InvalidateVisual();
    }

    private void MoveSelectedMark(Point point)
    {
        if (_selectedMark is not int index || index < 0 || index >= Marks.Count) return;
        double dx = point.X - _anchor.X;
        double dy = point.Y - _anchor.Y;
        if (dx * dx + dy * dy > 4) _markMoved = true;
        Mark mark = Marks[index];
        int count = Math.Min(_markStart.Length, mark.Points.Count);
        for (int i = 0; i < count; i++)
        {
            mark.Points[i] = new Point(_markStart[i].X + dx, _markStart[i].Y + dy);
        }
        InvalidateVisual();
    }

    private int? HitMark(Point point)
    {
        for (int index = Marks.Count - 1; index >= 0; index--)
        {
            if (Hits(Marks[index], point)) return index;
        }
        return null;
    }

    private static bool Hits(Mark mark, Point point)
    {
        switch (mark.Kind)
        {
            case MarkKind.Text:
                return MarkPainter.TextBounds(mark).Contains(point);
            case MarkKind.Arrow:
            case MarkKind.Pen:
                return NearStroke(mark, point, 8);
            case MarkKind.Rectangle:
            case MarkKind.Ellipse:
                if (mark.Points.Count < 2) return false;
                Rect box = MarkPainter.Normalize(mark.Points[0], mark.Points[1]);
                box.Inflate(8, 8);
                return box.Contains(point);
            default:
                return false;
        }
    }

    private static bool NearStroke(Mark mark, Point point, double reach)
    {
        if (mark.Points.Count == 0) return false;
        if (mark.Points.Count == 1)
        {
            return Distance(mark.Points[0], point) <= reach + mark.Thickness;
        }
        for (int i = 1; i < mark.Points.Count; i++)
        {
            if (SegmentDistance(mark.Points[i - 1], mark.Points[i], point) <= reach + mark.Thickness)
            {
                return true;
            }
        }
        return false;
    }

    private static double SegmentDistance(Point from, Point to, Point point)
    {
        double dx = to.X - from.X;
        double dy = to.Y - from.Y;
        double length = dx * dx + dy * dy;
        if (length < 1) return Distance(from, point);
        double t = Math.Max(0, Math.Min(1, ((point.X - from.X) * dx + (point.Y - from.Y) * dy) / length));
        return Distance(new Point(from.X + t * dx, from.Y + t * dy), point);
    }

    private void Remember()
    {
        AcceptHistory(CopyMarks());
    }

    private void AcceptHistory(Mark[] snapshot)
    {
        _history.Add(snapshot);
        if (_history.Count > 40) _history.RemoveAt(0);
        HistoryChanged?.Invoke();
    }

    private void ClearHistory()
    {
        _history.Clear();
        _pendingMove = null;
        _pendingText = null;
        HistoryChanged?.Invoke();
    }

    private Mark[] CopyMarks()
    {
        var copy = new Mark[Marks.Count];
        for (int i = 0; i < Marks.Count; i++) copy[i] = Clone(Marks[i]);
        return copy;
    }

    private static Mark Clone(Mark mark)
    {
        var copy = new Mark(mark.Kind)
        {
            Color = mark.Color,
            Thickness = mark.Thickness,
            Text = mark.Text,
            FontSize = mark.FontSize,
            BlockSize = mark.BlockSize
        };
        copy.Points.AddRange(mark.Points);
        return copy;
    }

    private static Rect MarkBounds(Mark mark)
    {
        if (mark.Kind == MarkKind.Text) return MarkPainter.TextBounds(mark);
        if (mark.Points.Count == 0) return Rect.Empty;
        double left = mark.Points[0].X;
        double top = mark.Points[0].Y;
        double right = left;
        double bottom = top;
        foreach (Point point in mark.Points)
        {
            left = Math.Min(left, point.X);
            top = Math.Min(top, point.Y);
            right = Math.Max(right, point.X);
            bottom = Math.Max(bottom, point.Y);
        }
        return new Rect(left, top, Math.Max(1, right - left), Math.Max(1, bottom - top));
    }

    public void SetTool(MarkKind? tool)
    {
        Tool = tool;
        Draft = null;
        InvalidateVisual();
    }

    public void SetSelection(Rect rect)
    {
        Selection = Clamp(rect);
        InvalidateVisual();
    }

    public void ClearSelection()
    {
        Selection = new Rect(0, 0, 0, 0);
        Marks.Clear();
        Draft = null;
        _selectedMark = null;
        ClearHistory();
        InvalidateVisual();
    }

    // MARK: - Result

    public Gdi.Rectangle SelectionPixels()
    {
        double scaleX = Snapshot.PixelWidth / Math.Max(1, ActualWidth);
        double scaleY = Snapshot.PixelHeight / Math.Max(1, ActualHeight);
        int x = (int)Math.Floor(Selection.X * scaleX);
        int y = (int)Math.Floor(Selection.Y * scaleY);
        int width = (int)Math.Ceiling(Selection.Width * scaleX);
        int height = (int)Math.Ceiling(Selection.Height * scaleY);
        int left = Math.Min(Math.Max(0, x), Math.Max(0, _bitmap.Width - 1));
        int top = Math.Min(Math.Max(0, y), Math.Max(0, _bitmap.Height - 1));
        int pixelWidth = Math.Min(Math.Max(1, width), _bitmap.Width - left);
        int pixelHeight = Math.Min(Math.Max(1, height), _bitmap.Height - top);
        return new Gdi.Rectangle(left, top, Math.Max(1, pixelWidth), Math.Max(1, pixelHeight));
    }

    public Gdi.Bitmap CropSelection()
    {
        return Imaging.Crop(_bitmap, SelectionPixels());
    }

    public BitmapSource Render(bool includeAnnotations, out Gdi.Size pixelSize)
    {
        Gdi.Rectangle rect = SelectionPixels();
        pixelSize = new Gdi.Size(rect.Width, rect.Height);
        using Gdi.Bitmap crop = Imaging.Crop(_bitmap, rect);
        if (!includeAnnotations || Marks.Count == 0)
        {
            return Imaging.ToSource(crop);
        }
        return AnnotationRenderer.Render(crop, Marks, Snapshot.PixelWidth / Math.Max(1, ActualWidth),
            Snapshot.PixelHeight / Math.Max(1, ActualHeight), rect);
    }

    protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo)
    {
        base.OnRenderSizeChanged(sizeInfo);
        _pixelatedView = null;
        InvalidateVisual();
    }
}
