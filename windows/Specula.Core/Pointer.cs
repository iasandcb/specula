namespace Specula;

public static class PointerButtons
{
    public const byte None = 0;
    public const byte Left = 1 << 0;
    public const byte Middle = 1 << 1;
    public const byte Right = 1 << 2;
    public const byte WheelUp = 1 << 3;
    public const byte WheelDown = 1 << 4;
    public const byte WheelLeft = 1 << 5;
    public const byte WheelRight = 1 << 6;
}

/// <summary>Letterboxed or filled image rectangle. Shared with the Swift pointer mapping.</summary>
public static class PointerMapping
{
    public readonly record struct Frame(double X, double Y, double Width, double Height)
    {
        public bool Contains(double x, double y) =>
            x >= X && y >= Y && x < X + Width && y < Y + Height;
    }

    public readonly record struct Point(int X, int Y);

    public static Frame? DisplayedFrame(double viewWidth, double viewHeight, double imageWidth, double imageHeight, bool fill)
    {
        if (viewWidth <= 0 || viewHeight <= 0 || imageWidth <= 0 || imageHeight <= 0) return null;
        if (!AllFinite(viewWidth, viewHeight, imageWidth, imageHeight)) return null;
        var scale = fill
            ? Math.Max(viewWidth / imageWidth, viewHeight / imageHeight)
            : Math.Min(viewWidth / imageWidth, viewHeight / imageHeight);
        if (!double.IsFinite(scale) || scale <= 0) return null;
        var width = imageWidth * scale;
        var height = imageHeight * scale;
        return new Frame((viewWidth - width) / 2, (viewHeight - height) / 2, width, height);
    }

    public static Point? FramebufferPoint(
        double viewX, double viewY, double viewWidth, double viewHeight,
        double imageWidth, double imageHeight, bool fill, bool clamp)
    {
        if (!double.IsFinite(viewX) || !double.IsFinite(viewY)) return null;
        var frame = DisplayedFrame(viewWidth, viewHeight, imageWidth, imageHeight, fill);
        if (frame is null) return null;
        if (!clamp && !frame.Value.Contains(viewX, viewY)) return null;
        var rawX = (viewX - frame.Value.X) / frame.Value.Width * imageWidth;
        var rawY = (viewY - frame.Value.Y) / frame.Value.Height * imageHeight;
        if (!double.IsFinite(rawX) || !double.IsFinite(rawY)) return null;
        rawX = Math.Min(Math.Max(rawX, 0), imageWidth - 1);
        rawY = Math.Min(Math.Max(rawY, 0), imageHeight - 1);
        return new Point((int)rawX, (int)rawY);
    }

    static bool AllFinite(params double[] values) => values.All(double.IsFinite);
}

/// <summary>Windows wheel deltas are 120 per detent. Positive Y is wheel-up, positive X is wheel-right.</summary>
public static class Wheel
{
    public const int DeltaPerClick = 120;
    public const int MaxClicks = 80;

    public static int Consume(ref int remainder, int delta)
    {
        var sum = (long)remainder + delta;
        var clicks = sum / DeltaPerClick;
        if (clicks > MaxClicks) clicks = MaxClicks;
        else if (clicks < -MaxClicks) clicks = -MaxClicks;
        var uncapped = sum / DeltaPerClick;
        remainder = Math.Abs(uncapped) > MaxClicks ? 0 : (int)(sum - clicks * DeltaPerClick);
        return (int)clicks;
    }

    public static byte[] Masks(int clicksX, int clicksY, byte held)
    {
        var masks = new List<byte>();
        if (clicksY > 0) Burst(PointerButtons.WheelUp, clicksY, held, masks);
        else if (clicksY < 0) Burst(PointerButtons.WheelDown, -clicksY, held, masks);
        if (clicksX > 0) Burst(PointerButtons.WheelRight, clicksX, held, masks);
        else if (clicksX < 0) Burst(PointerButtons.WheelLeft, -clicksX, held, masks);
        return masks.ToArray();
    }

    static void Burst(byte button, int count, byte held, List<byte> masks)
    {
        for (var i = 0; i < count; i++)
        {
            masks.Add((byte)(held | button));
            masks.Add(held);
        }
    }
}

/// <summary>Motion is limited to one sample per interval. Button changes, including wheel clicks, are immediate.</summary>
public sealed class PointerCoalescer
{
    public readonly record struct Sample(int X, int Y, byte Buttons);
    public readonly record struct Result(Sample[] Send, int? FlushAfterMs);

    public int IntervalMs { get; }
    Sample? _lastSent;
    Sample? _pending;
    int? _lastSentMs;

    public PointerCoalescer(int intervalMs = 16) => IntervalMs = Math.Max(1, intervalMs);

    public Result Submit(Sample sample, int nowMs)
    {
        if (_lastSent is null) return Commit(sample, nowMs);
        var previous = _pending?.Buttons ?? _lastSent.Value.Buttons;
        if (sample.Buttons != previous) return Commit(sample, nowMs);
        if (_pending is null && sample == _lastSent) return new Result(Array.Empty<Sample>(), null);
        _pending = sample;
        var due = (_lastSentMs ?? nowMs) + IntervalMs;
        if (nowMs >= due) return Commit(sample, nowMs);
        return new Result(Array.Empty<Sample>(), due - nowMs);
    }

    public Result Flush(int nowMs)
    {
        if (_pending is not Sample pending) return new Result(Array.Empty<Sample>(), null);
        var due = (_lastSentMs ?? nowMs) + IntervalMs;
        if (nowMs >= due) return Commit(pending, nowMs);
        return new Result(Array.Empty<Sample>(), due - nowMs);
    }

    Result Commit(Sample sample, int nowMs)
    {
        _pending = null;
        if (_lastSent == sample) return new Result(Array.Empty<Sample>(), null);
        _lastSent = sample;
        _lastSentMs = nowMs;
        return new Result(new[] { sample }, null);
    }
}
