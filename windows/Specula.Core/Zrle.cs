using ICSharpCode.SharpZipLib.Zip.Compression;

namespace Specula;

/// <summary>
/// One zlib stream and one palette for a connection. macOS Screen Sharing reuses palettes
/// (subencodings 127 and 129) across tiles and rectangles; RFC 6143 does not.
/// </summary>
public sealed class Zrle
{
    readonly Inflater _inflater = new(false);
    byte[][] _palette = Array.Empty<byte[]>();

    public byte[] Inflate(byte[] bytes, int cap)
    {
        if (!_inflater.IsNeedingInput)
            throw new ProtocolException("압축 스트림이 맞지 않습니다.");
        _inflater.SetInput(bytes);
        using var output = new MemoryStream();
        var buffer = new byte[16384];
        while (!_inflater.IsFinished)
        {
            int read;
            try
            {
                read = _inflater.Inflate(buffer);
            }
            catch (Exception ex)
            {
                throw new ProtocolException("화면 압축을 풀지 못했습니다.", ex);
            }
            if ((long)output.Length + read > cap)
                throw new ProtocolException("화면 압축 크기가 잘못되었습니다.");
            if (read > 0)
            {
                output.Write(buffer, 0, read);
                continue;
            }
            // IsNeedingInput means the byte window is empty. Bits kept for the next symbol stay
            // in SharpZipLib's bit buffer and are not "remaining input".
            if (_inflater.IsNeedingInput || _inflater.IsFinished) break;
            throw new ProtocolException("화면 압축을 풀지 못했습니다.");
        }
        if (!_inflater.IsNeedingInput)
            throw new ProtocolException("화면 압축 데이터가 남았습니다.");
        return output.ToArray();
    }

    public byte[] Compressed(int w, int h, byte[] bytes)
    {
        if (bytes.Length < 1 || bytes.Length > FrameLimits.Compressed(w, h))
            throw new ProtocolException("화면 압축 크기가 잘못되었습니다.");
        return Decode(w, h, Inflate(bytes, FrameLimits.Plain(w, h)));
    }

    public byte[] Decode(int w, int h, byte[] bytes)
    {
        FrameLimits.Check(w, h);
        var input = new Cursor(bytes);
        var pixels = new byte[w * h * 4];
        for (var ty = 0; ty < h; ty += 64)
        for (var tx = 0; tx < w; tx += 64)
        {
            var tw = Math.Min(64, w - tx);
            var th = Math.Min(64, h - ty);
            var count = tw * th;
            var sub = input.U8();
            if (sub == 0)
            {
                for (var i = 0; i < count; i++) Paint(pixels, w, tx, ty, tw, i, input.Pixel());
            }
            else if (sub == 1)
            {
                var solid = input.Pixel();
                for (var i = 0; i < count; i++) Paint(pixels, w, tx, ty, tw, i, solid);
            }
            else if (sub is >= 2 and <= 16 || sub == 127)
            {
                if (sub != 127) _palette = ReadPalette(input, sub);
                if (_palette.Length is < 2 or > 16)
                    throw new ProtocolException("재사용할 ZRLE 팔레트가 없습니다.");
                var bits = _palette.Length <= 2 ? 1 : _palette.Length <= 4 ? 2 : 4;
                for (var row = 0; row < th; row++)
                {
                    var left = 0;
                    var value = 0;
                    for (var col = 0; col < tw; col++)
                    {
                        if (left < bits)
                        {
                            value = input.U8();
                            left = 8;
                        }
                        left -= bits;
                        var index = (value >> left) & ((1 << bits) - 1);
                        if (index >= _palette.Length)
                            throw new ProtocolException("화면 압축 팔레트가 잘못되었습니다.");
                        Paint(pixels, w, tx, ty, tw, row * tw + col, _palette[index]);
                    }
                }
            }
            else if (sub >= 128)
            {
                if (sub >= 130) _palette = ReadPalette(input, sub - 128);
                if (sub != 128 && _palette.Length == 0)
                    throw new ProtocolException("재사용할 ZRLE 팔레트가 없습니다.");
                var written = 0;
                while (written < count)
                {
                    byte[] color;
                    int run;
                    if (sub == 128)
                    {
                        color = input.Pixel();
                        run = input.Run(count - written);
                    }
                    else
                    {
                        var marker = input.U8();
                        var index = marker & 127;
                        if (index >= _palette.Length)
                            throw new ProtocolException("화면 압축 팔레트가 잘못되었습니다.");
                        color = _palette[index];
                        run = marker < 128 ? 1 : input.Run(count - written);
                    }
                    for (var i = 0; i < run; i++) Paint(pixels, w, tx, ty, tw, written + i, color);
                    written += run;
                }
            }
            else throw new ProtocolException($"지원하지 않는 ZRLE 타일입니다: {sub}");
        }
        if (!input.Exhausted) throw new ProtocolException("화면 압축 데이터가 남았습니다.");
        return pixels;
    }

    static byte[][] ReadPalette(Cursor input, int count)
    {
        var palette = new byte[count][];
        for (var i = 0; i < count; i++) palette[i] = input.Pixel();
        return palette;
    }

    static void Paint(byte[] pixels, int frameWidth, int tx, int ty, int tw, int index, byte[] color)
    {
        var at = ((ty + index / tw) * frameWidth + tx + index % tw) * 4;
        color.CopyTo(pixels, at);
        pixels[at + 3] = 255;
    }

    sealed class Cursor
    {
        readonly byte[] _data;
        int _pos;

        public Cursor(byte[] data) => _data = data;

        public bool Exhausted => _pos == _data.Length;

        public int U8()
        {
            if (_pos >= _data.Length) throw new ProtocolException("화면 데이터가 잘못되었습니다.");
            return _data[_pos++];
        }

        public byte[] Pixel()
        {
            if (_pos + 3 > _data.Length) throw new ProtocolException("화면 데이터가 잘못되었습니다.");
            var pixel = new byte[3];
            Buffer.BlockCopy(_data, _pos, pixel, 0, 3);
            _pos += 3;
            return pixel;
        }

        public int Run(int limit)
        {
            var n = 1;
            while (true)
            {
                var b = U8();
                if (n > limit - b) throw new ProtocolException("화면 압축의 반복 길이가 잘못되었습니다.");
                n += b;
                if (b != 255) return n;
            }
        }
    }
}
