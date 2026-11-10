import Foundation

/// The two notification ledgers are separate payloads in the caller's transaction.
/// This codec does not persist deployment configuration or executable callbacks.
enum NotificationsPersistenceCoding {
    enum Failure: Error, Sendable, Equatable {
        case wrongOwner
        case unsupportedVersion(Int)
        case unsupportedDateEncoding
        case invalidDate
        case invalidSnapshot
    }

    private static let version = 1
    private static let dateEncoding = "foundation-reference-date-ieee754-binary64-hex"

    private struct Header: Decodable {
        let owner: String
        let version: Int
        let dateEncoding: String
    }

    private struct Envelope<Value: Codable>: Codable {
        let owner: String
        let version: Int
        let dateEncoding: String
        let business: Value
    }

    /// A nullable value whose key is required. Ordinary Optional synthesis would
    /// silently accept a missing credential/revocation field as nil.
    struct RequiredOptional<Value: Codable & Sendable>: Codable, Sendable {
        let value: Value?

        init(_ value: Value?) { self.value = value }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { value = nil }
            else { value = try container.decode(Value.self) }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            if let value { try container.encode(value) }
            else { try container.encodeNil() }
        }
    }

    static func encode<Value: Codable>(_ value: Value, owner: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let interval = date.timeIntervalSinceReferenceDate
            guard interval.isFinite else { throw Failure.invalidDate }
            var container = encoder.singleValueContainer()
            let text = String(interval.bitPattern, radix: 16)
            try container.encode(String(repeating: "0", count: 16 - text.count) + text)
        }
        return try encoder.encode(Envelope(
            owner: owner, version: version, dateEncoding: dateEncoding, business: value
        ))
    }

    /// Header, required keys, nullable keys and every Date are checked before
    /// a caller can replace any live rows. No business values enter our errors.
    static func decode<Value: Codable>(_ type: Value.Type, from data: Data, owner: String) throws -> Value {
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        guard header.owner == owner else { throw Failure.wrongOwner }
        guard header.version == version else { throw Failure.unsupportedVersion(header.version) }
        guard header.dateEncoding == dateEncoding else { throw Failure.unsupportedDateEncoding }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard text.utf8.count == 16,
                  text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let bits = UInt64(text, radix: 16) else {
                throw Failure.invalidDate
            }
            let interval = Double(bitPattern: bits)
            guard interval.isFinite else { throw Failure.invalidDate }
            return Date(timeIntervalSinceReferenceDate: interval)
        }
        return try decoder.decode(Envelope<Value>.self, from: data).business
    }
}
