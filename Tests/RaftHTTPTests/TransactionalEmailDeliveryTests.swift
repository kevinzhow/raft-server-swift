import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing
@testable import RaftHTTP

private let deliveryNow = Date(timeIntervalSince1970: 1_800_000_000)
private let deliveryAddress = "reader@example.com"
private let deliveryPath = "/client/v4/accounts/" + String(repeating: "a", count: 32) + "/email/sending/send"
private let deliveryWebURL = URL(string: "https://raft.example.com")!

private func deliveryIntent(expired: Bool = false, kind: TransactionalEmailIntent.Kind = .verifyEmail) throws -> TransactionalEmailIntent {
    try TransactionalEmailIntent(
        kind: kind, recipientEmail: deliveryAddress, recipientName: "Reader",
        rawToken: "synthetic-verification-token", webURL: deliveryWebURL,
        issuedAt: deliveryNow.addingTimeInterval(-60), expiresAt: deliveryNow.addingTimeInterval(expired ? -1 : 3600)
    )
}

private func cloudflareAcceptance(_ result: String) -> String {
    "{\"success\":true,\"errors\":[],\"messages\":[],\"result\":\(result)}"
}

private func cloudflareAcceptedResult(messageID: Bool) -> String {
    "{\(messageID ? "\"message_id\":\"cf-message\"," : "")\"delivered\":[],\"queued\":[\"\(deliveryAddress)\"],\"permanent_bounces\":[],\"suppressed_recipients\":[]}"
}

private func cloudflareSender(_ mailbox: DeliveryMailbox) throws -> TransactionalEmailSender {
    TransactionalEmailSender(configuration: try .cloudflareLocalMailbox(
        apiToken: "synthetic-cloudflare-token", from: "Raft <noreply@mail.example.com>",
        webURL: deliveryWebURL, endpoint: mailbox.url(path: deliveryPath)
    ))
}

@Suite struct TransactionalEmailDeliveryTests {
    @Test func cloudflareWireContractAndOptionalProviderMessageID() async throws {
        for hasID in [true, false] {
            try await withDeliveryMailbox(body: cloudflareAcceptance(cloudflareAcceptedResult(messageID: hasID))) { mailbox in
                let intent = try deliveryIntent()
                let sender = try cloudflareSender(mailbox)
                let receipt = try await sender.deliver(
                    kind: intent.kind.rawValue, codec: TransactionalEmailIntent.payloadCodec,
                    payload: intent.encodeOutboxPayload(), outboxID: "cloudflare-outbox", now: deliveryNow
                )
                #expect(receipt.providerMessageID == (hasID ? "cf-message" : nil))
                let requests = mailbox.requests
                #expect(requests.count == 1)
                let request = try #require(requests.first)
                #expect(request.method == "POST")
                #expect(request.uri == deliveryPath)
                #expect(request.headers["authorization"] == "Bearer synthetic-cloudflare-token")
                #expect(request.headers["content-type"] == "application/json")
                #expect(request.headers["content-length"] == String(request.body.count))
                #expect(request.headers["idempotency-key"] == nil)
                let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
                let from = try #require(body["from"] as? [String: String])
                #expect(from == ["address": "noreply@mail.example.com", "name": "Raft"])
                #expect(body["to"] as? String == deliveryAddress)
                #expect(body["subject"] as? String == "Verify your email — Raft")
                #expect((body["text"] as? String)?.contains("https://raft.example.com?verify=synthetic-verification-token") == true)
                #expect((body["html"] as? String)?.contains("synthetic-verification-token") == true)
            }
        }
        let delivered = "{\"message_id\":\"cf-delivered\",\"delivered\":[\"\(deliveryAddress)\"],\"queued\":[],\"permanent_bounces\":[],\"suppressed_recipients\":[]}"
        try await withDeliveryMailbox(body: cloudflareAcceptance(delivered)) { mailbox in
            let receipt = try await cloudflareSender(mailbox).send(deliveryIntent(kind: .resetPassword), outboxID: "delivered", now: deliveryNow)
            #expect(receipt.providerMessageID == "cf-delivered")
            let request = try #require(mailbox.requests.first)
            let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            #expect(body["subject"] as? String == "Reset your password — Raft")
            #expect((body["text"] as? String)?.contains("https://raft.example.com?reset=synthetic-verification-token") == true)
            #expect((body["html"] as? String)?.contains("?reset=synthetic-verification-token") == true)
        }
    }

