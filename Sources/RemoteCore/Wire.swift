import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#else
import CCryptoShim
#endif

public enum RFBError: LocalizedError {
    case invalid(String)
    /// The peer closed the socket or stopped sending. Retrying may help; a protocol error will not.
    case closed
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .closed: return "맥이 연결을 종료했습니다."
        }
    }
    public var isProtocolFailure: Bool {
        if case .invalid = self { return true }
        return false
    }
}

/// RFB PointerEvent button mask. Bit 0 is the left button (RFC 6143 §7.5.5).
/// Bits 5 and 6 are the de facto horizontal wheel (buttons 6 and 7).
public enum PointerButtons {
    public static let none: UInt8 = 0
    public static let left: UInt8 = 1 << 0
    public static let middle: UInt8 = 1 << 1
    public static let right: UInt8 = 1 << 2
    public static let wheelUp: UInt8 = 1 << 3
    public static let wheelDown: UInt8 = 1 << 4
    public static let wheelLeft: UInt8 = 1 << 5
    public static let wheelRight: UInt8 = 1 << 6

    /// Press, then release. A click must not leave the button down.
    public static func click(_ button: UInt8) -> [UInt8] { [button, none] }
}

public enum Wire {
    public static func u16(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
    public static func u32(_ value: UInt32) -> [UInt8] { (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    public static func integer(_ data: Data) -> Int { data.reduce(0) { ($0 << 8) | Int($1) } }
    public static func key(_ symbol: UInt32, down: Bool) -> Data { Data([4, down ? 1 : 0, 0, 0] + u32(symbol)) }
    public static func pointer(x: Int, y: Int, buttons: UInt8) -> Data { Data([5, buttons] + u16(x) + u16(y)) }

    /// Classic VNC authentication reverses the bits of each password byte before DES.
    public static func challengeResponse(_ challenge: Data, password: String) throws -> Data {
        guard challenge.count == 16 else { throw RFBError.invalid("잘못된 인증 요청입니다.") }
        let bytes = Array(password.utf8)
        guard !bytes.isEmpty, bytes.count <= 8, bytes.allSatisfy({ $0 < 128 }) else {
            throw RFBError.invalid("이 시제품의 VNC 암호는 영문·숫자·기호 1~8자로 입력해 주세요.")
        }
        let key = (bytes + Array(repeating: UInt8(0), count: 8 - bytes.count)).map { byte -> UInt8 in
            var result: UInt8 = 0
            for bit in 0..<8 { result |= ((byte >> bit) & 1) << (7 - bit) }
            return result
        }
        var output = [UInt8](repeating: 0, count: 16)
        var written = 0
        let status = key.withUnsafeBytes { k in challenge.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode), k.baseAddress, 8, nil, input.baseAddress, 16, out.baseAddress, 16, &written)
            }
        } }
        guard status == kCCSuccess, written == 16 else { throw RFBError.invalid("VNC 인증 응답을 만들지 못했습니다.") }
        return Data(output)
    }
}

/// Whether the remote screen should take hardware and software keys.
/// A presented sheet or alert, or a focused text field, keeps typing in the app.
public struct KeyboardCapture: Equatable {
    public enum Action: Equatable { case become, resign, stay }
    public var enabled: Bool
    public var interfacePresented: Bool
    public var textInputFocused: Bool
    public var isFirstResponder: Bool
    public init(enabled: Bool, interfacePresented: Bool, textInputFocused: Bool, isFirstResponder: Bool) {
        self.enabled = enabled
        self.interfacePresented = interfacePresented
        self.textInputFocused = textInputFocused
        self.isFirstResponder = isFirstResponder
    }
    public var forwardsToRemote: Bool { enabled && !interfacePresented && !textInputFocused }
    public var action: Action {
        if forwardsToRemote { return isFirstResponder ? .stay : .become }
        return isFirstResponder ? .resign : .stay
    }
}

/// US ANSI HID positions mapped to X11 keysyms for Apple's Screen Sharing server.
/// Left Alt sends Command (Super_L); right Alt sends Option (Meta_L).
/// Apple interprets Alt keysyms as Command too; Option must use Meta.
public enum PhysicalKey {
    public static func symbol(hid: Int, shift: Bool = false, option: Bool = false) -> UInt32? {
        // Apple's VNC server synthesizes the requested character and its modifiers.
        // Literal brackets cause it to remove Option; send the Option-produced character.
        if option, hid == 47 { return shift ? 0x0100201d : 0x0100201c }
        if option, hid == 48 { return shift ? 0x01002019 : 0x01002018 }
        if (4...29).contains(hid) { return UInt32((shift ? 65 : 97) + hid - 4) }
        if shift, (30...39).contains(hid) { return Array("!@#$%^&*()".utf8).map(UInt32.init)[hid - 30] }
        if (30...38).contains(hid) { return UInt32(49 + hid - 30) }
        if shift {
            let shifted: [Int: UInt32] = [45:95,46:43,47:123,48:125,49:124,51:58,52:34,53:126,54:60,55:62,56:63]
            if let symbol = shifted[hid] { return symbol }
        }
        let map: [Int: UInt32] = [39:48, 40:0xff0d, 41:0xff1b, 42:0xff08, 43:0xff09, 44:32,
            45:45, 46:61, 47:91, 48:93, 49:92, 51:59, 52:39, 53:96, 54:44, 55:46, 56:47,
            57:0xffe5, 76:0xffff, 79:0xff53, 80:0xff51, 81:0xff54, 82:0xff52,
            224:0xffe3, 225:0xffe1, 226:0xffeb, 227:0xffeb,
            228:0xffe4, 229:0xffe2, 230:0xffe7, 231:0xffec]
        return map[hid]
    }
}
