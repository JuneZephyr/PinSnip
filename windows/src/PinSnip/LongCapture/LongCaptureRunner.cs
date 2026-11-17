using System;
using System.Threading;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Gdi = System.Drawing;

namespace PinSnip;

internal enum LongCaptureEnd
{
    BottomReached,
    UserStop,
    UserDone,
    Misaligned,
    LimitReached,
    ManualLimit
}

/// <summary>Watches a region and stitches the rows that scroll into view. The
/// first frame is the selection the user already made. Nothing is scrolled
/// until the preview's auto button is pressed; until then the page moves only
/// because the user moves it.</summary>
internal sealed class LongCaptureRunner
{
    private readonly Gdi.Rectangle _region;
    private readonly Gdi.Bitmap _seed;
    private readonly int _maxHeight;
    private readonly int _progressLimit;
    private readonly Dispatcher _dispatcher;
    private readonly object _gate = new();

    private volatile bool _auto;
    private volatile bool _stop;
    private volatile bool _finish;
    private volatile bool _finished;
    private volatile bool _abandoned;
    private bool _cleaned;

    private Gdi.Bitmap? _last;
    private int _noProgress;
    private DateTime _lastPreview = DateTime.MinValue;
    private DateTime _lastNotice = DateTime.MinValue;

    public LongCaptureRunner(Gdi.Rectangle region, Gdi.Bitmap seed, int maxHeight, int progressLimit)
    {
        _region = region;
        _seed = seed;
        _maxHeight = Math.Max(1, maxHeight);
        _progressLimit = Math.Max(0, progressLimit);
        _dispatcher = System.Windows.Application.Current.Dispatcher;
    }

    public event Action<BitmapSource, int>? Preview;
    public event Action<BitmapSource?, LongCaptureEnd>? Finished;
    public event Action<string>? Notice;

    public bool IsAuto => _auto;
    public bool IsFinished => _finished;

    public void Start()
    {
        var thread = new Thread(Run)
        {
            IsBackground = true,
            Name = "PinSnip long capture"
        };
        thread.Start();
    }

    public void BeginAutoScroll() => _auto = true;
    public void EndAutoScroll() => _auto = false;
    public void ToggleAutoScroll() => _auto = !_auto;
    public void RequestStop() => _stop = true;
    public void RequestFinish() => _finish = true;

    /// <summary>Throws the session away: no preview or finish will arrive
    /// afterwards.</summary>
    public void Abandon()
    {
        _abandoned = true;
        _stop = true;
        lock (_gate)
        {
            _finished = true;
        }
        Preview = null;
        Finished = null;
        Notice = null;
    }

    // MARK: - Loop

    private void Run()
    {
        try
        {
            Gdi.Bitmap first = _seed;
            if (first.Width < 1 || first.Height < 1)
            {
                Complete(null, LongCaptureEnd.Misaligned);
                return;
            }

            var buffer = new StitchBuffer(first.Width, Math.Min(first.Height, _maxHeight));
            buffer.AppendRows(first, Math.Min(first.Height, _maxHeight));
            _last = first;
            PublishPreview(buffer, force: true);

            while (!_stop && !_finish)
            {
                // Manual mode never decides the page has reached the bottom,
                // and a frame that does not line up is skipped instead of
                // ending the session. A video or blinking caret can look like
                // new content forever, so that path is capped at about twenty
                // selection heights.
                bool manualCap = !_auto && _progressLimit > 0;
                int ceiling = manualCap ? Math.Min(_maxHeight, _progressLimit) : _maxHeight;
                buffer.MaxHeight = ceiling;
                if (buffer.Height >= ceiling)
                {
                    Complete(buffer, manualCap && ceiling < _maxHeight
                        ? LongCaptureEnd.ManualLimit
                        : LongCaptureEnd.LimitReached);
                    return;
                }

                if (_auto)
                {
                    ScrollDown();
                    if (_stop || _finish) break;
                    Gdi.Bitmap? frame = WaitForStable();
                    if (frame == null)
                    {
                        Complete(buffer, LongCaptureEnd.Misaligned);
                        return;
                    }
                    if (!Append(frame, buffer, endWhenStill: true)) return;
                }
                else
                {
                    Gdi.Bitmap? frame = WaitForMovement();
                    if (frame == null) continue;
                    if (_stop || _finish || _auto) continue;
                    if (!Append(frame, buffer, endWhenStill: false)) return;
                }
            }

            Complete(buffer, _stop ? LongCaptureEnd.UserStop : LongCaptureEnd.UserDone);
        }
        catch (Exception ex)
        {
            App.Log($"long capture failed: {ex}");
            Complete(null, LongCaptureEnd.Misaligned);
        }
        finally
        {
            // Nothing is left to look at once the session is over or abandoned.
            Cleanup();
        }
    }