    @Test func cloudflareRequiresTruthfulRecipientAcceptance() async throws {
        let malformedResults = [
            "null", "{}", "[]", "\"accepted\"",
            "{\"queued\":[\"\(deliveryAddress)\"],\"delivered\":[],\"permanent_bounces\":[]}",
            "{\"queued\":[\"\(deliveryAddress)\"],\"delivered\":[],\"permanent_bounces\":[],\"suppressed_recipients\":null}",
            "{\"message_id\":\"cf-message\",\"delivered\":[],\"queued\":[],\"permanent_bounces\":[],\"suppressed_recipients\":[]}",
            "{\"queued\":[\"other@example.com\"],\"delivered\":[],\"permanent_bounces\":[],\"suppressed_recipients\":[]}",
            "{\"queued\":[\"\(deliveryAddress)\",\"other@example.com\"],\"delivered\":[],\"permanent_bounces\":[],\"suppressed_recipients\":[]}",
            "{\"queued\":\"\(deliveryAddress)\",\"delivered\":[],\"permanent_bounces\":[],\"suppressed_recipients\":[]}"
        ]
        let invalidIDResults = ["", " ", "bad\\u0000id"].map {
            cloudflareAcceptedResult(messageID: true).replacingOccurrences(of: "cf-message", with: $0)
        }
        let rejectedBodies = (malformedResults + invalidIDResults).map(cloudflareAcceptance) + [
            "{\"success\":true,\"errors\":[],\"messages\":[]}",
            "{\"success\":false,\"errors\":[{\"code\":1000,\"message\":\"synthetic rejection\"}],\"result\":\(cloudflareAcceptedResult(messageID: true))}"
        ]
        for body in rejectedBodies {
            try await withDeliveryMailbox(body: body) { mailbox in
                await #expect(throws: TransactionalEmailError.self) {
                    try await cloudflareSender(mailbox).send(deliveryIntent(), outboxID: "rejected", now: deliveryNow)
                }
                #expect(mailbox.requests.count == 1)
            }
        }
        for field in ["permanent_bounces", "suppressed_recipients"] {
            let other = field == "permanent_bounces" ? "suppressed_recipients" : "permanent_bounces"
            let result = "{\"queued\":[\"\(deliveryAddress)\"],\"delivered\":[],\"\(field)\":[\"\(deliveryAddress)\"],\"\(other)\":[]}"
            try await withDeliveryMailbox(body: cloudflareAcceptance(result)) { mailbox in
                let error = await #expect(throws: TransactionalEmailError.self) {
                    try await cloudflareSender(mailbox).send(deliveryIntent(), outboxID: "recipient-rejected", now: deliveryNow)
                }
                #expect(error == .recipientRejected)
                #expect(error?.retryable == false)
            }
        }
    }

    @Test func cloudflareHTTPFailuresAndRedirectIsolation() async throws {
        for status in [429, 500, 503, 401, 403] {
            try await withDeliveryMailbox(status: status, body: "{\"success\":false}") { mailbox in
                let error = await #expect(throws: TransactionalEmailError.self) {
                    try await cloudflareSender(mailbox).send(deliveryIntent(), outboxID: "http-rejected", now: deliveryNow)
                }
                #expect(error == .providerRejected(status: status))
                #expect(error?.retryable == (status == 429 || status >= 500))
                #expect(mailbox.requests.count == 1)
            }
        }
        try await withDeliveryMailbox(body: cloudflareAcceptance(cloudflareAcceptedResult(messageID: true))) { destination in
            try await withDeliveryMailbox(status: 307, body: "", location: destination.url(path: "/redirected").absoluteString) { origin in
                let error = await #expect(throws: TransactionalEmailError.self) {
                    try await cloudflareSender(origin).send(deliveryIntent(), outboxID: "redirect", now: deliveryNow)
                }
                #expect(error == .providerRejected(status: 307))
                #expect(origin.requests.count == 1)
                #expect(destination.requests.isEmpty)
            }
        }
    }

    @Test func resendRetainsArrayRecipientsAndStableIdempotencyKey() async throws {
        try await withDeliveryMailbox(body: "{\"id\":\"resend-message\"}") { mailbox in
            let sender = TransactionalEmailSender(configuration: try .localMailbox(
                apiKey: "synthetic-resend-key", from: "Raft <noreply@mail.example.com>",
                webURL: deliveryWebURL, endpoint: mailbox.url(path: "/emails")
            ))
            for _ in 0..<2 {
                let receipt = try await sender.send(deliveryIntent(), outboxID: "resend-outbox-42", now: deliveryNow)
                #expect(receipt.providerMessageID == "resend-message")
            }
            #expect(mailbox.requests.count == 2)
            for request in mailbox.requests {
                #expect(request.method == "POST")
                #expect(request.uri == "/emails")
                #expect(request.headers["authorization"] == "Bearer synthetic-resend-key")
                #expect(request.headers["content-length"] == String(request.body.count))
                #expect(request.headers["idempotency-key"] == "raft-email-resend-outbox-42")
                let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
                #expect(body["from"] as? String == "Raft <noreply@mail.example.com>")
                #expect(body["to"] as? [String] == [deliveryAddress])
            }
        }
    }

    @Test func invalidIntentAndOutboxNeverReachMailbox() async throws {
        try await withDeliveryMailbox(body: cloudflareAcceptance(cloudflareAcceptedResult(messageID: true))) { mailbox in
            let sender = try cloudflareSender(mailbox)
            let expired = await #expect(throws: TransactionalEmailError.self) {
                try await sender.send(deliveryIntent(expired: true), outboxID: "expired", now: deliveryNow)
            }
            #expect(expired == .expiredIntent)
            for id in ["", "unsafe/header", "unsafe\r\nheader", String(repeating: "x", count: 201)] {
                let error = await #expect(throws: TransactionalEmailError.self) {
                    try await sender.send(deliveryIntent(), outboxID: id, now: deliveryNow)
                }
                #expect(error == .invalidOutboxIdentifier)
            }
            #expect(mailbox.requests.isEmpty)
        }
        #expect(throws: TransactionalEmailError.invalidConfiguration) {
            try TransactionalEmailConfiguration.cloudflareLocalMailbox(
                apiToken: "synthetic-cloudflare-token", from: "noreply@mail.example.com",
                webURL: deliveryWebURL, endpoint: URL(string: "http://mail.example.com/send")!
            )
        }
    }
}

