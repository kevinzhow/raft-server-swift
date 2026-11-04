import Foundation

/// App setup declaration contract: configuration progress is separate from
/// every installation permission. The setup URL must be HTTPS (loopback HTTP
/// allowed) with no credentials and no fragment, carries exactly the
/// installation/server/revision context, and completion is bound to the
/// declaration revision. Ported from the shared contract used by the server.
public struct AppSetupValidationError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

public struct AppSetupState: Sendable, Equatable {
    public enum Status: String, Sendable { case notRequired = "not_required", pending, complete }
    public var status: Status
    public var url: String?
    public var description: String?
    public var revision: Int
    public var completedAt: String?
}

public enum AppSetupContract {
    public static let maxURLLength = 2000
    public static let maxDescriptionLength = 500

    /// HTTPS (or loopback HTTP), without credentials or fragment.
    public static func isSafeOAuthReturnURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.user == nil, components.password == nil, components.fragment == nil,
              let host = components.host?.lowercased(), !host.isEmpty
        else { return false }
        if scheme == "https" { return true }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    public static func normalizeSetupUrl(_ raw: String?) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.count <= maxURLLength else {
            throw AppSetupValidationError("setupUrl must be a URL of at most 2000 characters")
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard isSafeOAuthReturnURL(value) else {
            throw AppSetupValidationError("setupUrl must be HTTPS (or loopback HTTP), without credentials or fragment")
        }
        return value
    }

    public static func normalizeSetupDescription(_ raw: String?) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let hasControl = raw.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
        guard raw.count <= maxDescriptionLength, !hasControl else {
            throw AppSetupValidationError("setupDescription must be a single line of at most 500 characters")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func normalizeInstallationId(_ raw: String) throws -> String {
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        guard raw.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            throw AppSetupValidationError("installation_id must be an installation UUID")
        }
        return raw.lowercased()
    }

    static func isoString(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: value)
    }

    /// Projects the declaration plus this installation's completion into the
    /// setup state. The context identifiers are never credentials or proof of
    /// user authority.
    public static func project(
        setupUrl: String?,
        setupDescription: String?,
        setupRevision: Int,
        installationId: String,
        serverId: String,
        completedRevision: Int?,
        completedAt: Date?
    ) throws -> AppSetupState {
        guard let setupUrl else {
            return AppSetupState(
                status: .notRequired, url: nil, description: nil,
                revision: setupRevision, completedAt: nil
            )
        }
        let normalized = try normalizeSetupUrl(setupUrl)
        guard let normalized, var components = URLComponents(string: normalized) else {
            return AppSetupState(
                status: .notRequired, url: nil, description: nil,
                revision: setupRevision, completedAt: nil
            )
        }
        var items = components.queryItems ?? []
        items.removeAll { ["installation_id", "server_id", "setup_revision"].contains($0.name) }
        items.append(URLQueryItem(name: "installation_id", value: installationId))
        items.append(URLQueryItem(name: "server_id", value: serverId))
        items.append(URLQueryItem(name: "setup_revision", value: String(setupRevision)))
        components.queryItems = items
        let complete = completedRevision == setupRevision
        return AppSetupState(
            status: complete ? .complete : .pending,
            url: components.string,
            description: setupDescription,
            revision: setupRevision,
            completedAt: complete ? completedAt.map(isoString) : nil
        )
    }
}
