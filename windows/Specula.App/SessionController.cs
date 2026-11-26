using System.Threading.Channels;

namespace Specula;

/// <summary>
/// RFB session plus the Specula Display helper. Frame delivery and connection state are separate
/// events so a new frame cannot rebuild the session menu.
/// </summary>
public sealed class SessionController : IDisposable
{
    readonly ISecretStore _secrets;
    readonly SynchronizationContext _ui;
    readonly RemoteKeyboard _keys = new();

    Channel<Outbound>? _outbound;
    RfbClient? _client;
    DisplayClient? _display;
    CancellationTokenSource? _heartbeat;
    Task? _reader;
    int _generation;
    volatile bool _userClose;

    public SessionController(ISecretStore secrets, SynchronizationContext ui)
    {
        _secrets = secrets;
        _ui = ui;
        SavedHost = secrets.Get("host") ?? "";
        SavedPort = secrets.Get("port") ?? "5900";
        SavedUsername = secrets.Get("username:" + SavedHost) ?? "";
        SavedPassword = secrets.Get("password:" + SavedHost) ?? "";
        CommandMode = secrets.Get("commandMode") == "ctrl" ? CommandMode.ControlKey : CommandMode.WindowsKey;
        _keys.Mode = CommandMode;
    }

    public string SavedHost { get; }
    public string SavedPort { get; }
    public string SavedUsername { get; }
    public string SavedPassword { get; }
    public CommandMode CommandMode { get; private set; }
    public bool Connecting { get; private set; }
    public bool Ready { get; private set; }
    public string Status { get; private set; } = "맥에 연결할 준비가 되었습니다";
    public string Error { get; private set; } = "";
    public bool SoftwareOption => _keys.SoftwareOption;
    public bool CommandTabHeld => _keys.CommandTabHeld;
    public bool AltHeld => _keys.AltHeld;
    public bool Portrait { get; private set; }
    public bool Busy { get; private set; }
    public bool Pairing { get; private set; }
    public bool SettingsVisible { get; private set; }
    public DisplaySnapshot? Snapshot { get; private set; }
    bool _rotateAfterPairing;

    public event Action? StateChanged;
    public event Action<Frame>? Frame;

    public (string Username, string Password) CredentialsFor(string host)
    {
        var key = host.Trim();
        return (_secrets.Get("username:" + key) ?? "", _secrets.Get("password:" + key) ?? "");
    }

    public void Connect(string host, int port, string username, string password)
    {
        if (Connecting || Ready) return;
        host = host.Trim();
        if (host.Length == 0)
        {
            Error = "맥 주소를 입력해 주세요.";
            Status = "";
            Notify();
            return;
        }
        if (port is < 1 or > 65535)
        {
            Error = "포트(1~65535)를 확인해 주세요.";
            Status = "";
            Notify();
            return;
        }
        if (password.Length == 0)
        {
            Error = "암호를 입력해 주세요.";
            Status = "";
            Notify();
            return;
        }
        _secrets.Put("host", host);
        _secrets.Put("port", port.ToString());
        _secrets.Put("username:" + host, username);
        _secrets.Put("password:" + host, password);
        var generation = ++_generation;
        _userClose = false;
        Connecting = true;
        Ready = false;
        Error = "";
        Status = "맥에 접속 중…";
        Portrait = false;
        SettingsVisible = false;
        Pairing = false;
        Snapshot = null;
        _keys.Reset();
        _keys.Mode = CommandMode;
        Notify();

        var client = new RfbClient();
        var display = new DisplayClient(host, _secrets);
        var outbound = Channel.CreateUnbounded<Outbound>(new UnboundedChannelOptions { SingleReader = true });
        _client = client;
        _display = display;
        _outbound = outbound;
        _ = Task.Run(() => WriteLoop(outbound.Reader, client));
        _reader = Task.Run(() =>
        {
            Exception? error = null;
            try
            {
                client.Run(host, port, username, password,
                    onReady: _ => Post(() =>
                    {
                        if (generation != _generation) return;
                        Connecting = false;
                        Ready = true;
                        Status = "맥에 연결됨";
                        Error = "";
                        Notify();
                        StartHeartbeat();
                    }),
                    onFrame: frame =>
                    {
                        if (generation != _generation) return;
                        _ui.Post(_ => Frame?.Invoke(frame), null);
                    },
                    onStatus: text => Post(() =>
                    {
                        if (generation != _generation || Ready) return;
                        Status = text;
                        Notify();
                    }));
            }
            catch (Exception ex)
            {
                error = ex;
            }
            finally
            {
                _heartbeat?.Cancel();
                try
                {
                    if (display.HasToken) display.Restore().GetAwaiter().GetResult();
                }
                catch { /* the helper restores itself if this request never arrives */ }
                outbound.Writer.TryComplete();
                Post(() =>
                {
                    if (generation != _generation) return;
                    Finish(error);
                });
            }
        });
    }

    public void Disconnect()
    {
        if (!Connecting && !Ready && _client == null) return;
        _userClose = true;
        if (Ready) ReleaseEverything();
        Enqueue(Outbound.CloseSocket());
        try { _client?.Close(); } catch { /* already closing */ }
    }

