import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider acceptance is not proof of mailbox delivery. Some Cloudflare REST
/// responses omit their provider message ID; that absence is never fabricated.
public struct TransactionalEmailReceipt: Sendable, Equatable {
    public let providerMessageID: String?
}

/// Real Resend REST I/O with no console-success fallback and no transport spy.
/// Credentials are sent only in Authorization, never in the URL. Redirects are
/// refused so a redirect cannot forward the recipient/token payload elsewhere.
public final class ResendTransactionalEmailSender: TransactionalEmailSending {
    private let configuration: TransactionalEmailConfiguration
    private let session: URLSession

    public init(configuration: TransactionalEmailConfiguration) {
        self.configuration = configuration
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 30
        settings.timeoutIntervalForResource = 40
        settings.httpShouldSetCookies = false
        settings.urlCache = nil
        session = URLSession(configuration: settings, delegate: TransactionalEmailNoRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func deliver(
        kind: String, codec: String, payload: Data, outboxID: String, now: Date = Date()
    ) async throws -> TransactionalEmailReceipt {
        let intent = try TransactionalEmailIntent.decodeOutboxPayload(kind: kind, codec: codec, payload: payload)
        return try await send(intent, outboxID: outboxID, now: now)
    }

    public func send(
        _ intent: TransactionalEmailIntent, outboxID: String, now: Date = Date()
    ) async throws -> TransactionalEmailReceipt {
        guard configuration.provider == .resend else { throw TransactionalEmailError.invalidConfiguration }
        guard intent.expiresAt > now else { throw TransactionalEmailError.expiredIntent }
        guard !outboxID.isEmpty, outboxID.utf8.count <= 200,
              outboxID.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                      || byte == 45 || byte == 46 || byte == 95
              }) else { throw TransactionalEmailError.invalidOutboxIdentifier }
        let message = try intent.message()
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("raft-email-\(outboxID)", forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(ResendRequest(
            from: configuration.from, to: [message.to], subject: message.subject,
            html: message.html, text: message.text
        ))
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw TransactionalEmailError.transportFailure }
        guard let http = response as? HTTPURLResponse else {
            throw TransactionalEmailError.invalidProviderResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // Never expose the provider's body; it may repeat addresses or links.
            throw TransactionalEmailError.providerRejected(status: http.statusCode)
        }
        guard data.count <= 65_536,
              let accepted = try? JSONDecoder().decode(ResendAcceptance.self, from: data),
              !accepted.id.isEmpty, accepted.id.utf8.count <= 1024,
              !accepted.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TransactionalEmailError.invalidProviderResponse
        }
        return TransactionalEmailReceipt(providerMessageID: accepted.id)
    }
}

private struct ResendRequest: Encodable {
    let from: String
    let to: [String]
    let subject: String
    let html: String
    let text: String
}

private struct ResendAcceptance: Decodable { let id: String }

final class TransactionalEmailNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
