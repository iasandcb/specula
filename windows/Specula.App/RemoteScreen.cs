using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Specula;

/// <summary>
/// Draws the framebuffer in place. Replacing this element, or the menu beside it, on every frame
/// is what dismissed the ⋯ menu on the phone clients.
/// </summary>
public sealed class RemoteScreen : FrameworkElement
{
    WriteableBitmap? _bitmap;
    readonly PointerCoalescer _coalescer = new();
    readonly DispatcherTimer _flush;
    int _wheelX;
    int _wheelY;
    byte _buttons;
    int _lastX;
    int _lastY;
    bool _havePoint;

    public RemoteScreen()
    {
        Focusable = true;
        _flush = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        _flush.Tick += (_, _) =>
        {
            _flush.Stop();
            var result = _coalescer.Flush(Environment.TickCount);
            Deliver(result);
            Arm(result.FlushAfterMs);
        };
    }

    public bool Fill { get; set; }

    public event Action<int, int, byte>? Pointer;

    public int PixelWidth => _bitmap?.PixelWidth ?? 0;
    public int PixelHeight => _bitmap?.PixelHeight ?? 0;

    public void Present(int width, int height, byte[] rgba)
    {
        if (width <= 0 || height <= 0 || rgba.Length < width * height * 4) return;
        if (_bitmap == null || _bitmap.PixelWidth != width || _bitmap.PixelHeight != height)
            _bitmap = new WriteableBitmap(width, height, 96, 96, PixelFormats.Bgra32, null);
        _bitmap.Lock();
        try
        {
            unsafe
            {
                var destBase = (byte*)_bitmap.BackBuffer;
                var stride = _bitmap.BackBufferStride;
                fixed (byte* srcBase = rgba)
                {
                    for (var y = 0; y < height; y++)
                    {
                        var dest = destBase + y * stride;
                        var src = srcBase + y * width * 4;
                        for (var x = 0; x < width; x++)
                        {
                            dest[0] = src[2];
                            dest[1] = src[1];
                            dest[2] = src[0];
                            dest[3] = 255;
                            dest += 4;
                            src += 4;
                        }
                    }
                }
            }
            _bitmap.AddDirtyRect(new Int32Rect(0, 0, width, height));
        }
        finally
        {
            _bitmap.Unlock();
        }
        InvalidateVisual();
    }

    public void HorizontalWheel(int delta)
    {
        if (PixelWidth == 0) return;
        TurnWheel(Mouse.GetPosition(this), delta, 0);
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        drawingContext.DrawRectangle(Brushes.Black, null, new Rect(RenderSize));
        if (_bitmap == null) return;
        var frame = PointerMapping.DisplayedFrame(ActualWidth, ActualHeight, _bitmap.PixelWidth, _bitmap.PixelHeight, Fill);
        if (frame is null) return;
        drawingContext.DrawImage(_bitmap, new Rect(frame.Value.X, frame.Value.Y, frame.Value.Width, frame.Value.Height));
    }

    protected override HitTestResult HitTestCore(PointHitTestParameters hitTestParameters) =>
        new PointHitTestResult(this, hitTestParameters.HitPoint);

    protected override void OnMouseDown(MouseButtonEventArgs e)
    {
        Focus();
        var point = e.GetPosition(this);
        // A press in the letterbox is not a Mac click. A drag that later leaves the image is clamped.
        if (PointerMapping.FramebufferPoint(point.X, point.Y, ActualWidth, ActualHeight, PixelWidth, PixelHeight, Fill, clamp: false) is null)
        {
            e.Handled = true;
            return;
        }
        CaptureMouse();
        _buttons = Buttons();
        Move(point, clamp: true);
        e.Handled = true;
    }

    protected override void OnMouseUp(MouseButtonEventArgs e)
    {
        _buttons = Buttons();
        Move(e.GetPosition(this), clamp: _buttons != 0);
        if (_buttons == 0) ReleaseMouseCapture();
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (!IsMouseCaptured && e.LeftButton == MouseButtonState.Released &&
            e.RightButton == MouseButtonState.Released && e.MiddleButton == MouseButtonState.Released)
            _buttons = 0;
        Move(e.GetPosition(this), clamp: _buttons != 0);
        e.Handled = true;
    }

    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        if (_buttons != 0 && _havePoint)
        {
            _buttons = 0;
            Submit(_lastX, _lastY, 0);
        }
    }

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        TurnWheel(e.GetPosition(this), 0, e.Delta);
        e.Handled = true;
    }

    void TurnWheel(Point point, int deltaX, int deltaY)
    {
        var clicksX = Wheel.Consume(ref _wheelX, deltaX);
        var clicksY = Wheel.Consume(ref _wheelY, deltaY);
        var mapped = PointerMapping.FramebufferPoint(
            point.X, point.Y, ActualWidth, ActualHeight, PixelWidth, PixelHeight, Fill, clamp: true);
        if (mapped is not PointerMapping.Point at) return;
        foreach (var mask in Wheel.Masks(clicksX, clicksY, _buttons))
            Submit(at.X, at.Y, mask);
    }

    void Move(Point point, bool clamp)
    {
        var mapped = PointerMapping.FramebufferPoint(
            point.X, point.Y, ActualWidth, ActualHeight, PixelWidth, PixelHeight, Fill, clamp);
        if (mapped is not PointerMapping.Point at) return;
        _lastX = at.X;
        _lastY = at.Y;
        _havePoint = true;
        Submit(at.X, at.Y, _buttons);
    }

    byte Buttons()
    {
        byte mask = 0;
        if (Mouse.LeftButton == MouseButtonState.Pressed) mask |= PointerButtons.Left;
        if (Mouse.MiddleButton == MouseButtonState.Pressed) mask |= PointerButtons.Middle;
        if (Mouse.RightButton == MouseButtonState.Pressed) mask |= PointerButtons.Right;
        return mask;
    }

    void Submit(int x, int y, byte buttons)
    {
        var result = _coalescer.Submit(new PointerCoalescer.Sample(x, y, buttons), Environment.TickCount);
        Deliver(result);
        Arm(result.FlushAfterMs);
    }

    void Deliver(PointerCoalescer.Result result)
    {
        foreach (var sample in result.Send)
            Pointer?.Invoke(sample.X, sample.Y, sample.Buttons);
    }

    void Arm(int? milliseconds)
    {
        _flush.Stop();
        if (milliseconds is not int delay) return;
        _flush.Interval = TimeSpan.FromMilliseconds(Math.Max(1, delay));
        _flush.Start();
    }
}
