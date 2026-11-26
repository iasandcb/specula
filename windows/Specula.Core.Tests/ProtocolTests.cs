using System.Numerics;
using System.Text;

namespace Specula.Tests;

public class ProtocolTests
{
    [Fact]
    public void DesKnownVectorAndValidation()
    {
        Assert.Equal(Hex("8ca64de9c1b123a78ca64de9c1b123a7"), Wire.Challenge(new byte[16], "\0"));
        foreach (var pass in new[] { "", "123456789", "한글" })
            Assert.Throws<ProtocolException>(() => Wire.Challenge(new byte[16], pass));
        Assert.Throws<ProtocolException>(() => Wire.Challenge(new byte[15], "test"));
    }

    [Fact]
    public void WirePacketsAndPixelFormat()
    {
        Assert.Equal(Hex("040100000000ffeb"), Wire.Key(0xffeb, true));
        Assert.Equal(Hex("040000000000ffeb"), Wire.Key(0xffeb, false));
        Assert.Equal(Hex("050107800438"), Wire.Pointer(1920, 1080, 1));
        Assert.Equal(Hex("0504000a0014"), Wire.Pointer(10, 20, 4));
        Assert.Equal(Hex("02000005000000100000000100000000ffffff21ffffff20"), Wire.Encodings());
        Assert.Equal(Hex("2018000100ff00ff00ff000810000000"), Wire.PixelFormat);
    }

    [Fact]
    public void CredentialsTerminatedWithoutTruncation()
    {
        var block = Ard.Credentials("alex", "암호", Enumerable.Repeat((byte)0xaa, 128).ToArray());
        Assert.Equal(new byte[] { 97, 108, 101, 120, 0 }, block[..5]);
        Assert.Equal(0, block[70]);
        Assert.Equal(0xaa, block[127]);
        foreach (var name in new[] { "", "a\0b", new string('a', 64) })
            Assert.Throws<ProtocolException>(() => Ard.Credentials(name, "secret", new byte[128]));
        Assert.Throws<ProtocolException>(() => Ard.Credentials("alex", new string('한', 22), new byte[128]));
        Assert.Equal(new byte[] { 0, 0, 1, 0 }, Ard.Pad(new BigInteger(256), 4));
    }

    [Fact]
    public void FullArdResponseMatchesPythonAndOpenSslFixture()
    {
        var response = Ard.Response(
            2,
            Hex(Prime),
            Hex(Peer),
            "alex",
            "암호123",
            Enumerable.Repeat((byte)3, 32).ToArray(),
            Enumerable.Repeat((byte)0xaa, 128).ToArray());
        Assert.Equal(Hex(ArdResponse), response);
    }

    [Fact]
    public void RejectsDegenerateDhParameters()
    {
        var prime = Hex(Prime);
        foreach (var peer in new[] { new byte[128], Enumerable.Repeat((byte)0, 127).Append((byte)1).ToArray(), prime })
            Assert.Throws<ProtocolException>(() => Ard.Response(2, prime, peer, "alex", "secret"));
        Assert.Throws<ProtocolException>(() => Ard.Response(1, prime, Hex(Peer), "alex", "secret"));
    }

    [Fact]
    public void SolidRawPackedAndRuns()
    {
        var z = new Zrle();
        Assert.Equal(Hex("0000ffff0000ffff"), z.Decode(2, 1, Hex("010000ff")));
        Assert.Equal(Hex("ff0000ff00ff00ff"), z.Decode(2, 1, Hex("00ff000000ff00")));
        Assert.Equal(Hex("ffffffff000000ffffffffff000000ffffffffff000000ff"), z.Decode(3, 2, Hex("02000000ffffffa040")));
        Assert.Equal(Hex("ff0000ffff0000ffff0000ff00ff00ff"), z.Decode(4, 1, Hex("80ff00000200ff0000")));
        Assert.Equal(Hex("000000ffffffffffffffffffffffffff"), z.Decode(4, 1, Hex("82000000ffffff008102")));
    }

