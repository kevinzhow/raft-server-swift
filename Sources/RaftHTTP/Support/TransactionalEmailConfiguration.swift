import Foundation

public enum TransactionalEmailError: DomainError, Equatable {
    case notConfigured
    case durableOutboxUnavailable
    case invalidConfiguration
    case invalidPayload
    case expiredIntent
    case invalidOutboxIdentifier
    case transportFailure
    case invalidProviderResponse
    case recipientRejected
    case providerRejected(status: Int)

    public var status: UInt { 503 }
    public var errorMessage: String { "Transactional email is unavailable" }

    public var retryable: Bool {
        switch self {
        case .transportFailure, .invalidProviderResponse: true
        case .providerRejected(let status): status == 408 || status == 409 || status == 429 || status >= 500
        default: false
        }
    }
}

public enum TransactionalEmailProvider: String, Sendable {
    case resend, cloudflare
}

/// Secrets remain outside durable payloads and diagnostics. A valid configuration
/// is not proof of account entitlement, sender verification, or mailbox delivery.
public struct TransactionalEmailConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let apiKey: String
    public let provider: TransactionalEmailProvider
    public let from: String
    public let webURL: URL
    let endpoint: URL

    public init(resendAPIKey: String, from: String, webURL: URL) throws {
        try self.init(
            provider: .resend, apiKey: resendAPIKey, from: from, webURL: webURL,
            endpoint: URL(string: "https://api.resend.com/emails")!, allowLoopbackHTTP: false
        )
    }

    public init(cloudflareAPIToken: String, accountID: String, from: String, webURL: URL) throws {
        guard accountID.utf8.count == 32, accountID.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw TransactionalEmailError.invalidConfiguration }
        try self.init(
            provider: .cloudflare, apiKey: cloudflareAPIToken, from: from, webURL: webURL,
            endpoint: URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/email/sending/send")!,
            allowLoopbackHTTP: false
        )
    }

    /// Cloudflare Email Sending uses its account REST API, not Email Routing.
    /// APP_URL must serve the actual Web verification/reset query-token flow.
    public static func fromEnvironment(_ environment: [String: String]) throws -> Self {
        guard let provider = TransactionalEmailProvider(rawValue: environment["RAFT_EMAIL_PROVIDER", default: "resend"])
        else { throw TransactionalEmailError.invalidConfiguration }
        guard let from = environment["FROM_EMAIL"], !from.isEmpty,
              let rawURL = environment["APP_URL"], !rawURL.isEmpty else {
            throw TransactionalEmailError.notConfigured
        }
        guard let webURL = URL(string: rawURL) else { throw TransactionalEmailError.invalidConfiguration }
        switch provider {
        case .resend:
            guard let key = environment["RESEND_API_KEY"], !key.isEmpty else {
                throw TransactionalEmailError.notConfigured
            }
            return try Self(resendAPIKey: key, from: from, webURL: webURL)
        case .cloudflare:
            guard let token = environment["CLOUDFLARE_EMAIL_API_TOKEN"], !token.isEmpty,
                  let accountID = environment["CLOUDFLARE_ACCOUNT_ID"], !accountID.isEmpty else {
                throw TransactionalEmailError.notConfigured
            }
            return try Self(cloudflareAPIToken: token, accountID: accountID, from: from, webURL: webURL)
        }
    }

    /// Explicit local network acceptance only; production env parsing never
    /// selects a custom endpoint or a console-success sender.
    public static func localMailbox(apiKey: String, from: String, webURL: URL, endpoint: URL) throws -> Self {
        try Self(provider: .resend, apiKey: apiKey, from: from, webURL: webURL, endpoint: endpoint, allowLoopbackHTTP: true)
    }

    public static func cloudflareLocalMailbox(apiToken: String, from: String, webURL: URL, endpoint: URL) throws -> Self {
        guard let host = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?.host,
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) else {
            throw TransactionalEmailError.invalidConfiguration
        }
        return try Self(provider: .cloudflare, apiKey: apiToken, from: from, webURL: webURL, endpoint: endpoint, allowLoopbackHTTP: true)
    }

    private init(
        provider: TransactionalEmailProvider, apiKey: String, from: String, webURL: URL,
        endpoint: URL, allowLoopbackHTTP: Bool
    ) throws {
        guard !apiKey.isEmpty,
              !apiKey.contains(where: { $0.isWhitespace || $0.isNewline }),
              !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !from.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TransactionalEmailError.invalidConfiguration
        }
        let mailbox: String
        if let left = from.lastIndex(of: "<"), from.hasSuffix(">") {
            mailbox = String(from[from.index(after: left)..<from.index(before: from.endIndex)])
        } else { mailbox = from }
        guard TransactionalEmailIntent.validAddress(mailbox),
              let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (allowLoopbackHTTP && parts.scheme == "http"
                && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())) else {
            throw TransactionalEmailError.invalidConfiguration
        }
        try Self.validateWebURL(webURL)
        self.provider = provider
        self.apiKey = apiKey
        self.from = from
        self.webURL = webURL
        self.endpoint = endpoint
    }

    static func validateWebURL(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw TransactionalEmailError.invalidConfiguration
        }
    }

    public var description: String { "TransactionalEmailConfiguration(\(provider.rawValue), credentials redacted)" }
    public var debugDescription: String { description }
}
