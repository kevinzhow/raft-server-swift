import Foundation

/// Owner-local opaque snapshots. Cross-owner consistency and PG commits belong
/// to the persistence coordinator. Payloads can contain access tokens: never log.
enum ProductFeedbackPersistenceFormat {
    enum Failure: Error, Sendable, Equatable {
        case wrongOwner
        case unsupportedVersion(Int)
        case unsupportedDateEncoding
    }

    private static let version = 1
    private static let dateEncoding = "foundation-reference-date-ieee754-binary64-hex"

    private struct Header: Decodable {
        let owner: String
        let version: Int
        let dateEncoding: String
    }

    private struct Envelope<Payload: Codable & Sendable>: Codable, Sendable {
        let owner: String
        let version: Int
        let dateEncoding: String
        let payload: Payload
    }

    static func encode<Payload: Codable & Sendable>(_ payload: Payload, owner: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dataEncodingStrategy = .base64
        return try encoder.encode(Envelope(
            owner: owner, version: version, dateEncoding: dateEncoding, payload: payload
        ))
    }

    /// Validate the format before decoding business rows. Every snapshot and row
    /// property is nonoptional at the DTO level, so all keys must exist; nullable
    /// record values use the required nullable wrapper below, never decodeIfPresent.
    static func decode<Payload: Codable & Sendable>(
        _ type: Payload.Type, from data: Data, owner: String
    ) throws -> Payload {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        let header = try decoder.decode(Header.self, from: data)
        guard header.owner == owner else { throw Failure.wrongOwner }
        guard header.version == version else { throw Failure.unsupportedVersion(header.version) }
        guard header.dateEncoding == dateEncoding else { throw Failure.unsupportedDateEncoding }
        return try decoder.decode(Envelope<Payload>.self, from: data).payload
    }
}

/// Required JSON key with an explicit null value. Synthesized decoding of an
/// ordinary Optional would silently accept a missing business-record field.
struct ProductFeedbackPersistenceNullable<Value: Codable & Sendable>: Codable, Sendable {
    let value: Value?

    init(_ value: Value?) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else {
            value = try container.decode(Value.self)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value {
            try container.encode(value)
        } else {
            try container.encodeNil()
        }
    }
}

/// Preserve every Date interval bit, including signed zero and nonfinite values.
/// No floating-point JSON conversion or epoch/unit conversion takes place.
struct ProductFeedbackPersistenceDate: Codable, Sendable {
    private let bits: UInt64

    init(_ value: Date) {
        bits = value.timeIntervalSinceReferenceDate.bitPattern
    }

    var value: Date {
        Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard encoded.utf8.count == 16,
              encoded.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let decoded = UInt64(encoded, radix: 16) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid feedback date bits")
        }
        bits = decoded
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let encoded = String(bits, radix: 16)
        try container.encode(String(repeating: "0", count: 16 - encoded.count) + encoded)
    }
}
