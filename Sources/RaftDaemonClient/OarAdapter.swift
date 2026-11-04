import Crypto
import Foundation

/// OAR (runtime account usage) → wire snapshot projection: mask identity, drop
/// unusable values instead of guessing, never let a failure read as zero
/// usage, and treat a reading above the wire's window ceiling as an explicit
/// error rather than a truncation. Ported from the upstream daemon adapter.
public enum RuntimeAccountUsageProvider: String, Sendable, Equatable, CaseIterable {
    case codex, claude, kimi
}

public enum RuntimeAccountUsageHealth: String, Sendable, Equatable {
    case ok, rateLimited = "rate_limited", unsupported, reauthRequired = "reauth_required", error
}

public struct OarWindow: Sendable, Equatable {
    public var label: String?
    public var usedRatio: Double?
    public var resetsAt: String?
    public init(label: String? = nil, usedRatio: Double? = nil, resetsAt: String? = nil) {
        self.label = label
        self.usedRatio = usedRatio
        self.resetsAt = resetsAt
    }
}

public enum OarSnapshotKind: String, Sendable, Equatable {
    case available, unsupported, reauthRequired = "reauth_required"
}

public struct OarAccountUsageSnapshot: Sendable, Equatable {
    public var kind: OarSnapshotKind
    public var email: String?
    public var plan: String?
    public var displayName: String?
    public var rateLimited: Bool
    public var windows: [OarWindow]
    public init(
        kind: OarSnapshotKind, email: String? = nil, plan: String? = nil, displayName: String? = nil,
        rateLimited: Bool = false, windows: [OarWindow] = []
    ) {
        self.kind = kind
        self.email = email
        self.plan = plan
        self.displayName = displayName
        self.rateLimited = rateLimited
        self.windows = windows
    }
}

public struct RuntimeAccountUsageWindow: Sendable, Equatable {
    public var id: String
    public var label: String
    public var status: String
    public var usedRatio: Double?
    public var resetsAt: String?
    public init(id: String, label: String, status: String, usedRatio: Double? = nil, resetsAt: String? = nil) {
        self.id = id
        self.label = label
        self.status = status
        self.usedRatio = usedRatio
        self.resetsAt = resetsAt
    }
}

public struct RuntimeAccountUsageAccount: Sendable, Equatable {
    public var accountKey: String
    public var maskedLabel: String?
    public var planLabel: String?
    public var displayName: String?
    public var health: RuntimeAccountUsageHealth
    public var parseErrorCode: String?
    public var windows: [RuntimeAccountUsageWindow]
}

public struct RuntimeAccountUsageSnapshot: Sendable, Equatable {
    public var protocolVersion = 2
    public var provider: RuntimeAccountUsageProvider
    public var collectedAt: String
    public var staleAfter: String
    public var collectorVersion: String
    public var accounts: [RuntimeAccountUsageAccount]

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "protocolVersion": protocolVersion,
            "provider": provider.rawValue,
            "collectedAt": collectedAt,
            "staleAfter": staleAfter,
            "collectorVersion": collectorVersion,
        ]
        object["accounts"] = accounts.map { account -> [String: Any] in
            var row: [String: Any] = ["accountKey": account.accountKey, "health": account.health.rawValue]
            if let maskedLabel = account.maskedLabel { row["maskedLabel"] = maskedLabel }
            if let planLabel = account.planLabel { row["planLabel"] = planLabel }
            if let displayName = account.displayName { row["displayName"] = displayName }
            if let parseErrorCode = account.parseErrorCode { row["parseErrorCode"] = parseErrorCode }
            row["windows"] = account.windows.map { window -> [String: Any] in
                var value: [String: Any] = ["id": window.id, "label": window.label, "status": window.status]
                if let usedRatio = window.usedRatio { value["usedRatio"] = usedRatio }
                if let resetsAt = window.resetsAt { value["resetsAt"] = resetsAt }
                return value
            }
            return row
        }
        return object
    }
}

public enum OarAdapter {
    public static let protocolVersion = 2
    public static let staleAfterMs = 30 * 60 * 1000
    public static let maxWireWindows = 12
    static let controlChars = CharacterSet(charactersIn: "\u{0000}"..."\u{001f}").union(CharacterSet(charactersIn: "\u{007f}"))