private struct DeliveryReply: Sendable {
    let status: Int
    let body: String
    let location: String?
}

private struct DeliveryRequest: Sendable {
    let method: String
    let uri: String
    let headers: [String: String]
    let body: Data
}

private final class DeliveryCapture: Sendable {
    let requests = Mutex<[DeliveryRequest]>([])
}

private final class DeliveryMailbox: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let captured: DeliveryCapture
    var requests: [DeliveryRequest] { captured.requests.withLock { $0 } }

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel, captured: DeliveryCapture) {
        self.group = group
        self.channel = channel
        self.captured = captured
    }

    static func start(reply: DeliveryReply) async throws -> DeliveryMailbox {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let captured = DeliveryCapture()
        do {
            let channel = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(DeliveryHandler(reply: reply, captured: captured))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            return DeliveryMailbox(group: group, channel: channel, captured: captured)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(channel.localAddress!.port!)\(path)")!
    }

    func stop() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }
}

// NIO confines mutable request assembly to this handler's channel event loop.
private final class DeliveryHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let reply: DeliveryReply
    private let captured: DeliveryCapture
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(reply: DeliveryReply, captured: DeliveryCapture) {
        self.reply = reply
        self.captured = captured
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body(var bytes): body.writeBuffer(&bytes)
        case .end:
            guard let head else { return }
            let headers = head.headers.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value }
            let request = DeliveryRequest(method: head.method.rawValue, uri: head.uri, headers: headers, body: Data(body.readableBytesView))
            captured.requests.withLock { $0.append(request) }
            var responseHeaders = HTTPHeaders([("Content-Type", "application/json"), ("Content-Length", "\(reply.body.utf8.count)"), ("Connection", "close")])
            if let location = reply.location { responseHeaders.add(name: "Location", value: location) }
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: reply.status), headers: responseHeaders))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: reply.body)))), promise: nil)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
        }
    }
}

private func withDeliveryMailbox(
    status: Int = 200, body: String, location: String? = nil,
    operation: @Sendable (DeliveryMailbox) async throws -> Void
) async throws {
    let mailbox = try await DeliveryMailbox.start(reply: DeliveryReply(status: status, body: body, location: location))
    do {
        try await operation(mailbox)
        await mailbox.stop()
    } catch {
        await mailbox.stop()
        throw error
    }
}