    [Fact]
    public void PaletteReuseAcrossTilesAndRectangles()
    {
        var z = new Zrle();
        var data = Hex("02000000ffffff").Concat(new byte[8]).Concat(Hex("7f80")).ToArray();
        var frame = z.Decode(65, 1, data);
        Assert.Equal(Hex("000000ff"), frame[..4]);
        Assert.Equal(Hex("ffffffff"), frame[^4..]);
        z.Decode(64, 1, Hex("82000000ffffff813f"));
        Assert.Equal(Hex("000000ff"), z.Decode(1, 1, Hex("8100")));
        Assert.Throws<ProtocolException>(() => new Zrle().Decode(1, 1, Hex("7f00")));
    }

    [Fact]
    public void SyncFlushedStreamStaysPersistent()
    {
        var text = new Zrle();
        Assert.Equal("hello", Encoding.UTF8.GetString(text.Inflate(Hex("789cca48cdc9c907000000ffff"), 100)));
        Assert.Equal("world!!", Encoding.UTF8.GetString(text.Inflate(Hex("2acf2fca49515404000000ffff"), 100)));
        var tiles = new Zrle();
        var a = tiles.Compressed(64, 64, Hex("78da62e4e46007000000ffff"));
        var b = tiles.Compressed(64, 64, Hex("62046200000000ffff"));
        Assert.Equal(a, b);
        Assert.Equal(Hex("090807ff"), a[..4]);
    }

    [Fact]
    public void FourKAndSixKLimitsAndDecode()
    {
        Assert.True(FrameLimits.Valid(6016, 3384));
        Assert.False(FrameLimits.Valid(8192, 8192));
        Assert.True(FrameLimits.Compressed(3840, 2160) > 8_000_000);
        Assert.True(FrameLimits.Compressed(64, 64) < 9_000_000);
        var frame = new Zrle().Compressed(3840, 2160, Hex("78daedc3a10d00000803b0cca2d1fbff4cde40b44933dba8aaaaaaaaaaaaaaaf1f74ece628"));
        Assert.Equal(3840 * 2160 * 4, frame.Length);
        Assert.Equal(Hex("0a141eff"), frame[..4]);
        Assert.Equal(Hex("0a141eff"), frame[^4..]);
    }

    [Fact]
    public void MalformedInputAndInflateBombsAreRejected()
    {
        foreach (var bytes in new[] { "11", "03000000ffffff010203c0", "8000000001", "0100000000", "7f00" })
            Assert.Throws<ProtocolException>(() => new Zrle().Decode(1, 1, Hex(bytes)));
        Assert.Throws<ProtocolException>(() => new Zrle().Inflate(Hex("789cca48cdc9c907000000ffff"), 4));
    }

    [Fact]
    public void OverlappingCopyRectUsesOriginalPixelsAndResize()
    {
        var client = new RfbClient();
        client.InitReplay(4, 1);
        var z = new Zrle();
        client.ReadUpdate(new MemoryStream(Packet(0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00)), z);
        client.ReadUpdate(new MemoryStream(Packet(0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00)), z);
        Assert.Equal(Hex("010000ff010000ff020000ff030000ff"), client.Snapshot().Rgba);
        client.ReadUpdate(new MemoryStream(Packet(0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x04, 0xff, 0xff, 0xff, 0x21)), z);
        Assert.Equal(1, client.Width);
        Assert.Equal(4, client.Height);
    }

    [Fact]
    public void InflaterHandlesSeventeenByteFragments()
    {
        var bytes = Convert.FromBase64String("eJxjYGRiZmFlY+fg5OLm4eXjFxAUEhYRFROXkJSSlpGVk1dQVFJWUVVT19DU0tbR1dM3MDQyNjE1M7ewtLK2sbWzd3B0cnZxdXP38PTy9vH18w8IDAoOCQ0Lj4iMio6JjYtPSExKTklNS8/IzMrOyc3LLygsKi4pLSuvqKyqrqmtq29obGpuaW1r7+js6u7p7eufMHHS5ClTp02fMXPW7Dlz581fsHDR4iVLly1fsXLV6jVr163fsHHT5i1bt23fsXPX7j179+0/cPDQ4SNHjx0/cfLU6TNnz52/cPHS5StXr12/cfPW7Tt3791/8PDR4ydPnz1/8fLV6zdv373/8PHT5y9fv33/8fMXw6jXR70+6vVRr496fdTro14f9fqo10e9Pur1Ua+Pen3U66NeH/X6qNdHvT7q9VGvj3p91OujXh/1+qjXR70+6vVRr496fdTrMK8DACxSNXI=");
        var output = new MemoryStream();
        var z = new Zrle();
        for (var offset = 0; offset < bytes.Length; offset += 17)
            output.Write(z.Inflate(bytes[offset..Math.Min(offset + 17, bytes.Length)], 8000));
        Assert.Equal(Enumerable.Range(0, 8000).Select(i => (byte)(i % 251)).ToArray(), output.ToArray());
    }

