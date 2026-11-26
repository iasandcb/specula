using System.Net.Sockets;
using System.Text;

namespace Specula;

public readonly record struct Frame(int Width, int Height, byte[] Rgba);

/// <summary>
/// Blocking RFB 3.3/3.7/3.8 client. The read loop owns the socket; writes are serialized.
/// Account login is ARD type 30. An empty username is classic VNC type 2. There is no fallback
/// to unauthenticated access, and the cursor pseudo-encoding is not requested.
/// </summary>
public sealed class RfbClient : IDisposable
{
    readonly object _writeLock = new();
    Socket? _socket;
    NetworkStream? _output;
    byte[] _pixels = Array.Empty<byte>();
    volatile bool _handshakeTimedOut;

    public int Width { get; private set; }
    public int Height { get; private set; }

    public void Send(byte[] bytes)
    {
        lock (_writeLock)
        {
            var output = _output ?? throw new ProtocolException("연결이 종료되었습니다.");
            output.Write(bytes, 0, bytes.Length);
            output.Flush();
        }
    }

    public void Key(int symbol, bool down) => Send(Wire.Key(symbol, down));

    public void Pointer(int x, int y, int buttons)
    {
        if (Width <= 0 || Height <= 0) return;
        Send(Wire.Pointer(Math.Clamp(x, 0, Width - 1), Math.Clamp(y, 0, Height - 1), buttons));
    }

    public void Request(bool incremental) => Send(Wire.FramebufferRequest(incremental, Width, Height));

    public void Run(
        string host,
        int port,
        string username,
        string password,
        Action<string> onReady,
        Action<Frame> onFrame,
        Action<string>? onStatus = null)
    {
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
        _socket = socket;
        using var deadline = new Timer(_ =>
        {
            _handshakeTimedOut = true;
            try { socket.Close(); } catch { /* the read surfaces the timeout */ }
        }, null, TimeSpan.FromSeconds(45), Timeout.InfiniteTimeSpan);
        try
        {
            onStatus?.Invoke("맥에 접속 중…");
            try
            {
                using var connectLimit = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                socket.ConnectAsync(host, port, connectLimit.Token).GetAwaiter().GetResult();
            }
            catch (OperationCanceledException)
            {
                throw new ProtocolException("맥에 연결할 수 없습니다. 주소와 화면 공유 설정을 확인해 주세요.");
            }
            socket.ReceiveTimeout = 10_000;
            var stream = new NetworkStream(socket, ownsSocket: false);
            lock (_writeLock) _output = stream;
            var input = new BeReader(stream);
            onStatus?.Invoke("맥 응답 확인 · 로그인 방식 협의 중…");
            var banner = Encoding.ASCII.GetString(input.Read(12));
            if (banner.Length != 12 || !banner.StartsWith("RFB 003.", StringComparison.Ordinal) || banner[11] != '\n' ||
                !int.TryParse(banner.AsSpan(8, 3), out var minor) || minor < 3)
                throw new ProtocolException("지원하지 않는 화면 공유 프로토콜입니다.");
            var version = minor >= 8 ? 8 : minor >= 7 ? 7 : 3;
            Send(Encoding.ASCII.GetBytes($"RFB 003.00{version}\n"));
            var security = username.Length > 0 ? 30 : 2;
            if (version == 3)
            {
                if (input.I32() != security)
                    throw new ProtocolException(security == 30
                        ? "이 맥은 계정 로그인을 제공하지 않습니다. 사용자 이름을 비우고 VNC 암호로 접속해 주세요."
                        : "맥에서 VNC 암호 접속을 켜거나 사용자 이름을 입력해 계정으로 접속해 주세요.");
            }
            else
            {
                var count = input.U8();
                if (count == 0) throw new ProtocolException(Reason(input));
                var types = input.Read(count);
                if (!types.Contains((byte)security))
                    throw new ProtocolException(security == 30
                        ? "이 맥은 지원하는 계정 인증(ARD)을 제공하지 않습니다. VNC 암호 접속을 사용해 주세요."
                        : "사용자 이름과 맥 로그인 암호를 입력하거나, 맥에서 VNC 암호 접속을 켜 주세요.");
                Send(new[] { (byte)security });
            }
            if (security == 30)
            {
                var generator = input.U16();
                var length = input.U16();
                if (length is < 128 or > 512)
                    throw new ProtocolException("지원하지 않는 맥 인증 키 크기입니다.");
                onStatus?.Invoke("맥 계정 인증 키 계산 중…");
                var response = Ard.Response(generator, input.Read(length), input.Read(length), username, password);
                onStatus?.Invoke("맥에 로그인 확인 중…");
                Send(response);
            }
            else
            {
                onStatus?.Invoke("VNC 암호 확인 중…");
                Send(Wire.Challenge(input.Read(16), password));
            }
            if (input.I32() != 0)
                throw new ProtocolException(security == 30
                    ? "맥 계정 인증에 실패했습니다. 사용자 이름·암호와 화면 공유 접근 권한을 확인해 주세요."
                    : "인증에 실패했습니다. 맥에 설정한 VNC 암호를 확인해 주세요.");
            onStatus?.Invoke("로그인 완료 · 화면 정보 수신 중…");
            Send(new byte[] { 1 });
            Width = input.U16();
            Height = input.U16();
            _ = input.Read(16);
            var name = Reason(input);
            Allocate();
            Send(Wire.SetPixelFormat());
            Send(Wire.Encodings());
            deadline.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
            socket.ReceiveTimeout = 0;
            onStatus?.Invoke("첫 화면을 받는 중…");
            onReady(name);
            Request(false);
            var zrle = new Zrle();
            while (socket.Connected)
            {
                switch (input.U8())
                {
                    case 0:
                        if (ReadUpdate(input, zrle))
                            onFrame(new Frame(Width, Height, (byte[])_pixels.Clone()));
                        break;
                    case 2:
                        break;
                    case 3:
                        _ = input.Read(3);
                        _ = Reason(input);
                        break;
                    case var type:
                        throw new ProtocolException($"지원하지 않는 서버 메시지입니다: {type}");
                }
            }
        }
        catch (ProtocolException)
        {
            throw;
        }
        catch (Exception ex) when (_handshakeTimedOut)
        {
            throw new ProtocolException("맥 인증 응답이 없어 연결을 취소했습니다.", ex);
        }
        finally
        {
            deadline.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
            try { socket.Close(); } catch { /* already closing */ }
            lock (_writeLock) _output = null;
            _socket = null;
        }
    }

