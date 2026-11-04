import Crypto
import Foundation

public struct PublicSearchServiceKey: Sendable, Equatable {
    public var keyId: String
    public var sha256: String
    public var expiresAt: Date?

    public init(keyId: String, sha256: String, expiresAt: Date? = nil) {
        self.keyId = keyId
        self.sha256 = sha256
        self.expiresAt = expiresAt
    }
}

public protocol PublicSearchServiceKeyProviding: Sendable {
    func keys() throws -> [PublicSearchServiceKey]
}

public struct PublicSearchStaticKeySource: PublicSearchServiceKeyProviding {
    private let rows: [PublicSearchServiceKey]

    public init(_ rows: [PublicSearchServiceKey]) {
        self.rows = rows
    }

    public func keys() throws -> [PublicSearchServiceKey] { rows }
}

public enum PublicSearchBucketDecision: Sendable, Equatable {
    case allowed
    case rateLimited(retryAfter: Int)
    case unavailable
}

public protocol PublicSearchBucketStoring: Sendable {
    func consume(limit: Int) -> PublicSearchBucketDecision
}

public final class PublicSearchMemoryBucketStore: PublicSearchBucketStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var windowStart: Date
    private var used = 0

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        self.windowStart = now()
    }

    public func consume(limit: Int) -> PublicSearchBucketDecision {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        if current.timeIntervalSince(windowStart) >= 60 {
            windowStart = current
            used = 0
        }
        guard used < limit else {
            let retry = max(1, min(60, Int(60 - current.timeIntervalSince(windowStart).rounded(.up))))
            return .rateLimited(retryAfter: retry)
        }
        used += 1
        return .allowed
    }
}

public struct PublicSearchServiceLimits: Sendable {
    public var ratePerMinute: Int
    public var maxInFlight: Int

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        func value(_ key: String, _ fallback: Int) -> Int {
            guard let raw = environment[key], let parsed = Int(raw) else { return fallback }
            return parsed
        }
        ratePerMinute = value("RAFT_LANDING_SERVICE_RATE_PER_MINUTE", 60)
        maxInFlight = value("RAFT_LANDING_SERVICE_MAX_IN_FLIGHT", 8)
    }
}

public enum PublicSearchServiceCredential: Sendable, Equatable {
    case anonymous
    case invalid
    case unavailable
    case service(keyId: String)
}

public enum PublicSearchServiceAccess {
    public static let clientId = "raft-landing"

    public static func classify(
        authorization: String?,
        keySource: (any PublicSearchServiceKeyProviding)?,
        clock: Date = Date()
    ) -> PublicSearchServiceCredential {
        guard let authorization, authorization.hasPrefix("Raft-Service") else { return .anonymous }
        let parts = authorization.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "Raft-Service", parts[1] == "v1" else { return .invalid }
        let pair = parts[2].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return .invalid }
        guard let keySource else { return .unavailable }
        let rows: [PublicSearchServiceKey]
        do {
            rows = try keySource.keys()
        } catch {
            return .unavailable
        }
        guard !rows.isEmpty, validKeySet(rows) else { return .unavailable }
        guard rows.contains(where: { $0.expiresAt == nil }) else { return .unavailable }
        guard let row = rows.first(where: { $0.keyId == pair[0] }) else { return .invalid }
        if let expiresAt = row.expiresAt, expiresAt <= clock { return .invalid }
        let digest = SHA256.hash(data: Data(pair[1].utf8)).map { String(format: "%02x", $0) }.joined()
        guard digest.count == row.sha256.count, timingSafeEqual(digest, row.sha256.lowercased()) else { return .invalid }
        return .service(keyId: row.keyId)
    }

    public static func validKeySet(_ rows: [PublicSearchServiceKey]) -> Bool {
        let ids = Set(rows.map(\.keyId))
        guard ids.count == rows.count else { return false }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        return rows.allSatisfy { row in
            row.sha256.count == 64 && row.sha256.unicodeScalars.allSatisfy { hex.contains($0) }
                && !row.keyId.isEmpty
        }
    }

    private static func timingSafeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    public static func refusal(_ credential: PublicSearchServiceCredential) -> (status: Int, code: String)? {
        switch credential {
        case .anonymous, .service: return nil
        case .invalid: return (401, "service_credential_invalid")
        case .unavailable: return (503, "service_unavailable")
        }
    }
}
