import Crypto
import Foundation

/// The pinned upstream `stableUuid` helper (`services/onboardingService.ts`):
/// SHA-256 of the input, version nibble forced to 4, variant bits forced to
/// RFC 4122, lowercase hex. Only server-generated onboarding rows use it, so it
/// stays a small support function instead of another domain type.
enum StableUUID {
    static func make(_ input: String) -> String {
        let hex = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        let characters = Array(hex)
        func slice(_ range: Range<Int>) -> String { String(characters[range]) }
        let variant = (Int(slice(16..<18), radix: 16)! & 0x3f) | 0x80
        return [
            slice(0..<8),
            slice(8..<12),
            "4" + slice(13..<16),
            String(format: "%02x", variant) + slice(18..<20),
            slice(20..<32),
        ].joined(separator: "-")
    }
}
