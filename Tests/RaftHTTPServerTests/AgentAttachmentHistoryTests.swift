import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The agent-facing history read carries the same attachment envelope as the
/// pinned `toAgentApiMessageEnvelope` (`internalAgentApi.ts:1132`) over rows
/// enriched by `messageService.ts:6465` and `:5016`.
private func agentHistoryHeaders(_ key: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    return headers
}

@Test(arguments: [false, true])
func agentHistoryListsAttachmentMetadataAndDownloadUsesTheAgentCredential(binary: Bool) async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        let setup = AttachmentPreviewAccounts(storage: fixture.storage)
        let agentId = setup.accounts.oauth.createAgent(
            serverId: setup.serverId, name: "Attachment Reader",
            creatorUserId: setup.userId, runtime: "claude")
        setup.accounts.oauth.addChannelAgent(channelId: setup.channelId, agentId: agentId)
        let readKey = setup.accounts.mintAgentCredential(
            agentId: agentId, scopes: ["read"], name: "attachment-reader")
        setup.accounts.setAccountProfileForTesting(
            id: setup.userId, name: "kevinchou-c", displayName: "pending_7808a39c4efb92d4cb34")
        // A real PNG exercises the object-store -> Agent HTTP response boundary.
        let bytes = binary ? try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
            : Data("agent must be able to read this attachment\n".utf8)
        let filename = binary ? "acceptance.png" : "acceptance.txt"
        let mime = binary ? "image/png" : "text/plain"
        let attachmentId = try await setup.upload(
            bytes, filename: filename, mime: mime)

        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {}, emailAccounts: setup.accounts))
            try await app.testing { client in
                var humanHeaders = HTTPFields()
                humanHeaders[.authorization] = setup.authorization
                humanHeaders[.contentType] = "application/json"
                humanHeaders[HTTPField.Name("X-Server-Id")!] = setup.serverId
                let created = try await client.send(.post, headers: humanHeaders, to: "/api/messages") { request in
                    request.body = .init(string: """
                        {"channelId":"\(setup.channelId)","content":"please read the attachment","attachmentIds":["\(attachmentId)"]}
                        """)
                }
                #expect(created.status == .ok)
                let message = try #require(JSONSerialization.jsonObject(with: created.body.data ?? Data()) as? [String: Any])
                let messageId = try #require(message["id"] as? String)

                let history = try await client.get(
                    URI(string: "/internal/agent-api/history?channel=%23preview&limit=10&consume=false"),
                    headers: agentHistoryHeaders(readKey))
                #expect(history.status == .ok)
                let body = try #require(JSONSerialization.jsonObject(with: history.body.data ?? Data()) as? [String: Any])
                let rows = try #require(body["messages"] as? [[String: Any]])
                let row = try #require(rows.first { $0["id"] as? String == messageId })
                #expect(row["senderName"] as? String == "kevinchou-c")
                let attachments = try #require(row["attachments"] as? [[String: Any]])
                #expect(attachments.count == 1)
                #expect(attachments.first?["id"] as? String == attachmentId)
                #expect(attachments.first?["filename"] as? String == filename)
                #expect(attachments.first?["mimeType"] as? String == mime)
                #expect(attachments.first?["sizeBytes"] as? Int == bytes.count)

                let download = try await client.get(
                    URI(string: "/internal/agent-api/attachments/\(attachmentId)"),
                    headers: agentHistoryHeaders(readKey))
                #expect(download.status == .ok)
                #expect(download.body.data == bytes)
                #expect(download.headers[.contentType] == mime)
                #expect(download.headers[.contentLength] == String(bytes.count))
            }
        }
        await fixture.stop()
    } catch {
        await fixture.stop()
        throw error
    }
}

@Test func agentAttachmentDownloadFollowsThreadAccessThroughTheParentChannel() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        let setup = AttachmentPreviewAccounts(storage: fixture.storage)
        let agentId = setup.accounts.oauth.createAgent(
            serverId: setup.serverId, name: "Thread Attachment Reader",
            creatorUserId: setup.userId, runtime: "claude")
        setup.accounts.oauth.addChannelAgent(channelId: setup.channelId, agentId: agentId)
        let readKey = setup.accounts.mintAgentCredential(
            agentId: agentId, scopes: ["read"], name: "thread-attachment-reader")
        let parentMessageId = UUID().uuidString.lowercased()
        let threadId = setup.accounts.oauth.createThreadChannel(
            parentChannelId: setup.channelId, parentMessageId: parentMessageId)
        setup.accounts.addPostableChannel(
            serverId: setup.serverId, channelId: threadId, memberId: setup.userId,
            kind: "thread", parentChannelId: setup.channelId, parentMessageId: parentMessageId,
            name: "attachment-thread")
        let upload = try await setup.accounts.agentsLifecycle.uploadAttachmentContents(
            authorization: setup.authorization, serverId: setup.serverId, channelId: threadId,
            files: [.init(filename: "thread.txt", mimeType: "text/plain", bytes: Data("thread bytes".utf8))])
        let attachmentId = try #require(upload.attachments.first?.id)
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {}, emailAccounts: setup.accounts))
            try await app.testing { client in
                let download = try await client.get(
                    URI(string: "/internal/agent-api/attachments/\(attachmentId)"),
                    headers: agentHistoryHeaders(readKey))
                #expect(download.status == .ok)
                #expect(download.body.data == Data("thread bytes".utf8))
            }
        }
        await fixture.stop()
    } catch {
        await fixture.stop()
        throw error
    }
}