    /// <summary>Adds the newly revealed rows. Returns false when the session has
    /// ended. A row is appended only when the bottom of the previous frame is
    /// still inside the new one, which is what keeps the join continuous.</summary>
    private bool Append(Gdi.Bitmap frame, StitchBuffer buffer, bool endWhenStill)
    {
        if (_last == null)
        {
            frame.Dispose();
            return false;
        }

        FrameShift shift = Stitcher.Detect(_last, frame);
        if (!Continuous(shift, _last.Height))
        {
            frame.Dispose();
            if (endWhenStill)
            {
                Complete(buffer, LongCaptureEnd.Misaligned);
                return false;
            }
            ReportNotice("滚得太快，这一段没接上。慢一点滚，让上一屏还留在选区里");
            return true;
        }

        if (shift.Pixels < 4)
        {
            if (endWhenStill)
            {
                _noProgress++;
                if (_noProgress >= 2)
                {
                    frame.Dispose();
                    Complete(buffer, LongCaptureEnd.BottomReached);
                    return false;
                }
                _last.Dispose();
                _last = frame;
            }
            else
            {
                frame.Dispose();
            }
            return true;
        }

        _noProgress = 0;
        using (Gdi.Bitmap? strip = Stitcher.NewRows(frame, shift.Pixels))
        {
            if (strip == null)
            {
                frame.Dispose();
                if (endWhenStill)
                {
                    Complete(buffer, LongCaptureEnd.Misaligned);
                    return false;
                }
                return true;
            }
            buffer.AppendRows(strip, shift.Pixels);
        }

        _last.Dispose();
        _last = frame;
        PublishPreview(buffer, force: false);
        return true;
    }

    private static bool Continuous(FrameShift shift, int height)
    {
        if (shift.Quality > 18) return false;
        double ratio = shift.Pixels / (double)Math.Max(height, 1);
        if (ratio > 0.85) return false;
        if (ratio > 0.55 && shift.Quality > 6) return false;
        return true;
    }

    private Gdi.Bitmap? WaitForMovement()
    {
        while (!_stop && !_finish && !_auto)
        {
            Gdi.Bitmap? frame = CaptureRegion();
            if (frame == null)
            {
                Thread.Sleep(200);
                continue;
            }
            if (_last == null) return frame;
            if (Stitcher.Difference(_last, frame) >= 4)
            {
                Gdi.Bitmap? stable = WaitForStable();
                if (stable != null)
                {
                    frame.Dispose();
                    return stable;
                }
                return frame;
            }
            frame.Dispose();
            Thread.Sleep(180);
        }
        return null;
    }

    private Gdi.Bitmap? WaitForStable()
    {
        DateTime start = DateTime.UtcNow;
        DateTime deadline = start.AddSeconds(4);
        Gdi.Bitmap? last = null;
        int stableStreak = 0;

        while (DateTime.UtcNow < deadline)
        {
            if (_stop || _finish) return last;
            Gdi.Bitmap? frame = CaptureRegion();
            if (frame == null) return last;
            if (last != null)
            {
                stableStreak = Stitcher.Difference(last, frame) < 2.0 ? stableStreak + 1 : 0;
                last.Dispose();
            }
            last = frame;
            if (stableStreak >= 2 && (DateTime.UtcNow - start).TotalSeconds >= 0.15)
            {
                return last;
            }
            Thread.Sleep(40);
        }
        return last;
    }

    private void ScrollDown()
    {
        int centerX = _region.Left + _region.Width / 2;
        int centerY = _region.Top + _region.Height / 2;
        // A few notches, capped, so a tall selection actually moves without
        // jumping so far that the previous bottom leaves the frame.
        int notches = Math.Max(2, Math.Min(5, _region.Height / 180));
        Platform.Native.ScrollAt(centerX, centerY, -120 * notches);
    }

    private Gdi.Bitmap? CaptureRegion()
    {
        try
        {
            return ScreenCapture.Capture(_region);
        }
        catch
        {
            return null;
        }
    }

    // MARK: - Callbacks

    private void PublishPreview(StitchBuffer buffer, bool force)
    {
        DateTime now = DateTime.UtcNow;
        if (!force && (now - _lastPreview).TotalMilliseconds < 400) return;
        _lastPreview = now;

        Gdi.Bitmap bitmap;
        try
        {
            bitmap = buffer.ToBitmap();
        }
        catch
        {
            return;
        }
        BitmapSource source = Imaging.ToSource(bitmap);
        bitmap.Dispose();
        int height = buffer.Height;

        _dispatcher.BeginInvoke(new Action(() =>
        {
            if (_finished) return;
            Preview?.Invoke(source, height);
        }));
    }

    private void ReportNotice(string text)
    {
        DateTime now = DateTime.UtcNow;
        if ((now - _lastNotice).TotalSeconds < 1.2) return;
        _lastNotice = now;
        _dispatcher.BeginInvoke(new Action(() =>
        {
            if (_finished) return;
            Notice?.Invoke(text);
        }));
    }

    private bool TryMarkFinished()
    {
        lock (_gate)
        {
            if (_finished) return false;
            _finished = true;
            return true;
        }
    }

    private void Complete(StitchBuffer? buffer, LongCaptureEnd reason)
    {
        if (!TryMarkFinished()) return;

        Gdi.Bitmap? final = null;
        try
        {
            final = buffer?.ToBitmap();
        }
        catch
        {
            final = null;
        }
        BitmapSource? source = final != null ? Imaging.ToSource(final) : null;
        final?.Dispose();

        Cleanup();

        Action<BitmapSource?, LongCaptureEnd>? handler = Finished;
        if (handler == null) return;
        _dispatcher.BeginInvoke(new Action(() =>
        {
            if (_abandoned) return;
            handler(source, reason);
        }));
    }

    private void Cleanup()
    {
        // Complete and the loop's finally both call this. Disposing a GDI
        // bitmap twice throws and can take the process down with it.
        if (_cleaned) return;
        _cleaned = true;

        Gdi.Bitmap? last = _last;
        _last = null;
        last?.Dispose();
        if (!ReferenceEquals(_seed, last))
        {
            _seed.Dispose();
        }
    }
}
