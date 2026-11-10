import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cloudflare Email Sending REST I/O (not Email Routing). Positive recipient
/// acceptance is required; success=true or a message ID alone is insufficient.
/// Cloudflare does not document provider idempotency for this API. A lost HTTP
/// response or lost durable acknowledgement can therefore cause duplicate mail.
public final class CloudflareTransactionalEmailSender: TransactionalEmailSending {
    private let configuration: TransactionalEmailConfiguration
    private let transport: TransactionalEmailTransport

    public init(configuration: TransactionalEmailConfiguration) {
        self.configuration = configuration
        transport = TransactionalEmailTransport()
    }

    /// Stops new tasks, cancels outstanding ones, waits a bounded time for the
    /// session invalidation callback, then retires the session so its
    /// multi-handle teardown cannot run during process shutdown.
    public func shutdown() async {
        await transport.shutdown()
    }

    public func send(
        _ intent: TransactionalEmailIntent, outboxID: String, now: Date = Date()
    ) async throws -> TransactionalEmailReceipt {
        guard configuration.provider == .cloudflare else { throw TransactionalEmailError.invalidConfiguration }
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
        // Do not invent Idempotency-Key or Message-ID guarantees for this API.
        request.httpBody = try JSONEncoder().encode(CloudflareEmailRequest(
            from: CloudflareEmailAddress(configuration.from), to: message.to,
            subject: message.subject, html: message.html, text: message.text
        ))
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport.perform(request) }
        catch { throw TransactionalEmailError.transportFailure }
        guard let http = response as? HTTPURLResponse else {
            throw TransactionalEmailError.invalidProviderResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // Provider bodies can repeat recipient addresses and private links.
            throw TransactionalEmailError.providerRejected(status: http.statusCode)
        }
        guard data.count <= 65_536,
              let envelope = try? JSONDecoder().decode(CloudflareEmailResponse.self, from: data) else {
            throw TransactionalEmailError.invalidProviderResponse
        }
        guard envelope.success, envelope.errors?.isEmpty != false else {
            throw TransactionalEmailError.providerRejected(status: http.statusCode)
        }
        guard let result = envelope.result else { throw TransactionalEmailError.invalidProviderResponse }
        let suppressed = result.suppressedRecipients
        guard !result.permanentBounces.contains(message.to), !suppressed.contains(message.to) else {
            throw TransactionalEmailError.recipientRejected
        }
        guard result.permanentBounces.isEmpty, suppressed.isEmpty,
              result.delivered + result.queued == [message.to] else {
            throw TransactionalEmailError.invalidProviderResponse
        }
        if let id = result.messageID {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf8.count <= 1024,
                  !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw TransactionalEmailError.invalidProviderResponse
            }
        }
        // Current API reference supplies message_id; an older official REST
        // example omits it. Preserve that absence instead of fabricating an ID.
        return TransactionalEmailReceipt(providerMessageID: result.messageID)
    }
}

private struct CloudflareEmailAddress: Encodable {
    let address: String
    let name: String?

    init(_ from: String) {
        if let left = from.lastIndex(of: "<"), from.hasSuffix(">") {
            address = String(from[from.index(after: left)..<from.index(before: from.endIndex)])
            let display = String(from[..<left]).trimmingCharacters(in: .whitespacesAndNewlines)
            name = display.isEmpty ? nil : display
        } else {
            address = from
            name = nil
        }
    }
}

private struct CloudflareEmailRequest: Encodable {
    let from: CloudflareEmailAddress
    let to: String
    let subject: String
    let html: String
    let text: String
}

private struct CloudflareEmailResponse: Decodable {
    let success: Bool
    let result: CloudflareEmailAcceptance?
    let errors: [CloudflareEmailAPIError]?
}

private struct CloudflareEmailAPIError: Decodable { let code: Int? }

private struct CloudflareEmailAcceptance: Decodable {
    let messageID: String?
    let delivered: [String]
    let queued: [String]
    let permanentBounces: [String]
    let suppressedRecipients: [String]

    enum CodingKeys: String, CodingKey {
        case delivered, queued
        case messageID = "message_id"
        case permanentBounces = "permanent_bounces"
        case suppressedRecipients = "suppressed_recipients"
    }
}
