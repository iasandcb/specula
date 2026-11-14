import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#else
import CCryptoShim
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif
import BigInt

/// Apple Remote Desktop security type 30. This protects credentials, not the RFB session.
/// Wire reference: https://github.com/novnc/noVNC/blob/master/core/rfb.js
public enum ARD {
    static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!)
        }
        guard status == errSecSuccess else { throw RFBError.invalid("인증용 난수를 만들지 못했습니다.") }
        return Data(bytes)
    }

    static func padded(_ value: BigUInt, length: Int) throws -> Data {
        let bytes = value.serialize()
        guard bytes.count <= length else { throw RFBError.invalid("인증 키의 크기가 잘못되었습니다.") }
        return Data(repeating: 0, count: length - bytes.count) + bytes
    }

    static func credentials(username: String, password: String, padding: Data) throws -> Data {
        let user = Data(username.utf8), pass = Data(password.utf8)
        guard !user.isEmpty, !pass.isEmpty, user.count < 64, pass.count < 64,
              !user.contains(0), !pass.contains(0), padding.count == 128 else {
            throw RFBError.invalid("맥 사용자 이름과 암호는 각각 UTF-8 63바이트 이내로 입력해 주세요.")
        }
        var block = padding
        block.replaceSubrange(0..<user.count, with: user); block[user.count] = 0
        block.replaceSubrange(64..<(64 + pass.count), with: pass); block[64 + pass.count] = 0
        return block
    }

    static func encrypt(_ credentials: Data, shared: Data) throws -> Data {
        let key = Array(Insecure.MD5.hash(data: shared))
        var encrypted = [UInt8](repeating: 0, count: 128)
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in credentials.withUnsafeBytes { input in
            encrypted.withUnsafeMutableBytes { output in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), keyBytes.baseAddress, 16, nil, input.baseAddress, credentials.count, output.baseAddress, 128, &written)
            }
        } }
        guard status == kCCSuccess, written == 128 else { throw RFBError.invalid("맥 계정 인증 데이터를 만들지 못했습니다.") }
        return Data(encrypted)
    }

    public static func response(generator: Int, modulus: Data, peer: Data, username: String, password: String) throws -> Data {
        try response(generator: generator, modulus: modulus, peer: peer, username: username, password: password, entropy: random(32), padding: random(128))
    }

    static func response(generator: Int, modulus: Data, peer: Data, username: String, password: String, entropy: Data, padding: Data) throws -> Data {
        let block = try credentials(username: username, password: password, padding: padding)
        let p = BigUInt(modulus), g = BigUInt(max(0, generator)), server = BigUInt(peer)
        guard (128...512).contains(modulus.count), modulus.count == peer.count,
              p.bitWidth >= 1024, p & 1 == 1, g > 1, g < p - 1, server > 1, server < p - 1 else {
            throw RFBError.invalid("맥이 보낸 계정 인증 키가 올바르지 않습니다.")
        }
        try Task.checkCancellation()
        // RFC 3526 group 16 is already a published prime. Compare every byte via SHA-256;
        // repeating Miller-Rabin on 4096 bits in Debug can exceed the handshake deadline.
        let group16Hash = "4ee95187682bcb230ad26a95205f6920e84708f6251b3894329b09ec23919e33"
        let fingerprint = SHA256.hash(data: modulus).map { String(format: "%02x", $0) }.joined()
        guard fingerprint == group16Hash || p.isPrime(rounds: 8) else { throw RFBError.invalid("맥이 보낸 인증 소수가 올바르지 않습니다.") }
        try Task.checkCancellation()
        let exponent = BigUInt(entropy) + 2
        let publicKey = g.power(exponent, modulus: p)
        let secret = server.power(exponent, modulus: p)
        guard secret > 1, publicKey > 1 else { throw RFBError.invalid("맥 인증 키 교환에 실패했습니다.") }
        try Task.checkCancellation()
        return try encrypt(block, shared: padded(secret, length: modulus.count)) + padded(publicKey, length: modulus.count)
    }
}
