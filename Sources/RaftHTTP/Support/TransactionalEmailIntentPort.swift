import Foundation
import RaftShared

/// Production auth services stage confidential data in the active transaction.
/// The PostgreSQL coordinator must persist these envelopes in the same commit
/// as the account/token rows. No network I/O or after-commit closure is used here.
/// Binding this port alone does not make the coordinator or worker durable.
public struct TransactionalEmailIntentPort: Sendable {
    private let webURL: URL?

    private init(webURL: URL?) { self.webURL = webURL }

    /// Preserves the existing in-memory acceptance seams. This mode refuses
    /// production domains; it is never a successful production delivery mode.
    public static let developmentOnly = Self(webURL: nil)

    public static func durable(configuration: TransactionalEmailConfiguration) -> Self {
        Self(webURL: configuration.webURL)
    }

    func requireReady(in domain: TransactionDomain) throws {
        if webURL == nil {
            guard !domain.isReadOnlyUnscoped,
                  ProcessInfo.processInfo.environment["NODE_ENV"] != "production" else {
                throw TransactionalEmailError.notConfigured
            }
            return
        }
        // Preflight before any token/account mutation. The shared implementation
        // checks the active context, domain and open durable effect buffer.
        do { try DeferredEffects.requireDurableTransaction(in: domain) }
        catch { throw TransactionalEmailError.durableOutboxUnavailable }
    }

    func allowsDevelopmentAutoVerification(in domain: TransactionDomain) -> Bool {
        webURL == nil && !domain.isReadOnlyUnscoped
            && ProcessInfo.processInfo.environment["NODE_ENV"] != "production"
    }

    func verification(recipientEmail: String, name: String, rawToken: String, issuedAt: Date) throws {
        try record(
            kind: .verifyEmail, recipientEmail: recipientEmail, name: name,
            rawToken: rawToken, issuedAt: issuedAt, lifetime: 24 * 60 * 60
        )
    }

    func passwordReset(recipientEmail: String, name: String, rawToken: String, issuedAt: Date) throws {
        try record(
            kind: .resetPassword, recipientEmail: recipientEmail, name: name,
            rawToken: rawToken, issuedAt: issuedAt, lifetime: 60 * 60
        )
    }

    private func record(
        kind: TransactionalEmailIntent.Kind, recipientEmail: String, name: String,
        rawToken: String, issuedAt: Date, lifetime: TimeInterval
    ) throws {
        guard let webURL else { return }
        do {
            let intent = try TransactionalEmailIntent(
                kind: kind, recipientEmail: recipientEmail, recipientName: name,
                rawToken: rawToken, webURL: webURL, issuedAt: issuedAt,
                expiresAt: issuedAt.addingTimeInterval(lifetime)
            )
            try DeferredEffects.persist(kind: kind.rawValue, payload: intent.encodeOutboxPayload())
        } catch {
            DeferredEffects.markRollbackOnly()
            throw TransactionalEmailError.durableOutboxUnavailable
        }
    }
}

/// Internal recipient facts from the account owner, with no token or Store leak.
struct TransactionalEmailRecipient: Sendable {
    let email: String
    let name: String
}