    [Fact]
    public void RealScreenSharingCaptureWithShortReads()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "screen-sharing-zrle.bin");
        var fixture = File.ReadAllBytes(path);
        Assert.Equal(1_791_118, fixture.Length);
        var fragmented = new ShortReadStream(fixture);
        var client = new RfbClient();
        client.InitReplay(1600, 1200);
        var frames = 0;
        var z = new Zrle();
        var input = fragmented;
        while (input.Remaining > 0)
        {
            Assert.Equal(0, input.ReadByte());
            if (client.ReadUpdate(input, z)) frames++;
        }
        ulong hash = 14695981039346656037UL;
        foreach (var b in client.Snapshot().Rgba)
            hash = (hash ^ b) * 1099511628211UL;
        Assert.Equal(24, frames);
        Assert.Equal(1600, client.Width);
        Assert.Equal(1200, client.Height);
        Assert.Equal(3000278177406984333UL, hash);
        Assert.True(fragmented.Reads > 1000);
    }

    static byte[] Packet(params byte[] bytes) => bytes;

    const string Prime = "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece65381ffffffffffffffff";
    const string Peer = "567bd67676e2ece82d1656a441af9505378082a7a0286ecc24f5517362993c027fe35227ffd11844e11eb457648f5151443fd51d6827f0c47642d545a0727896af5a71846368fca550a90dccb06ee16825a33feb2e3c2e9098930968acfb110c53d344663b0acf2e2753bbf8aaf303889918d753ece2dbc96ddcac8fe3793c8d";
    const string ArdResponse = "bb878e78cb825ee14826edb748bc8af0bf401d474cb99685d7341dcfa1fd102dbf401d474cb99685d7341dcfa1fd102dbf401d474cb99685d7341dcfa1fd102d74bb4106d7e514f45fb9468586e0b992bf401d474cb99685d7341dcfa1fd102dbf401d474cb99685d7341dcfa1fd102dbf401d474cb99685d7341dcfa1fd102d1695d0e82c9d7085f1126ee2ae24fc2946f049a0bf366d790360f93e2c090e3551ebf2c4b1a5aa421dbb2c24dd6904882d43e54b7f46cfaaa62b856d9b487a9c8af511b247834673f1d42a7559988bf3129f51fd3c370f3bdbf4c400b11cf8869a7b384d5dc4daa6bd085edb0f32363c7fcbf78e51d846c790c1b26269dda201";

    public static byte[] Hex(string text)
    {
        var bytes = new byte[text.Length / 2];
        for (var i = 0; i < bytes.Length; i++) bytes[i] = Convert.ToByte(text.Substring(i * 2, 2), 16);
        return bytes;
    }

    sealed class ShortReadStream : Stream
    {
        readonly byte[] _data;
        readonly Random _random = new(1);
        int _pos;
        public int Reads { get; private set; }
        public int Remaining => _data.Length - _pos;
        public ShortReadStream(byte[] data) => _data = data;
        public override int Read(byte[] buffer, int offset, int count)
        {
            if (_pos >= _data.Length) return 0;
            var n = Math.Min(count, Math.Min(1 + _random.Next(1500), _data.Length - _pos));
            Buffer.BlockCopy(_data, _pos, buffer, offset, n);
            _pos += n;
            Reads++;
            return n;
        }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => _data.Length;
        public override long Position { get => _pos; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