    public void Shutdown(TimeSpan wait)
    {
        Disconnect();
        try { _reader?.Wait(wait); } catch { /* the process is leaving */ }
    }

    public void Pointer(int x, int y, byte buttons)
    {
        if (!Ready) return;
        Enqueue(Outbound.PointerEvent(x, y, buttons));
    }

    public void PhysicalScan(int scan, bool extended, bool down)
    {
        if (!Ready) return;
        Send(_keys.Press(scan, extended, down));
    }

    public void ReleasePhysicalKeys() => Send(_keys.ReleasePhysical());

    /// <summary>The window lost the foreground. Every held key goes up so the Mac does not keep Shift or Alt.</summary>
    public void ReleaseForFocusLoss()
    {
        if (!Ready) return;
        var strokes = _keys.ReleaseAll();
        if (strokes.Count == 0) return;
        Send(strokes);
        Notify();
    }

    public void ToggleSoftwareOption()
    {
        if (!Ready) return;
        Send(_keys.ToggleSoftwareOption());
        Notify();
    }

    public void ToggleCommandMode()
    {
        Send(_keys.ReleasePhysical());
        CommandMode = CommandMode == CommandMode.WindowsKey ? CommandMode.ControlKey : CommandMode.WindowsKey;
        _keys.Mode = CommandMode;
        _secrets.Put("commandMode", CommandMode == CommandMode.WindowsKey ? "windows" : "ctrl");
        Notify();
    }

    public void InputSource()
    {
        if (!Ready) return;
        Enqueue(Outbound.KeyEvent(PhysicalKey.ControlLeft, true));
        Enqueue(Outbound.KeyEvent(PhysicalKey.Space, true));
        Enqueue(Outbound.KeyEvent(PhysicalKey.Space, false));
        Enqueue(Outbound.KeyEvent(PhysicalKey.ControlLeft, false));
    }

    public void PressCommandTab()
    {
        if (!Ready) return;
        Send(_keys.BeginCommandTab(out var pause));
        if (pause) Enqueue(Outbound.Delay(40));
        Send(_keys.TabStroke());
        Notify();
    }

    public void ReleaseCommandTab()
    {
        if (!CommandTabHeld) return;
        Send(_keys.ReleaseCommandTab());
        Notify();
    }

    public void OpenResolution() => OpenSettings(rotateAfter: false);

    public void OpenRotation() => OpenSettings(rotateAfter: true);

    public void CloseSettings()
    {
        SettingsVisible = false;
        Pairing = false;
        _rotateAfterPairing = false;
        Error = "";
        Notify();
    }

    public async Task SubmitCode(string code)
    {
        if (_display == null || Busy) return;
        Busy = true;
        Error = "";
        Notify();
        try
        {
            await _display.Pair(code).ConfigureAwait(false);
            if (_rotateAfterPairing)
            {
                _rotateAfterPairing = false;
                var degrees = await _display.Rotate().ConfigureAwait(false);
                Post(() => Portrait = degrees is 90 or 270);
            }
            var snapshot = await _display.Modes().ConfigureAwait(false);
            Post(() =>
            {
                Pairing = false;
                Snapshot = snapshot;
                StartHeartbeat();
            });
        }
        catch (Exception ex)
        {
            Post(() =>
            {
                if (ex is PairingRequiredException)
                {
                    Pairing = true;
                    Snapshot = null;
                }
                Error = Korean(ex);
            });
        }
        finally
        {
            Post(() => { Busy = false; Notify(); });
        }
    }

    public async Task ChangeMode(long id)
    {
        if (_display == null || Busy) return;
        Busy = true;
        Error = "";
        Notify();
        try
        {
            var snapshot = await _display.Change(id).ConfigureAwait(false);
            Post(() => Snapshot = snapshot);
        }
        catch (Exception ex) { Post(() => ApplyDisplayError(ex)); }
        finally { Post(() => { Busy = false; Notify(); }); }
    }

    public async Task RestoreResolution()
    {
        if (_display == null || Busy) return;
        Busy = true;
        Error = "";
        Notify();
        try
        {
            await _display.Restore().ConfigureAwait(false);
            var snapshot = await _display.Modes().ConfigureAwait(false);
            Post(() => Snapshot = snapshot);
        }
        catch (Exception ex) { Post(() => ApplyDisplayError(ex)); }
        finally { Post(() => { Busy = false; Notify(); }); }
    }

    public void Dispose()
    {
        _heartbeat?.Cancel();
        try { _client?.Dispose(); } catch { /* closing */ }
        _display?.Dispose();
    }

    void OpenSettings(bool rotateAfter)
    {
        if (!Ready || _display == null) return;
        ReleaseCommandTab();
        Error = "";
        if (!_display.HasToken)
        {
            SettingsVisible = true;
            Pairing = true;
            Snapshot = null;
            _rotateAfterPairing = rotateAfter;
            Notify();
            return;
        }
        _rotateAfterPairing = false;
        if (rotateAfter)
        {
            SettingsVisible = false;
            Notify();
            _ = RotateNow();
            return;
        }
        SettingsVisible = true;
        Pairing = false;
        Snapshot = null;
        Notify();
        _ = LoadModes();
    }

