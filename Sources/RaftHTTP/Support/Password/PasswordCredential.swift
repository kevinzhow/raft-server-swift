import CArgon2
import Foundation

public enum PasswordCredentialError: DomainError, Sendable {
    case unavailable
    case busy

    public var status: UInt { 503 }
    public var errorMessage: String { "Password authentication temporarily unavailable" }
}

/// Argon2id PHC credentials. SHA token/PKCE codecs are deliberately separate.
public enum PasswordCredential {
    /// New credentials match node-argon2's defaults: v19, 64 MiB, t3, p4,
    /// a fresh 16-byte CSPRNG salt and a 32-byte output.
    public static func hash(_ password: String) throws -> String {
        var generator = SystemRandomNumberGenerator()
        let salt = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return try encode(password, salt: salt)
    }

    static func encode(_ password: String, salt: [UInt8]) throws -> String {
        guard salt.count == 16 else { throw PasswordCredentialError.unavailable }
        let bytes = Array(password.utf8)
        let size = argon2_encodedlen(3, 65_536, 4, 16, 32, Argon2_id)
        var encoded = [CChar](repeating: 0, count: size)
        let result = bytes.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                encoded.withUnsafeMutableBufferPointer { output in
                    argon2id_hash_encoded(3, 65_536, 4, passwordBytes.baseAddress, bytes.count,
                                          saltBytes.baseAddress, salt.count, 32, output.baseAddress, size)
                }
            }
        }
        guard result == 0 else { throw PasswordCredentialError.unavailable }
        return String(decoding: encoded.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Validate the PHC resource limits before the C verifier can allocate.
    /// Old development SHA strings and unsupported/malformed PHCs fail closed.
    public static func verify(_ password: String, encoded: String) -> Bool {
        guard accepts(encoded) else { return false }
        let bytes = Array(password.utf8)
        return encoded.withCString { phc in
            bytes.withUnsafeBytes { input in
                argon2id_verify(phc, input.baseAddress, bytes.count) == 0
            }
        }
    }

    static func accepts(_ encoded: String) -> Bool {
        guard encoded.utf8.count <= 256, !encoded.utf8.contains(0) else { return false }
        let fields = encoded.split(separator: "$", omittingEmptySubsequences: false)
        guard fields.count == 6, fields[0].isEmpty, fields[1] == "argon2id", fields[2] == "v=19" else { return false }
        let options = fields[3].split(separator: ",", omittingEmptySubsequences: false)
        guard options.count == 3,
              let memory = parameter(options[0], prefix: "m="), (8_192...65_536).contains(memory),
              let time = parameter(options[1], prefix: "t="), (1...4).contains(time),
              let lanes = parameter(options[2], prefix: "p="), (1...4).contains(lanes),
              memory >= 8 * lanes,
              let salt = base64(fields[4]), (16...32).contains(salt.count),
              let output = base64(fields[5]), output.count == 32 else { return false }
        return true
    }

    private static func parameter(_ value: Substring, prefix: String) -> Int? {
        guard value.hasPrefix(prefix) else { return nil }
        let digits = value.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.count <= 6, digits.first != "0",
              digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(digits)
    }

    private static func base64(_ value: Substring) -> Data? {
        guard !value.isEmpty, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47
        }) else { return nil }
        let text = String(value)
        let padding = String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: text + padding),
              bytes.base64EncodedString().replacingOccurrences(of: "=", with: "") == text else { return nil }
        return bytes
    }
}
