using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Media.Imaging;
using Gdi = System.Drawing;

namespace PinSnip;

/// <summary>Owns every pinned window: creation, hiding all of them before a
/// capture and destroying them on quit.</summary>
internal sealed class PinManager
{
    private readonly App _app;
    private readonly List<PinWindow> _pins = new();
    private bool _hidden;

    public PinManager(App app)
    {
        _app = app;
    }

    public int Count => _pins.Count;

    public void Add(BitmapSource image, Gdi.Rectangle? screen)
    {
        Gdi.Rectangle target = screen ?? ScreenCapture.ScreenAtCursor().WorkingArea;
        var pin = new PinWindow(image, target) { PinManager = this };
        _pins.Add(pin);
        if (_hidden)
        {
            _hidden = false;
        }
        pin.Show();
        _app.PinsChanged();
    }

    public void Close(PinWindow pin)
    {
        try
        {
            pin.Close();
        }
        catch
        {
        }
    }

    public void HideAll()
    {
        _hidden = true;
        foreach (PinWindow pin in _pins.ToList())
        {
            try
            {
                pin.Hide();
            }
            catch
            {
            }
        }
    }

    public void ToggleAll()
    {
        if (_pins.Count == 0)
        {
            _app.Notify("没有贴图", "按 F3 把剪切板里的图片或文字贴到屏幕上");
            return;
        }

        _hidden = !_hidden;
        foreach (PinWindow pin in _pins)
        {
            try
            {
                if (_hidden) pin.Hide();
                else pin.Show();
            }
            catch
            {
                // A pin closed while the list was being iterated.
            }
        }
    }

    public void DestroyAll()
    {
        var copy = _pins.ToList();
        _pins.Clear();
        foreach (PinWindow pin in copy)
        {
            pin.PinManager = null;
            try
            {
                pin.Close();
            }
            catch
            {
            }
        }
        _app.PinsChanged();
    }

    public void OnPinClosed(PinWindow pin)
    {
        _pins.Remove(pin);
        _app.PinsChanged();
    }

    /// <summary>Hides the pins for the instant a capture takes, so they can never
    /// appear in the frozen image.</summary>
    public IDisposable SuspendForCapture()
    {
        var visible = _pins.Where(pin => pin.IsVisible).ToList();
        foreach (PinWindow pin in visible)
        {
            try
            {
                pin.Hide();
            }
            catch
            {
            }
        }
        return new Restore(visible, _hidden);
    }

    private sealed class Restore : IDisposable
    {
        private readonly List<PinWindow> _pins;
        private readonly bool _staysHidden;

        public Restore(List<PinWindow> pins, bool staysHidden)
        {
            _pins = pins;
            _staysHidden = staysHidden;
        }

        public void Dispose()
        {
            if (_staysHidden) return;
            foreach (PinWindow pin in _pins)
            {
                try
                {
                    pin.Show();
                }
                catch
                {
                }
            }
        }
    }
}
