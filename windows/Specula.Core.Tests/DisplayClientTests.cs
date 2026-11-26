using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace Specula.Tests;

public class DisplayClientTests
{
    sealed class Memory : ISecretStore
    {
        readonly Dictionary<string, string> _values = new();
        public string? Get(string key) => _values.TryGetValue(key, out var value) ? value : null;
        public void Put(string key, string? value)
        {
            if (value == null) _values.Remove(key);
            else _values[key] = value;
        }
    }

    [Fact]
    public async Task PairModeRotationHeartbeatRestoreAndUnauthorized()
    {
        var secrets = new Memory();
        var status = 200;
        var paths = new List<string>();
        var angle = 0;
        const string mode = """{"id":42,"width":1280,"height":720,"pixelWidth":2560,"pixelHeight":1440}""";
        var snapshot = "{\"current\":" + mode + ",\"modes\":[" + mode + "," + mode + "]}";
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var server = Task.Run(async () =>
        {
            for (var i = 0; i < 11; i++)
            {
                using var client = await listener.AcceptTcpClientAsync();
                client.ReceiveTimeout = 5000;
                using var stream = client.GetStream();
                var (method, path, headers, body) = await ReadRequest(stream);
                paths.Add(path);
                var result = "{}";
                if (path == "/pair")
                {
                    Assert.Equal("POST", method);
                    Assert.Equal("123456", JsonDocument.Parse(body).RootElement.GetProperty("code").GetString());
                    result = """{"token":"fresh"}""";
                }
                else
                {
                    Assert.Equal("Bearer fresh", headers["authorization"]);
                    switch (path)
                    {
                        case "/modes":
                            Assert.Equal("GET", method);
                            result = snapshot;
                            break;
                        case "/mode":
                            Assert.Equal(42, JsonDocument.Parse(body).RootElement.GetProperty("modeID").GetInt32());
                            result = snapshot;
                            break;
                        case "/rotation":
                            if (method == "POST") angle = JsonDocument.Parse(body).RootElement.GetProperty("degrees").GetInt32();
                            result = "{\"degrees\":" + angle + ",\"supported\":true}";
                            break;
                        case "/heartbeat":
                        case "/restore":
                            Assert.Equal("POST", method);
                            JsonDocument.Parse(body);
                            break;
                    }
                }
                if (status != 200) result = """{"message":"다시 연결해 주세요."}""";
                var payload = Encoding.UTF8.GetBytes(result);
                var head = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} Response\r\nContent-Type: application/json\r\nContent-Length: {payload.Length}\r\nConnection: close\r\n\r\n");
                await stream.WriteAsync(head);
                await stream.WriteAsync(payload);
            }
        });
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var display = new DisplayClient("127.0.0.1", secrets, port);
        try
        {
            await display.Pair("123456");
            Assert.Equal("fresh", secrets.Get("token:127.0.0.1"));
            var snap = await display.Modes();
            Assert.Equal(42, snap.Current.Id);
            Assert.Equal("1280 × 720 · 레티나", snap.Current.Title);
            Assert.Single(snap.Modes);
            await display.Change(42);
            Assert.Equal(90, await display.Rotate());
            Assert.Equal(0, await display.Rotate());
            await display.Heartbeat();
            await display.Restore();
            Assert.Contains("/pair", paths);
            Assert.Contains("/modes", paths);
            Assert.Contains("/mode", paths);
            Assert.Contains("/rotation", paths);
            Assert.Contains("/heartbeat", paths);
            Assert.Contains("/restore", paths);
            status = 401;
            var denied = await Assert.ThrowsAsync<PairingRequiredException>(() => display.Heartbeat());
            Assert.Contains("연결 코드", denied.Message);
            Assert.Null(secrets.Get("token:127.0.0.1"));
            secrets.Put("token:127.0.0.1", "old");
            await Assert.ThrowsAsync<PairingRequiredException>(() => display.Pair("123456"));
            Assert.Null(secrets.Get("token:127.0.0.1"));
            await server.WaitAsync(TimeSpan.FromSeconds(10));
        }
        finally
        {
            display.Dispose();
            listener.Stop();
        }
    }

    [Fact]
    public async Task ListFailsFastOnUnresponsiveHelper()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var stalled = Task.Run(async () =>
        {
            using var client = await listener.AcceptTcpClientAsync();
            await Task.Delay(1200);
        });
        var display = new DisplayClient("127.0.0.1", new Memory(), ((IPEndPoint)listener.LocalEndpoint).Port);
        var start = DateTime.UtcNow;
        await Assert.ThrowsAnyAsync<IOException>(() => display.Call("/modes", timeoutMs: 200));
        Assert.True(DateTime.UtcNow - start < TimeSpan.FromSeconds(2));
        listener.Stop();
        display.Dispose();
        try { await stalled; } catch { /* listener closed */ }
    }

    static async Task<(string method, string path, Dictionary<string, string> headers, string body)> ReadRequest(NetworkStream stream)
    {
        var data = new MemoryStream();
        var one = new byte[1];
        while (true)
        {
            if (await stream.ReadAsync(one) <= 0) throw new IOException("closed");
            data.WriteByte(one[0]);
            if (data.Length >= 4)
            {
                var tail = data.GetBuffer();
                var n = (int)data.Length;
                if (tail[n - 4] == '\r' && tail[n - 3] == '\n' && tail[n - 2] == '\r' && tail[n - 1] == '\n') break;
            }
        }
        var headerText = Encoding.ASCII.GetString(data.ToArray());
        var lines = headerText.Split("\r\n");
        var request = lines[0].Split(' ');
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 1; i < lines.Length; i++)
        {
            if (lines[i].Length == 0) continue;
            var split = lines[i].IndexOf(':');
            if (split > 0) headers[lines[i][..split]] = lines[i][(split + 1)..].Trim();
        }
        var length = headers.TryGetValue("content-length", out var value) ? int.Parse(value) : 0;
        var body = new byte[length];
        var read = 0;
        while (read < length)
        {
            var n = await stream.ReadAsync(body.AsMemory(read));
            if (n <= 0) break;
            read += n;
        }
        return (request[0], request[1], headers, Encoding.UTF8.GetString(body));
    }
}
