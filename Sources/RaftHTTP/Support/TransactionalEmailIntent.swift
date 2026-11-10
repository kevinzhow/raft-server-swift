import Foundation

/// Confidential outbox data, never an HTTP response or a log value. The token
/// hash stays in the account ledger; the raw token must survive a process crash
/// in the same database transaction as that ledger write.
public struct TransactionalEmailIntent: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: String, Codable, Sendable {
        case verifyEmail = "auth.verify-email.v1"
        case resetPassword = "auth.reset-password.v1"
    }

    public static let payloadCodec = "raft.transactional-email.v1"
    public let codec: String
    public let kind: Kind
    public let recipientEmail: String
    private let recipientName: String
    private let rawToken: String
    private let webURL: URL
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        kind: Kind, recipientEmail: String, recipientName: String,
        rawToken: String, webURL: URL, issuedAt: Date, expiresAt: Date
    ) throws {
        self.codec = Self.payloadCodec
        self.kind = kind
        self.recipientEmail = recipientEmail
        self.recipientName = recipientName
        self.rawToken = rawToken
        self.webURL = webURL
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        try validate()
    }

    public var description: String { "TransactionalEmailIntent(\(kind.rawValue), confidential)" }
    public var debugDescription: String { description }

    /// JSON v1 uses milliseconds since Unix epoch for both dates. Treat this
    /// encoded payload as a secret: restrict DB access and never log/dead-letter
    /// the payload into public diagnostics.
    public func encodeOutboxPayload() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let payload = try encoder.encode(self)
        guard payload.count <= 32_768 else { throw TransactionalEmailError.invalidPayload }
        return payload
    }

    public static func decodeOutboxPayload(kind: String, codec: String, payload: Data) throws -> Self {
        guard codec == payloadCodec, payload.count <= 32_768 else {
            throw TransactionalEmailError.invalidPayload
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let intent: Self
        do { intent = try decoder.decode(Self.self, from: payload) }
        catch { throw TransactionalEmailError.invalidPayload }
        guard intent.kind.rawValue == kind else { throw TransactionalEmailError.invalidPayload }
        try intent.validate()
        return intent
    }

    func validate() throws {
        guard codec == Self.payloadCodec, !recipientEmail.isEmpty, recipientEmail.utf8.count <= 4096,
              !rawToken.isEmpty, rawToken.utf8.count <= 4096,
              recipientName.utf8.count <= 4096,
              issuedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > issuedAt else { throw TransactionalEmailError.invalidPayload }
        try TransactionalEmailConfiguration.validateWebURL(webURL)
    }

    static func validAddress(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 320 && !value.contains(where: { $0.isWhitespace || $0.isNewline })
            && !value.contains(where: { ",;<>\"".contains($0) })
            && value.split(separator: "@", omittingEmptySubsequences: false).count == 2
            && value.first != "@" && value.last != "@"
    }

    /// Upstream Web consumes ?verify= / ?reset= and then POSTs to the existing
    /// /api/auth/verify-email or /api/auth/reset-password endpoint. A GET to an
    /// invented API verification route cannot redeem these tokens.
    public func message() throws -> TransactionalEmailMessage {
        try validate()
        guard var components = URLComponents(url: webURL, resolvingAgainstBaseURL: false) else {
            throw TransactionalEmailError.invalidConfiguration
        }
        components.queryItems = [URLQueryItem(name: kind == .verifyEmail ? "verify" : "reset", value: rawToken)]
        guard let actionURL = components.url?.absoluteString else { throw TransactionalEmailError.invalidPayload }
        let verify = kind == .verifyEmail
        let title = verify ? "Verify your email" : "Reset your password"
        let action = verify ? "Verify Email" : "Reset Password"
        let explanation = verify
            ? "Click the link below to verify your email address:"
            : "Someone requested a password reset for your account. Use the link below to set a new password:"
        let expiry = verify ? "This link expires in 24 hours." : "This link expires in 1 hour."
        let ignore = verify
            ? "If you didn't create a Raft account, you can safely ignore this email."
            : "If you didn't request this, you can safely ignore this email."
        let name = recipientName.isEmpty ? "there" : recipientName
        let text = "\(title)\n\nHey \(name),\n\n\(explanation)\n\(actionURL)\n\n\(expiry) \(ignore)"
        let html = """
        <!doctype html><html><body><h1>\(Self.escapeHTML(title))</h1><p>Hey \(Self.escapeHTML(name)),</p><p>\(Self.escapeHTML(explanation))</p><p><a href="\(Self.escapeHTML(actionURL))">\(Self.escapeHTML(action))</a></p><p>Or copy this link: \(Self.escapeHTML(actionURL))</p><p>\(Self.escapeHTML(expiry)) \(Self.escapeHTML(ignore))</p></body></html>
        """
        return TransactionalEmailMessage(to: recipientEmail, subject: "\(title) — Raft", text: text, html: html)
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

public struct TransactionalEmailMessage: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let to: String
    public let subject: String
    public let text: String
    public let html: String
    public var description: String { "TransactionalEmailMessage(confidential)" }
    public var debugDescription: String { description }
}
