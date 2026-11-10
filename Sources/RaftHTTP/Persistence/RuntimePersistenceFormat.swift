import Foundation

/// These errors never include persisted keys, tokens, bytes or decoder coding paths.
enum RuntimePersistenceError: Error, Sendable, Equatable {
    case invalidSnapshot
    case unsupportedVersion(Int)
    case unsupportedDateEncoding
}

/// A required nullable field. Unlike a synthesized Optional property, a missing
/// JSON key is a schema error, while an explicit JSON null remains a valid value.
struct RuntimePersistenceNullable<Value: Codable & Sendable>: Codable, Sendable {
    let value: Value?

    init(_ value: Value?) { self.value = value }

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
        if let value { try container.encode(value) } else { try container.encodeNil() }
    }
}

/// Private wire format for the two runtime owners. Data and embedded JSON strings
/// are encoded as bytes/base64 and strings; embedded JSON is never parsed again.
/// Dates store the complete Foundation reference-seconds Double bit pattern.
/// Integer values use Swift's typed integer encoder/decoder, without a Double hop.
enum RuntimePersistenceFormat {
    static let version = 1
    static let dateEncoding = "foundation-reference-date-ieee754-binary64-hex"

    private struct Header: Decodable {
        let domain: String
        let version: Int
        let dateEncoding: String
    }

    private struct Envelope<Payload: Codable & Sendable>: Codable, Sendable {
        let domain: String
        let version: Int
        let dateEncoding: String
        let payload: Payload
    }

    static func encode<Payload: Codable & Sendable>(_ payload: Payload, domain: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dataEncodingStrategy = .base64
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let bits = String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
            try container.encode(String(repeating: "0", count: 16 - bits.count) + bits)
        }
        do {
            return try encoder.encode(Envelope(
                domain: domain, version: version, dateEncoding: dateEncoding, payload: payload
            ))
        } catch {
            throw RuntimePersistenceError.invalidSnapshot
        }
    }

    /// The header, every required table, nullable key, nested row and scalar type
    /// is decoded before the caller acquires a mutation borrow on either owner.
    static func decode<Payload: Codable & Sendable>(
        _ type: Payload.Type, from data: Data, domain: String
    ) throws -> Payload {
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: data) }
        catch { throw RuntimePersistenceError.invalidSnapshot }
        guard header.domain == domain else { throw RuntimePersistenceError.invalidSnapshot }
        guard header.version == version else { throw RuntimePersistenceError.unsupportedVersion(header.version) }
        guard header.dateEncoding == dateEncoding else { throw RuntimePersistenceError.unsupportedDateEncoding }
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard text.utf8.count == 16,
                  text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let bits = UInt64(text, radix: 16)
            else { throw RuntimePersistenceError.invalidSnapshot }
            return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
        }
        do { return try decoder.decode(Envelope<Payload>.self, from: data).payload }
        catch { throw RuntimePersistenceError.invalidSnapshot }
    }
}
