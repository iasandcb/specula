using System.IO;
using System.Security.Cryptography;
using System.Text.Json;

namespace Specula;

/// <summary>DPAPI-wrapped settings. The login password and helper token never sit on disk in the clear.</summary>
public sealed class SecretFile : ISecretStore
{
    readonly string _path;
    readonly Dictionary<string, string> _values = new();

    public SecretFile()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Specula");
        Directory.CreateDirectory(dir);
        _path = Path.Combine(dir, "secrets.bin");
        try
        {
            if (!File.Exists(_path)) return;
            var plain = ProtectedData.Unprotect(File.ReadAllBytes(_path), null, DataProtectionScope.CurrentUser);
            var loaded = JsonSerializer.Deserialize<Dictionary<string, string>>(plain);
            if (loaded == null) return;
            foreach (var pair in loaded) _values[pair.Key] = pair.Value;
        }
        catch
        {
            _values.Clear();
        }
    }

    public string? Get(string key) => _values.TryGetValue(key, out var value) ? value : null;

    public void Put(string key, string? value)
    {
        if (value == null) _values.Remove(key);
        else _values[key] = value;
        var plain = JsonSerializer.SerializeToUtf8Bytes(_values);
        var blob = ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(_path, blob);
    }
}
