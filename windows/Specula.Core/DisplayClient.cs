using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Specula;

public interface ISecretStore
{
    string? Get(string key);
    void Put(string key, string? value);
}

public sealed class DisplayMode
{
    public DisplayMode(long id, int width, int height, int pixelWidth, int pixelHeight)
    {
        Id = id;
        Width = width;
        Height = height;
        PixelWidth = pixelWidth;
        PixelHeight = pixelHeight;
    }

    public long Id { get; }
    public int Width { get; }
    public int Height { get; }
    public int PixelWidth { get; }
    public int PixelHeight { get; }
    public string Title => $"{Width} × {Height}" + (PixelWidth > Width ? " · 레티나" : "");
}

public sealed class DisplaySnapshot
{
    public DisplaySnapshot(DisplayMode current, IReadOnlyList<DisplayMode> modes)
    {
        Current = current;
        Modes = modes;
    }

    public DisplayMode Current { get; }
    public IReadOnlyList<DisplayMode> Modes { get; }
}

/// <summary>HTTP client for Specula Display on TCP 5901. The helper is reached only for resolution, rotation, and the lease.</summary>
public sealed class DisplayClient : IDisposable
{
    readonly HttpClient _http;
    readonly ISecretStore _secrets;
    readonly string _host;
    readonly int _port;
    readonly string _tokenKey;

    public DisplayClient(string host, ISecretStore secrets, int port = 5901, HttpMessageHandler? handler = null)
    {
        _host = host;
        _secrets = secrets;
        _port = port;
        _tokenKey = "token:" + host;
        _http = handler == null
            ? new HttpClient(new HttpClientHandler { AllowAutoRedirect = false })
            : new HttpClient(handler, disposeHandler: false);
        _http.Timeout = Timeout.InfiniteTimeSpan;
    }

    public bool HasToken => _secrets.Get(_tokenKey) != null;

    public async Task<JsonDocument> Call(string path, string? body = null, int timeoutMs = 3000)
    {
        var builder = new UriBuilder(Uri.UriSchemeHttp, _host, _port, path);
        using var request = new HttpRequestMessage(body == null ? HttpMethod.Get : HttpMethod.Post, builder.Uri);
        request.Version = HttpVersion.Version11;
        request.Headers.ConnectionClose = true;
        request.Headers.ExpectContinue = false;
        if (path != "/pair" && _secrets.Get(_tokenKey) is string token)
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (body != null)
        {
            request.Content = new ByteArrayContent(Encoding.UTF8.GetBytes(body));
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        }
        using var cts = new CancellationTokenSource(timeoutMs);
        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException ex)
        {
            throw new ProtocolException("맥의 해상도 보조 앱에 연결할 수 없습니다.", ex);
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException)
        {
            throw new ProtocolException("맥의 해상도 보조 앱에 연결할 수 없습니다.", ex);
        }
        using (response)
        {
            var bytes = await response.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false);
            if (bytes.Length > 1_048_576) throw new ProtocolException("서버 메시지가 너무 큽니다.");
            var text = bytes.Length == 0 ? "{}" : Encoding.UTF8.GetString(bytes);
            if ((int)response.StatusCode == 401)
            {
                _secrets.Put(_tokenKey, null);
                throw new PairingRequiredException(path == "/pair"
                    ? "연결 코드를 확인해 주세요."
                    : "맥의 연결 코드로 다시 연결해 주세요.");
            }
            JsonDocument json;
            try
            {
                json = JsonDocument.Parse(text);
            }
            catch (JsonException ex)
            {
                throw new ProtocolException("맥의 해상도 보조 앱에 연결할 수 없습니다.", ex);
            }
            if (response.StatusCode != HttpStatusCode.OK)
            {
                var message = json.RootElement.TryGetProperty("message", out var value) && value.ValueKind == JsonValueKind.String
                    ? value.GetString()
                    : null;
                json.Dispose();
                throw new ProtocolException(string.IsNullOrEmpty(message)
                    ? "맥의 해상도 보조 앱에 연결할 수 없습니다."
                    : message);
            }
            return json;
        }
    }

    public async Task Pair(string code)
    {
        using var result = await Call("/pair", JsonSerializer.Serialize(new Dictionary<string, string> { ["code"] = code })).ConfigureAwait(false);
        var token = result.RootElement.GetProperty("token").GetString();
        if (string.IsNullOrEmpty(token))
            throw new ProtocolException("맥의 해상도 보조 앱에 연결할 수 없습니다.");
        _secrets.Put(_tokenKey, token);
    }

    public async Task<DisplaySnapshot> Modes() => Snapshot(await Call("/modes").ConfigureAwait(false));

    public async Task<DisplaySnapshot> Change(long id)
    {
        using var json = await Call("/mode", JsonSerializer.Serialize(new Dictionary<string, long> { ["modeID"] = id })).ConfigureAwait(false);
        return ParseSnapshot(json);
    }

    public async Task<int> Rotation()
    {
        using var json = await Call("/rotation").ConfigureAwait(false);
        return json.RootElement.GetProperty("degrees").GetInt32();
    }

    public async Task<int> Rotate()
    {
        var current = await RotationBody(6000).ConfigureAwait(false);
        var normalized = ((current % 360) + 360) % 360;
        var next = normalized == 0 ? 90 : 0;
        using var result = await Call("/rotation", JsonSerializer.Serialize(new Dictionary<string, int> { ["degrees"] = next }), 6000).ConfigureAwait(false);
        if (!result.RootElement.GetProperty("supported").GetBoolean())
            throw new ProtocolException("이 디스플레이의 화면을 회전하지 못했습니다.");
        return result.RootElement.GetProperty("degrees").GetInt32();
    }

    async Task<int> RotationBody(int timeout)
    {
        using var json = await Call("/rotation", timeoutMs: timeout).ConfigureAwait(false);
        return json.RootElement.GetProperty("degrees").GetInt32();
    }

    public async Task Heartbeat()
    {
        using var json = await Call("/heartbeat", "{}").ConfigureAwait(false);
    }

    public async Task Restore()
    {
        using var json = await Call("/restore", "{}").ConfigureAwait(false);
    }

    static DisplaySnapshot Snapshot(JsonDocument json)
    {
        using (json) return ParseSnapshot(json);
    }

    static DisplaySnapshot ParseSnapshot(JsonDocument json)
    {
        var current = Mode(json.RootElement.GetProperty("current"));
        var modes = json.RootElement.GetProperty("modes").EnumerateArray()
            .Select(Mode)
            .Where(mode => mode.Width > 0 && mode.Height > 0 && mode.PixelWidth > 0 && mode.PixelHeight > 0 &&
                           (long)mode.PixelWidth * mode.PixelHeight <= 6016L * 3384)
            .OrderBy(mode => mode.Width)
            .ThenBy(mode => mode.Height)
            .ThenBy(mode => mode.PixelWidth)
            .ThenBy(mode => mode.PixelHeight)
            .ThenBy(mode => mode.Id)
            .DistinctBy(mode => (mode.Width, mode.Height, mode.PixelWidth, mode.PixelHeight))
            .ToArray();
        return new DisplaySnapshot(current, modes);
    }

    static DisplayMode Mode(JsonElement json) => new(
        json.GetProperty("id").GetInt64(),
        json.GetProperty("width").GetInt32(),
        json.GetProperty("height").GetInt32(),
        json.GetProperty("pixelWidth").GetInt32(),
        json.GetProperty("pixelHeight").GetInt32());

    public void Dispose() => _http.Dispose();
}
