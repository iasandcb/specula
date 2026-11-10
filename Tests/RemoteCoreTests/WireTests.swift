import XCTest
@testable import RemoteCore

final class WireTests: XCTestCase {
    func testAuthenticationAgainstKnownDESVector() throws {
        // DES zero-key/zero-plaintext reference vector, repeated for the two VNC blocks.
        let result = try Wire.challengeResponse(Data(repeating: 0, count: 16), password: "\0")
        XCTAssertEqual(result.map { String(format: "%02x", $0) }.joined(), "8ca64de9c1b123a78ca64de9c1b123a7")
    }
    func testInvalidChallengeAndUnsupportedPasswordsFail() {
        XCTAssertThrowsError(try Wire.challengeResponse(Data(repeating: 0, count: 15), password: "test"))
        for password in ["", "123456789", "한글"] {
            XCTAssertThrowsError(try Wire.challengeResponse(Data(repeating: 0, count: 16), password: password))
        }
    }
    func testKeyPacketsUseNetworkByteOrder() {
        XCTAssertEqual(Array(Wire.key(0xffeb, down: true)), [4,1,0,0,0,0,255,235])
        XCTAssertEqual(Array(Wire.key(0xffeb, down: false)), [4,0,0,0,0,0,255,235])
    }
    func testPointerCoordinatesDoNotLoseHighBytes() {
        XCTAssertEqual(Array(Wire.pointer(x: 1920, y: 1080, buttons: PointerButtons.left)), [5,1,7,128,4,56])
    }
    func testPointerButtonMaskMatchesRFBBits() {
        XCTAssertEqual(PointerButtons.left, 1)
        XCTAssertEqual(PointerButtons.middle, 2)
        XCTAssertEqual(PointerButtons.right, 4)
        XCTAssertEqual(PointerButtons.wheelUp, 8)
        XCTAssertEqual(PointerButtons.wheelDown, 16)
        XCTAssertEqual(PointerButtons.left | PointerButtons.middle | PointerButtons.right | PointerButtons.wheelUp | PointerButtons.wheelDown, 31)
        XCTAssertEqual(PointerButtons.click(PointerButtons.left), [PointerButtons.left, PointerButtons.none])
        XCTAssertEqual(PointerButtons.click(PointerButtons.right), [4, 0])
        XCTAssertEqual(Array(Wire.pointer(x: 10, y: 20, buttons: PointerButtons.right)), [5,4,0,10,0,20])
        XCTAssertEqual(Array(Wire.pointer(x: 10, y: 20, buttons: PointerButtons.none)), [5,0,0,10,0,20])
    }
    func testAltSidesProvideBothMacCommandAndOption() {
        XCTAssertEqual(PhysicalKey.symbol(hid: 226), 0xffeb) // Left Alt → Command
        XCTAssertEqual(PhysicalKey.symbol(hid: 230), 0xffe7) // Right Alt → Option (Meta_L)
        XCTAssertEqual(PhysicalKey.symbol(hid: 227), 0xffeb) // Physical Command is unchanged.
        XCTAssertEqual(Array(Wire.key(0xffe8, down: false)), [4,0,0,0,0,0,255,232])
    }
    func testOptionBracketsSendCharactersThatPreserveMacOption() {
        XCTAssertEqual(PhysicalKey.symbol(hid: 47, option: true), 0x0100201c)
        XCTAssertEqual(PhysicalKey.symbol(hid: 48, option: true), 0x01002018)
        XCTAssertEqual(PhysicalKey.symbol(hid: 47, shift: true, option: true), 0x0100201d)
        XCTAssertEqual(PhysicalKey.symbol(hid: 48, shift: true, option: true), 0x01002019)
        XCTAssertEqual(PhysicalKey.symbol(hid: 47), 91)
        XCTAssertEqual(PhysicalKey.symbol(hid: 48), 93)
        XCTAssertEqual(PhysicalKey.symbol(hid: 80, option: true), 0xff51)
    }
    func testPhysicalPositionsRemainLatinForMacIME() {
        // Korean ㄱ occupies the US R position; never transmit composed Korean here.
        XCTAssertEqual(PhysicalKey.symbol(hid: 21), 0x72)
        XCTAssertEqual(PhysicalKey.symbol(hid: 21, shift: true), 0x52)
        XCTAssertEqual(PhysicalKey.symbol(hid: 30, shift: true), 0x21)
        XCTAssertEqual(PhysicalKey.symbol(hid: 225), 0xffe1)
        XCTAssertEqual(PhysicalKey.symbol(hid: 227), 0xffeb)
        XCTAssertNil(PhysicalKey.symbol(hid: 999))
    }
}
