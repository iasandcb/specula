import XCTest
import BigInt
@testable import RemoteCore

final class ARDTests: XCTestCase {
    static let prime = hex("ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece65381ffffffffffffffff")
    static let peer = hex("567bd67676e2ece82d1656a441af9505378082a7a0286ecc24f5517362993c027fe35227ffd11844e11eb457648f5151443fd51d6827f0c47642d545a0727896af5a71846368fca550a90dccb06ee16825a33feb2e3c2e9098930968acfb110c53d344663b0acf2e2753bbf8aaf303889918d753ece2dbc96ddcac8fe3793c8d")
    static func hex(_ string: String) -> Data {
        Data(stride(from: 0, to: string.count, by: 2).map {
            let start = string.index(string.startIndex, offsetBy: $0)
            return UInt8(string[start..<string.index(start, offsetBy: 2)], radix: 16)!
        })
    }
    func testFullResponseAgainstPythonAndOpenSSLFixture() throws {
        // Independent Python pow + hashlib.md5 + OpenSSL AES-128-ECB fixture.
        let response = try ARD.response(generator: 2, modulus: Self.prime, peer: Self.peer, username: "alex", password: "암호123", entropy: Data(repeating: 3, count: 32), padding: Data(repeating: 0xaa, count: 128))
        XCTAssertEqual(response, Self.hex("bb878e78cb825ee14826edb748bc8af0bf401d474cb99685d7341dcfa1fd102dbf401d474cb99685d7341dcfa1fd102dbf401d474cb99685d7341dcfa1fd102d74bb4106d7e514f45fb9468586e0b992bf401d474cb99685d7341dcfa1fd102dbf401d474cb99685d7341dcfa1fd102dbf401d474cb99685d7341dcfa1fd102d1695d0e82c9d7085f1126ee2ae24fc2946f049a0bf366d790360f93e2c090e3551ebf2c4b1a5aa421dbb2c24dd6904882d43e54b7f46cfaaa62b856d9b487a9c8af511b247834673f1d42a7559988bf3129f51fd3c370f3bdbf4c400b11cf8869a7b384d5dc4daa6bd085edb0f32363c7fcbf78e51d846c790c1b26269dda201"))
    }
    func testCredentialsAreTerminatedAndNeverSilentlyTruncated() throws {
        let block = try ARD.credentials(username: "alex", password: "암호", padding: Data(repeating: 0xaa, count: 128))
        XCTAssertEqual(block.prefix(5), Data([97,108,101,120,0]))
        XCTAssertEqual(block[70], 0)
        XCTAssertEqual(block[127], 0xaa)
        for name in ["", "a\0b", String(repeating: "a", count: 64)] {
            XCTAssertThrowsError(try ARD.credentials(username: name, password: "secret", padding: Data(repeating: 0, count: 128)))
        }
        XCTAssertThrowsError(try ARD.credentials(username: "alex", password: String(repeating: "한", count: 22), padding: Data(repeating: 0, count: 128)))
    }
    func testRejectsDegenerateDHParameters() throws {
        for peer in [Data(repeating: 0, count: 128), Data(repeating: 0, count: 127) + Data([1]), Self.prime] {
            XCTAssertThrowsError(try ARD.response(generator: 2, modulus: Self.prime, peer: peer, username: "alex", password: "secret"))
        }
        XCTAssertThrowsError(try ARD.response(generator: 1, modulus: Self.prime, peer: Self.peer, username: "alex", password: "secret"))
    }
    func testSharedSecretUsesFixedWidthIncludingLeadingZeroes() throws {
        XCTAssertEqual(try ARD.padded(BigUInt(256), length: 4), Data([0,0,1,0]))
    }
}
