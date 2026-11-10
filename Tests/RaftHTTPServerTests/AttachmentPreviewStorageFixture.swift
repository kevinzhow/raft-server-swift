import Crypto
import Foundation
import HTTPTypes
import NIOCore
@testable import RaftHTTP
import RaftObjectStorage
import SotoTestUtils
import Synchronization
import TestSupport
import Testing
import Vapor

let attachmentPreviewFixtureSigningSecret = "synthetic-attachment-preview-jwt-key-material-at-least-32-bytes"

/// A real SDK-compatible localhost endpoint. Only sealed ciphertext is retained.
final class AttachmentPreviewStorageFixture: Sendable {
    struct State: Sendable {
        var ciphertext: [String: Data] = [:]
        var tamper = false
        var rejectedStatus: Int?
    }
    final class CapturedState: Sendable {
        let value = Mutex(State())
    }
    let state: CapturedState
    let storage: S3AttachmentStorage
    private let server: AWSTestServer
    private let serving: Task<Void, any Error>

    init() throws {
        let server = AWSTestServer(serviceProtocol: .xml)
        let state = CapturedState()
        self.server = server
        self.state = state
        self.storage = S3AttachmentStorage(configuration: try .loopbackFixture(
            endpoint: server.addressURL, bucket: "fixture", accessKeyID: "synthetic-access",
            secretAccessKey: "synthetic-secret", encryptionKey: Data(repeating: 7, count: 32)
        ))
        self.serving = Task.detached {
            try server.processRaw { request in
                state.value.withLock { value in
                    let key = String(request.uri.prefix { $0 != "?" })
                    if let status = value.rejectedStatus {
                        let xml = "<Error><Code>AccessDenied</Code><Message>synthetic-provider-private-detail</Message></Error>"
                        return .result(.init(httpStatus: .init(statusCode: status), headers: ["Content-Type": "application/xml"],
                            body: ByteBuffer(string: xml)), continueProcessing: true)
                    }
                    switch request.method.rawValue {
                    case "PUT":
                        value.ciphertext[key] = Data(request.body.readableBytesView)
                        return .result(.init(httpStatus: .ok, headers: ["ETag": "\"synthetic-object\""]), continueProcessing: true)
                    case "GET":
                        guard var bytes = value.ciphertext[key] else {
                            return .result(.init(httpStatus: .notFound, headers: ["Content-Type": "application/xml"],
                                body: ByteBuffer(string: "<Error><Code>NoSuchKey</Code></Error>")), continueProcessing: true)
                        }
                        if value.tamper, !bytes.isEmpty { bytes[bytes.index(before: bytes.endIndex)] ^= 1 }
                        return .result(.init(httpStatus: .ok, headers: ["Content-Type": "application/octet-stream"],
                            body: ByteBuffer(bytes: bytes)), continueProcessing: true)
                    case "DELETE":
                        value.ciphertext.removeValue(forKey: key)
                        return .result(.init(httpStatus: .noContent), continueProcessing: true)
                    default: return .result(.init(httpStatus: .methodNotAllowed), continueProcessing: true)
                    }
                }
            }
        }
    }

    func stop() async {
        try? await storage.shutdown()
        try? server.stop()
        _ = try? await serving.value
    }
}

/// A controlled suspension used only to choose concurrent ACL mutation timing.
/// Assertions inspect the published HTTP/error output; this gate is not evidence
/// of provider behavior or a query-count observation.
actor AttachmentPreviewReadGate: AttachmentObjectStoring {
    let underlying: any AttachmentObjectStoring
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    init(_ underlying: any AttachmentObjectStoring) { self.underlying = underlying }
    func put(attachmentID: String, bytes: Data) async throws -> AttachmentObjectReference {
        try await underlying.put(attachmentID: attachmentID, bytes: bytes)
    }
    func delete(_ reference: AttachmentObjectReference) async throws { try await underlying.delete(reference) }
    func get(_ reference: AttachmentObjectReference) async throws -> Data {
        let bytes: Data
        do { bytes = try await underlying.get(reference) }
        catch { markEntered(); throw error }
        markEntered()
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        return bytes
    }
    private func markEntered() {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
    }
    func waitUntilFetched() async {
        if !entered { await withCheckedContinuation { enteredWaiter = $0 } }
    }
    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

struct AttachmentPreviewAccounts: Sendable {
    let accounts: EmailLoginDirectory
    let userId: String
    let serverId: String
    let channelId: String
    let authorization: String

    init(storage: any AttachmentObjectStoring) {
        let accounts = EmailLoginDirectory()
        accounts.oauth.jwtSecret = attachmentPreviewFixtureSigningSecret
        let userId = UUID().uuidString.lowercased()
        let serverId = UUID().uuidString.lowercased()
        accounts.addAccount(id: userId, email: "preview-owner@example.com", password: "password123")
        accounts.markEmailVerified(userId: userId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "preview-fixture", name: "Preview", ownerId: userId)
        let channelId = accounts.oauth.createChannel(serverId: serverId, name: "preview", creatorUserId: userId)
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: userId, name: "preview")
        let authorization = "Bearer \(accounts.mintAccessTokenForTesting(userId: userId))"
        accounts.configureAttachmentStorage(storage)
        self.accounts = accounts
        self.userId = userId
        self.serverId = serverId
        self.channelId = channelId
        self.authorization = authorization
    }

    func upload(_ bytes: Data, filename: String = "report.html", mime: String = "text/html") async throws -> String {
        let response = try await accounts.agentsLifecycle.uploadAttachmentContents(
            authorization: authorization, serverId: serverId, channelId: channelId,
            files: [.init(filename: filename, mimeType: mime, bytes: bytes)]
        )
        return try #require(response.attachments.first?.id)
    }

    func previewToken(_ id: String) async throws -> String {
        try await AttachmentPreviewTokens(secret: accounts.oauth.jwtSecret)
            .mint(attachmentId: id, serverId: serverId, actorId: userId)
    }

    func service(now: @escaping @Sendable () -> Date) -> AgentsLifecycleService {
        let live = accounts.agentsLifecycle
        var dependencies = live.dependencies
        dependencies.now = now
        return AgentsLifecycleService(profiles: live.profiles, agents: live.agents, machines: live.machines,
            channels: live.channels, messages: live.messages, inboxFacts: live.inboxFacts,
            productEvents: live.productEvents, oauth: live.oauth, dependencies: dependencies)
    }

    func preview(_ id: String) async throws {
        let token = try await previewToken(id)
        _ = try await accounts.agentsLifecycle.attachmentHTMLPreview(
            attachmentId: id, serverId: serverId, previewToken: token, bearerQuery: nil
        )
    }
}

func expectAttachmentPreviewRefusal(
    _ response: ClientResponse, notAMember: Bool = false, privateHTML: Data
) async throws {
    #expect(response.status == (notAMember ? .forbidden : .notFound))
    let body = try await attachmentPreviewBody(response)
    let expected = notAMember ? #"{"error":"Not a member of this server"}"# : #"{"error":"Attachment not found"}"#
    #expect(body == Data(expected.utf8))
    #expect(body.range(of: privateHTML) == nil)
    #expect(!String(decoding: body, as: UTF8.self).contains("<html>"))
}

func attachmentPreviewBody(_ response: ClientResponse) async throws -> Data {
    let bytes = Mutex(Data())
    try await response.body.withStreamingBytes { span in
        var chunk = Data()
        chunk.reserveCapacity(span.count)
        for index in span.indices { chunk.append(span[index]) }
        bytes.withLock { $0.append(chunk) }
    }
    return bytes.withLock { $0 }
}