    public static func safeLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        guard trimmed.rangeOfCharacter(from: controlChars) == nil else { return nil }
        return trimmed
    }

    public static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func accountKey(provider: RuntimeAccountUsageProvider, localAccountSlot: String) -> String {
        sha256Hex(provider.rawValue + "\u{0000}" + localAccountSlot)
    }

    static func windowId(label: String, index: Int) -> String {
        "w\(index)_" + String(sha256Hex(label).prefix(12))
    }

    public static func maskEmail(_ value: String?) -> String? {
        guard let value else { return nil }
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, email.count <= 254 else { return nil }
        let scalars = email.unicodeScalars
        guard !scalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }) else { return nil }
        let parts = email.components(separatedBy: "@")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let local = parts[0]
        let domain = parts[1].lowercased()
        guard local.count <= 64, domain.count <= 63 else { return nil }
        guard !local.hasPrefix("."), !local.hasSuffix("."), !local.contains("..") else { return nil }
        guard local.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+$"#, options: .regularExpression) != nil else { return nil }
        let labels = domain.components(separatedBy: ".")
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil
            else { return nil }
        }
        let prefixLength = local.count >= 8 ? 3 : 1
        let remaining = local.count - prefixLength
        let suffixLength = remaining > 4 ? min(5, remaining - 4) : 0
        let originalLocal = email.components(separatedBy: "@")[0]
        let prefix = String(originalLocal.prefix(prefixLength))
        let suffix = suffixLength > 0 ? String(originalLocal.suffix(suffixLength)) : ""
        let masked = "\(prefix)****\(suffix)@\(domain)"
        return masked.count <= 80 ? masked : nil
    }

    static func isoString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }

    static func isoOrUndefined(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let parsed = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            return nil
        }
        return isoString(parsed)
    }

    public static func project(
        provider: RuntimeAccountUsageProvider,
        snapshot: OarAccountUsageSnapshot,
        localAccountSlot: String,
        collectorVersion: String,
        observedAtMs: Int
    ) -> RuntimeAccountUsageSnapshot {
        let accountKey = accountKey(provider: provider, localAccountSlot: localAccountSlot)
        let observedAt = Date(timeIntervalSince1970: Double(observedAtMs) / 1000)
        let baseCollected = isoString(observedAt)
        let baseStale = isoString(observedAt.addingTimeInterval(Double(staleAfterMs) / 1000))

        if snapshot.kind == .unsupported || snapshot.kind == .reauthRequired {
            let health: RuntimeAccountUsageHealth = snapshot.kind == .unsupported ? .unsupported : .reauthRequired
            return RuntimeAccountUsageSnapshot(
                provider: provider, collectedAt: baseCollected, staleAfter: baseStale,
                collectorVersion: collectorVersion,
                accounts: [.init(accountKey: accountKey, health: health, windows: [])]
            )
        }

        let maskedLabel = maskEmail(snapshot.email)
        let planLabel = safeLabel(snapshot.plan)
        let displayName = maskedLabel == nil ? safeLabel(snapshot.displayName) : nil
        var sawUnreadableRatio = false

        var windows: [RuntimeAccountUsageWindow] = []
        for (index, window) in snapshot.windows.enumerated() {
            let label = safeLabel(window.label) ?? "Usage limit"
            let id = windowId(label: label, index: index)
            let usable = window.usedRatio.map { $0.isFinite && $0 >= 0 && $0 <= 1 } ?? false
            if !usable {
                sawUnreadableRatio = true
                windows.append(.init(id: id, label: label, status: "parse_unavailable"))
                continue
            }
            let ratio = window.usedRatio!
            let resetsAt = isoOrUndefined(window.resetsAt)
            windows.append(.init(
                id: id, label: label, status: ratio >= 1 ? "limit_reached" : "ok",
                usedRatio: (ratio * 1_000_000).rounded() / 1_000_000,
                resetsAt: resetsAt
            ))
        }

        if windows.count > maxWireWindows {
            return RuntimeAccountUsageSnapshot(
                provider: provider, collectedAt: baseCollected, staleAfter: baseStale,
                collectorVersion: collectorVersion,
                accounts: [.init(
                    accountKey: accountKey, maskedLabel: maskedLabel, planLabel: planLabel,
                    displayName: displayName, health: .error, windows: []
                )]
            )
        }

        let health: RuntimeAccountUsageHealth = snapshot.rateLimited ? .rateLimited : .ok
        return RuntimeAccountUsageSnapshot(
            provider: provider, collectedAt: baseCollected, staleAfter: baseStale,
            collectorVersion: collectorVersion,
            accounts: [.init(
                accountKey: accountKey, maskedLabel: maskedLabel, planLabel: planLabel,
                displayName: displayName, health: health,
                parseErrorCode: sawUnreadableRatio ? "oar_window_ratio_unreadable" : nil,
                windows: windows
            )]
        )
    }

    /// A failed read becomes an explicit `error` account with NO windows —
    /// never a zero-usage reading.
    public static func failure(
        provider: RuntimeAccountUsageProvider,
        localAccountSlot: String,
        collectorVersion: String,
        observedAtMs: Int
    ) -> RuntimeAccountUsageSnapshot {
        let observedAt = Date(timeIntervalSince1970: Double(observedAtMs) / 1000)
        return RuntimeAccountUsageSnapshot(
            provider: provider,
            collectedAt: isoString(observedAt),
            staleAfter: isoString(observedAt.addingTimeInterval(Double(staleAfterMs) / 1000)),
            collectorVersion: collectorVersion,
            accounts: [.init(
                accountKey: accountKey(provider: provider, localAccountSlot: localAccountSlot),
                health: .error, windows: []
            )]
        )
    }
}