    public bool ReadUpdate(Stream stream, Zrle zrle) => ReadUpdate(new BeReader(stream), zrle);

    bool ReadUpdate(BeReader input, Zrle zrle)
    {
        _ = input.U8();
        var count = input.U16();
        var resized = false;
        var changed = false;
        for (var i = 0; i < count; i++)
        {
            var x = input.U16();
            var y = input.U16();
            var w = input.U16();
            var h = input.U16();
            var encoding = input.I32();
            if (encoding == -224)
            {
                if (_output != null) Request(!resized);
                return changed;
            }
            try
            {
                if (encoding == -223)
                {
                    Width = w;
                    Height = h;
                    Allocate();
                    resized = true;
                    changed = true;
                    continue;
                }
                FrameLimits.Check(w, h);
                if ((long)x + w > Width || (long)y + h > Height)
                    throw new ProtocolException("화면 데이터가 잘못되었습니다.");
                var data = encoding switch
                {
                    0 => ReadRaw(input, w, h),
                    1 => ReadCopy(input, w, h),
                    16 => ReadZrle(input, zrle, w, h),
                    _ => throw new ProtocolException($"지원하지 않는 화면 압축 방식입니다: {encoding}")
                };
                for (var row = 0; row < h; row++)
                {
                    Buffer.BlockCopy(data, row * w * 4, _pixels, ((y + row) * Width + x) * 4, w * 4);
                }
                changed = true;
            }
            catch (Exception ex)
            {
                throw new ProtocolException($"화면 데이터 오류 · 인코딩 {encoding} · {x},{y} {w}×{h}: {ex.Message}", ex);
            }
        }
        if (_output != null) Request(!resized);
        return changed;
    }

    byte[] ReadRaw(BeReader input, int w, int h)
    {
        var data = input.Read(w * h * 4);
        for (var i = 3; i < data.Length; i += 4) data[i] = 255;
        return data;
    }

    byte[] ReadCopy(BeReader input, int w, int h)
    {
        var sx = input.U16();
        var sy = input.U16();
        if ((long)sx + w > Width || (long)sy + h > Height)
            throw new ProtocolException("화면 복사 범위가 잘못되었습니다.");
        var copy = new byte[w * h * 4];
        for (var row = 0; row < h; row++)
        {
            Buffer.BlockCopy(_pixels, ((sy + row) * Width + sx) * 4, copy, row * w * 4, w * 4);
        }
        return copy;
    }

    static byte[] ReadZrle(BeReader input, Zrle zrle, int w, int h)
    {
        var length = input.I32();
        if (length < 1 || length > FrameLimits.Compressed(w, h))
            throw new ProtocolException("화면 압축 크기가 잘못되었습니다.");
        return zrle.Compressed(w, h, input.Read(length));
    }

    static string Reason(BeReader input)
    {
        var length = input.I32();
        if (length is < 0 or > 1_048_576) throw new ProtocolException("서버 메시지가 너무 큽니다.");
        return Encoding.UTF8.GetString(input.Read(length));
    }

    void Allocate()
    {
        FrameLimits.Check(Width, Height);
        _pixels = new byte[Width * Height * 4];
    }

    public void InitReplay(int w, int h)
    {
        Width = w;
        Height = h;
        Allocate();
    }

    public Frame Snapshot() => new(Width, Height, (byte[])_pixels.Clone());

    public void Dispose() => Close();

    public void Close()
    {
        try { _socket?.Close(); } catch { /* closing is idempotent */ }
    }
}