    async Task LoadModes()
    {
        if (_display == null) return;
        Busy = true;
        Notify();
        try
        {
            var snapshot = await _display.Modes().ConfigureAwait(false);
            Post(() => Snapshot = snapshot);
        }
        catch (Exception ex) { Post(() => ApplyDisplayError(ex)); }
        finally { Post(() => { Busy = false; Notify(); }); }
    }

    async Task RotateNow()
    {
        if (_display == null) return;
        Busy = true;
        Notify();
        try
        {
            var degrees = await _display.Rotate().ConfigureAwait(false);
            Post(() => Portrait = degrees is 90 or 270);
        }
        catch (Exception ex) { Post(() => ApplyDisplayError(ex)); }
        finally { Post(() => { Busy = false; Notify(); }); }
    }

    void ApplyDisplayError(Exception ex)
    {
        if (ex is PairingRequiredException)
        {
            Pairing = true;
            SettingsVisible = true;
            Snapshot = null;
            _heartbeat?.Cancel();
        }
        Error = Korean(ex);
        Notify();
    }

    void StartHeartbeat()
    {
        _heartbeat?.Cancel();
        if (_display is not { HasToken: true } display) return;
        var cts = new CancellationTokenSource();
        _heartbeat = cts;
        _ = Task.Run(async () =>
        {
            try
            {
                var degrees = await display.Rotation().ConfigureAwait(false);
                Post(() => { Portrait = degrees is 90 or 270; Notify(); });
            }
            catch (PairingRequiredException)
            {
                Post(() => { if (Ready) ApplyDisplayError(new PairingRequiredException()); });
                return;
            }
            catch { /* rotation is optional until the user asks for it */ }
            while (!cts.IsCancellationRequested)
            {
                try
                {
                    await display.Heartbeat().ConfigureAwait(false);
                    await Task.Delay(15_000, cts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) { return; }
                catch (PairingRequiredException)
                {
                    Post(() => { if (Ready) ApplyDisplayError(new PairingRequiredException()); });
                    return;
                }
                catch
                {
                    Post(() =>
                    {
                        if (!Ready) return;
                        Error = "해상도 보조 앱과의 연결이 끊겼습니다. 변경한 해상도는 약 1분 이내에 복원됩니다.";
                        Notify();
                    });
                    try { await Task.Delay(5_000, cts.Token).ConfigureAwait(false); }
                    catch { return; }
                }
            }
        });
    }

    void Finish(Exception? error)
    {
        Connecting = false;
        Ready = false;
        SettingsVisible = false;
        Pairing = false;
        Busy = false;
        Portrait = false;
        Snapshot = null;
        _keys.Reset();
        _heartbeat?.Cancel();
        _client = null;
        _display?.Dispose();
        _display = null;
        if (_userClose || error == null)
        {
            Status = "연결을 종료했습니다";
            Error = "";
        }
        else
        {
            Error = Korean(error);
            Status = "";
        }
        Notify();
    }

    void ReleaseEverything() => Send(_keys.ReleaseAll());

    void Send(List<KeyStroke> strokes)
    {
        foreach (var stroke in strokes) Enqueue(Outbound.KeyEvent(stroke.Symbol, stroke.Down));
    }

    void Enqueue(Outbound item) => _outbound?.Writer.TryWrite(item);

    static async Task WriteLoop(ChannelReader<Outbound> reader, RfbClient client)
    {
        try
        {
            await foreach (var item in reader.ReadAllAsync().ConfigureAwait(false))
            {
                try
                {
                    switch (item.Kind)
                    {
                        case 1: client.Key(item.A, item.B != 0); break;
                        case 2: client.Pointer(item.A, item.B, item.C); break;
                        case 3: await Task.Delay(item.A).ConfigureAwait(false); break;
                        case 4: client.Close(); return;
                    }
                }
                catch
                {
                    try { client.Close(); } catch { /* the read loop reports the drop */ }
                    return;
                }
            }
        }
        catch { /* the channel ended because the read loop finished */ }
    }

    void Post(Action action) => _ui.Post(_ => action(), null);
    void Notify() => StateChanged?.Invoke();

    static string Korean(Exception ex)
    {
        var message = ex.GetBaseException().Message;
        return message.Any(c => c is >= '가' and <= '힣')
            ? message
            : "맥에 연결할 수 없습니다. 주소와 화면 공유 설정을 확인해 주세요.";
    }

    readonly record struct Outbound(byte Kind, int A, int B, int C)
    {
        public static Outbound KeyEvent(int symbol, bool down) => new(1, symbol, down ? 1 : 0, 0);
        public static Outbound PointerEvent(int x, int y, int buttons) => new(2, x, y, buttons);
        public static Outbound Delay(int ms) => new(3, ms, 0, 0);
        public static Outbound CloseSocket() => new(4, 0, 0, 0);
    }
}
