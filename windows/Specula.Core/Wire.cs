using System.Security.Cryptography;
using Org.BouncyCastle.Crypto.Engines;
using Org.BouncyCastle.Crypto.Parameters;

namespace Specula;

/// <summary>RFB packets shared with the Swift and Android clients. Big-endian, as on the wire.</summary>
public static class Wire
{
    /// <summary>32 bpp, depth 24, little-endian true color, R/G/B shifts 0/8/16.</summary>
    public static readonly byte[] PixelFormat = { 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 0, 8, 16, 0, 0, 0 };

    public static byte[] Key(int symbol, bool down) =>
        new BeWriter().U8(4).U8(down ? 1 : 0).U16(0).I32(symbol).ToArray();

    public static byte[] Pointer(int x, int y, int buttons) =>
        new BeWriter().U8(5).U8(buttons).U16(x).U16(y).ToArray();

    /// <summary>ZRLE, CopyRect, Raw, DesktopSize, LastRect. Cursor pseudo-encoding stays off.</summary>
    public static byte[] Encodings() =>
        new BeWriter().U8(2).U8(0).U16(5).I32(16).I32(1).I32(0).I32(-223).I32(-224).ToArray();

    public static byte[] SetPixelFormat()
    {
        var writer = new BeWriter().U8(0).U8(0).U8(0).U8(0);
        writer.Bytes(PixelFormat);
        return writer.ToArray();
    }

    public static byte[] FramebufferRequest(bool incremental, int width, int height) =>
        new BeWriter().U8(3).U8(incremental ? 1 : 0).U16(0).U16(0).U16(width).U16(height).ToArray();

    /// <summary>Classic VNC authentication reverses each password bit before DES-ECB.</summary>
    public static byte[] Challenge(byte[] challenge, string password)
    {
        var pass = System.Text.Encoding.UTF8.GetBytes(password);
        if (challenge.Length != 16 || pass.Length is < 1 or > 8 || pass.Any(b => b >= 128))
            throw new ProtocolException("VNC 암호는 영문·숫자·기호 1~8자로 입력해 주세요.");
        var key = new byte[8];
        for (var i = 0; i < pass.Length; i++) key[i] = ReverseBits(pass[i]);
        var engine = new DesEngine();
        engine.Init(true, new KeyParameter(key));
        var output = new byte[16];
        engine.ProcessBlock(challenge, 0, output, 0);
        engine.ProcessBlock(challenge, 8, output, 8);
        return output;
    }

    static byte ReverseBits(byte value)
    {
        byte result = 0;
        for (var bit = 0; bit < 8; bit++)
            result |= (byte)(((value >> bit) & 1) << (7 - bit));
        return result;
    }
}

public static class FrameLimits
{
    public static bool Valid(int w, int h) =>
        w is >= 1 and <= 8192 && h is >= 1 and <= 8192 && (long)w * h <= 6016L * 3384;

    public static void Check(int w, int h)
    {
        if (!Valid(w, h)) throw new ProtocolException("지원 가능한 화면 크기를 초과했습니다.");
    }

    public static int Plain(int w, int h)
    {
        Check(w, h);
        return w * h * 4 + ((w + 63) / 64) * ((h + 63) / 64);
    }

    public static int Compressed(int w, int h) => Plain(w, h) + 1024;
}

sealed class BeWriter
{
    readonly MemoryStream _stream = new();

    public BeWriter U8(int value)
    {
        _stream.WriteByte((byte)value);
        return this;
    }

    public BeWriter U16(int value)
    {
        _stream.WriteByte((byte)(value >> 8));
        _stream.WriteByte((byte)value);
        return this;
    }

    public BeWriter I32(int value)
    {
        var bits = (uint)value;
        _stream.WriteByte((byte)(bits >> 24));
        _stream.WriteByte((byte)(bits >> 16));
        _stream.WriteByte((byte)(bits >> 8));
        _stream.WriteByte((byte)bits);
        return this;
    }

    public void Bytes(byte[] value) => _stream.Write(value, 0, value.Length);

    public byte[] ToArray() => _stream.ToArray();
}

sealed class BeReader
{
    readonly Stream _stream;
    readonly byte[] _scratch = new byte[4];

    public BeReader(Stream stream) => _stream = stream;

    public byte[] Read(int count)
    {
        var buffer = new byte[count];
        ReadExact(buffer, 0, count);
        return buffer;
    }

    public void ReadExact(byte[] buffer, int offset, int count)
    {
        while (count > 0)
        {
            var read = _stream.Read(buffer, offset, count);
            if (read <= 0) throw new ProtocolException("맥이 연결을 종료했습니다.");
            offset += read;
            count -= read;
        }
    }

    public int U8()
    {
        ReadExact(_scratch, 0, 1);
        return _scratch[0];
    }

    public int U16()
    {
        ReadExact(_scratch, 0, 2);
        return (_scratch[0] << 8) | _scratch[1];
    }

    public int I32()
    {
        ReadExact(_scratch, 0, 4);
        return (int)(((uint)_scratch[0] << 24) | ((uint)_scratch[1] << 16) | ((uint)_scratch[2] << 8) | _scratch[3]);
    }
}
