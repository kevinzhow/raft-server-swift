import Crypto
import Foundation

public enum AuthTokenCodec {
    public static func sha256Hex(_ value: String) -> String {
        AuthTokenCodec.sha256(value)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func refreshAttempt(_ header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /^arf_[0-9a-f]{16}$/) != nil else { return nil }
        return trimmed
    }

    static func refreshInstallation(_ header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /^ari_[0-9a-f]{32}$/) != nil else { return nil }
        return trimmed
    }

    static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ value: String) -> String {
        AuthTokenCodec.sha256(Data(value.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64urlDecode(_ value: String) -> Data? {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        return Data(base64Encoded: padded)
    }

    static func sealSuccessor(_ token: String) -> String {
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data("slock-session-refresh-rotation-receipt".utf8))))
        if let sealed = try? AES.GCM.seal(Data(token.utf8), using: key) {
            return sealed.ciphertext.base64EncodedString()
        }
        return AuthTokenCodec.sha256("sealed:\(token)")
    }

    static func token() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func pkceS256(_ verifier: String) -> String {
        AuthTokenCodec.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func deviceSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "dvc_\(encoded)"
    }

    public static let agentCredentialUseDefaultThrottleMs = 60_000
}
