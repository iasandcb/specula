using System.Numerics;
using System.Security.Cryptography;

namespace Specula;

/// <summary>
/// Apple Remote Desktop security type 30. DH, MD5, and AES-128-ECB protect the credentials only;
/// the framebuffer and input that follow are not encrypted. This matches the Swift and Android clients.
/// </summary>
public static class Ard
{
    const string Group16 =
        "4ee95187682bcb230ad26a95205f6920e84708f6251b3894329b09ec23919e33";

    public static byte[] Pad(BigInteger value, int length)
    {
        if (value.Sign < 0) throw new ProtocolException("인증 키의 크기가 잘못되었습니다.");
        var raw = value.ToByteArray(isUnsigned: true, isBigEndian: true);
        if (raw.Length == 1 && raw[0] == 0) raw = Array.Empty<byte>();
        if (raw.Length > length) throw new ProtocolException("인증 키의 크기가 잘못되었습니다.");
        if (raw.Length == length) return raw;
        var padded = new byte[length];
        Buffer.BlockCopy(raw, 0, padded, length - raw.Length, raw.Length);
        return padded;
    }

    public static byte[] Credentials(string username, string password, byte[] padding)
    {
        var user = System.Text.Encoding.UTF8.GetBytes(username);
        var pass = System.Text.Encoding.UTF8.GetBytes(password);
        if (user.Length is < 1 or > 63 || pass.Length is < 1 or > 63 ||
            user.Contains((byte)0) || pass.Contains((byte)0) || padding.Length != 128)
            throw new ProtocolException("맥 사용자 이름과 암호는 각각 UTF-8 63바이트 이내로 입력해 주세요.");
        var block = (byte[])padding.Clone();
        user.CopyTo(block, 0);
        block[user.Length] = 0;
        pass.CopyTo(block, 64);
        block[64 + pass.Length] = 0;
        return block;
    }

    public static byte[] Response(int generator, byte[] modulus, byte[] peer, string username, string password) =>
        Response(generator, modulus, peer, username, password, Random(32), Random(128));

    public static byte[] Response(
        int generator, byte[] modulus, byte[] peer, string username, string password, byte[] entropy, byte[] padding)
    {
        var block = Credentials(username, password, padding);
        var p = new BigInteger(modulus, isUnsigned: true, isBigEndian: true);
        var g = new BigInteger(generator);
        var server = new BigInteger(peer, isUnsigned: true, isBigEndian: true);
        if (modulus.Length is < 128 or > 512 || peer.Length != modulus.Length ||
            p.GetBitLength() < 1024 || p.IsEven || g <= 1 || g >= p - 1 || server <= 1 || server >= p - 1)
            throw new ProtocolException("맥이 보낸 계정 인증 키가 올바르지 않습니다.");
        var fingerprint = Convert.ToHexString(SHA256.HashData(modulus)).ToLowerInvariant();
        if (fingerprint != Group16 && !IsProbablePrime(p, 16))
            throw new ProtocolException("맥이 보낸 인증 소수가 올바르지 않습니다.");
        var exponent = new BigInteger(entropy, isUnsigned: true, isBigEndian: true) + 2;
        var publicKey = BigInteger.ModPow(g, exponent, p);
        var secret = BigInteger.ModPow(server, exponent, p);
        if (publicKey <= 1 || secret <= 1)
            throw new ProtocolException("맥 인증 키 교환에 실패했습니다.");
        using var aes = Aes.Create();
        aes.Mode = CipherMode.ECB;
        aes.Padding = PaddingMode.None;
        aes.Key = MD5.HashData(Pad(secret, modulus.Length));
        using var encryptor = aes.CreateEncryptor();
        var cipher = encryptor.TransformFinalBlock(block, 0, block.Length);
        var encoded = Pad(publicKey, modulus.Length);
        var result = new byte[cipher.Length + encoded.Length];
        cipher.CopyTo(result, 0);
        encoded.CopyTo(result, cipher.Length);
        return result;
    }

    static byte[] Random(int count)
    {
        var bytes = new byte[count];
        RandomNumberGenerator.Fill(bytes);
        return bytes;
    }

    /// <summary>Miller-Rabin. The published RFC 3526 group 16 modulus skips this via the SHA-256 check above.</summary>
    public static bool IsProbablePrime(BigInteger n, int rounds)
    {
        if (n == 2 || n == 3) return true;
        if (n < 2 || n.IsEven) return false;
        var d = n - 1;
        var s = 0;
        while (d.IsEven)
        {
            d >>= 1;
            s++;
        }
        for (var i = 0; i < rounds; i++)
        {
            var a = RandomBelow(n - 3) + 2;
            var x = BigInteger.ModPow(a, d, n);
            if (x == 1 || x == n - 1) continue;
            var composite = true;
            for (var r = 1; r < s; r++)
            {
                x = BigInteger.ModPow(x, 2, n);
                if (x == n - 1)
                {
                    composite = false;
                    break;
                }
            }
            if (composite) return false;
        }
        return true;
    }

    static BigInteger RandomBelow(BigInteger limit)
    {
        var width = limit.ToByteArray(isUnsigned: true, isBigEndian: true).Length;
        var buffer = new byte[width];
        while (true)
        {
            RandomNumberGenerator.Fill(buffer);
            var value = new BigInteger(buffer, isUnsigned: true, isBigEndian: true);
            if (value < limit) return value;
        }
    }
}
