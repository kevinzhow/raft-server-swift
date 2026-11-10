import Foundation

/// Codec validation errors contain format metadata, never persisted business data.
enum CollaborationPersistenceError: Error, Sendable {
    case invalidFormat
    case unsupportedVersion(Int)
    case unsupportedDateEncoding
}

/// Owner-local snapshots, not a multi-owner transaction or durable PG commit.
/// All current State fields of these three owners are business facts and included.
/// Excluded: Mutex identities, executable methods/static policy constants. None of
/// these States contains live callbacks, runtime providers or connection handles.
/// ProviderConnection rows, pending events, stale-write holds and audience overrides
/// are business/security facts, not transient connections or simulation settings.
/// Embedded JSON is kept as String; no JSONValue or binary Data field occurs in
/// these owners. Native Int fields remain JSON integer tokens. Dates use the exact
/// IEEE-754 bits of Foundation's reference-date interval, including optional dates.
enum CollaborationPersistenceCoding {
    private static let version = 1
    private static let dates = "foundation-reference-date-ieee754-binary64-hex"

    static func encode<Value: Codable>(_ value: Value, format: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let bits = String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
            try container.encode(String(repeating: "0", count: 16 - bits.count) + bits)
        }
        return try encoder.encode(Envelope(format: format, version: version, dateEncoding: dates, business: value))
    }

    static func decode<Value: Codable>(_ type: Value.Type, from data: Data, format: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard text.utf8.count == 16,
                  text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let bits = UInt64(text, radix: 16) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid collaboration date bits")
            }
            return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
        }
        let snapshot = try decoder.decode(Envelope<Value>.self, from: data)
        guard snapshot.format == format else { throw CollaborationPersistenceError.invalidFormat }
        guard snapshot.version == version else { throw CollaborationPersistenceError.unsupportedVersion(snapshot.version) }
        guard snapshot.dateEncoding == dates else { throw CollaborationPersistenceError.unsupportedDateEncoding }
        return snapshot.business
    }

    private struct Envelope<Value: Codable>: Codable {
        let format: String
        let version: Int
        let dateEncoding: String
        let business: Value
    }
}
