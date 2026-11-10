import Foundation

/// A payload is opaque outside its owner. The caller supplies any cross-owner
/// transaction boundary; these codecs do not create one.
enum MessagingPersistenceFormat {
    static let version = 1

    private struct Header: Decodable {
        let version: Int
        let owner: String
    }

    private struct Envelope<Payload: Codable & Sendable>: Codable, Sendable {
        let version: Int
        let owner: String
        let payload: Payload
    }

    static func encode<Payload: Codable & Sendable>(_ payload: Payload, owner: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Envelope(version: version, owner: owner, payload: payload))
    }

    static func decode<Payload: Codable & Sendable>(
        _ type: Payload.Type, from data: Data, owner: String
    ) throws -> Payload {
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        guard header.version == version else {
            throw MessagingPersistenceError.unsupportedVersion(owner: header.owner, version: header.version)
        }
        guard header.owner == owner else {
            throw MessagingPersistenceError.wrongOwner(expected: owner, actual: header.owner)
        }
        return try decoder.decode(Envelope<Payload>.self, from: data).payload
    }
}

enum MessagingPersistenceError: Error, Sendable {
    case unsupportedVersion(owner: String, version: Int)
    case wrongOwner(expected: String, actual: String)
}

/// Codable's ordinary Date strategies can round timestamps. Store the exact
/// Foundation reference-interval bits instead; UInt64 and Data remain typed.
struct MessagingPersistenceDateBits: Codable, Sendable {
    let referenceIntervalBits: UInt64

    init(_ value: Date) {
        referenceIntervalBits = value.timeIntervalSinceReferenceDate.bitPattern
    }

    var value: Date {
        Date(timeIntervalSinceReferenceDate: Double(bitPattern: referenceIntervalBits))
    }
}
