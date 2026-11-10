import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func deletedChannelDeepLinksAndThreadsAreCloaked() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111661"
    let serverId = "33333333-3333-4333-8333-333333333693"
    accounts.addAccount(id: ownerId, email: "deleted-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "deleted", name: "Deleted", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "deleted-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "deleted-room")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let message = accounts.addChannelMessageForTesting(channelId: channelId, content: "deleted-content", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: channelId, parentMessageId: message)
    accounts.addPostableChannel(
        serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread",
        parentChannelId: channelId, parentMessageId: message, name: "thread"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let deleted = try await client.delete(URI(string: "/api/channels/\(channelId)"), headers: headers)
            #expect(deleted.status == .ok)
            #expect(deleted.body.string == "{\"ok\":true}")
            #expect(deleted.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            let channelRead = try await client.get(URI(string: "/api/messages/channel/\(channelId)"), headers: headers)
            #expect(channelRead.status == .notFound, "deleted channel deep-links are cloaked")
            let threadRead = try await client.get(URI(string: "/api/messages/channel/\(thread)"), headers: headers)
            #expect(threadRead.status == .notFound, "thread deep-links are cloaked after parent deletion")
        }
    }
}


@Test func deletedChannelSearchAndAttachmentPathsAreCloaked() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111662"
    let serverId = "33333333-3333-4333-8333-333333333694"
    accounts.addAccount(id: ownerId, email: "deleted-attach@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "deleted-attach", name: "Deleted Attach", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "deleted-attach-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "deleted-attach-room")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let authorization = "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))"
    let bytes = Data("deleted".utf8)
    try await withSingleURLStorage { storage in
        accounts.configureAttachmentStorage(storage.storage)
        try await withApp { app in
            configure(app, services: singleURLServices(accounts))
            try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
                let port = try #require(client.port)
                var headers = singleURLHeaders(authorization, serverId)
                headers[HTTPField.Name("Host")!] = "127.0.0.1:\(port)"
                let attachment = try await singleURLUpload(client, authorization: authorization, server: serverId,
                    channel: channelId, filename: "deleted.txt", mime: "text/plain", bytes: bytes)
                var messageHeaders = headers
                messageHeaders[.contentType] = "application/json"
                let posted = try await client.send(.post, headers: messageHeaders, to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"lorem deletedmarker ipsum\",\"attachmentIds\":[\"\(attachment)\"]}")
                }
                #expect(posted.status == .ok)
                let postedBytes = try await attachmentPreviewBody(posted)
                let postedMessage = try #require(JSONSerialization.jsonObject(with: postedBytes) as? [String: Any])
                _ = try #require(postedMessage["id"] as? String)
                let before = try await client.get(URI(string: "/api/attachments/\(attachment)/url"), headers: headers)
                #expect(before.status == .ok, "fixture attachment must be readable before deletion")
                let wire = try await singleURLWire(before)
                let origin = try #require(URLComponents(string: wire.url))
                #expect(origin.scheme == "http")
                #expect(origin.host == "127.0.0.1")
                #expect(origin.port == port)
                let download = try await client.get(URI(string: wire.url))
                #expect(download.status == .ok)
                let plaintext = try await attachmentPreviewBody(download)
                #expect(plaintext == bytes)
                #expect(download.headers[.contentLength] == String(bytes.count))
                #expect(download.headers[.contentType] == "text/plain; charset=utf-8")
                let sealed = storage.state.value.withLock { Array($0.ciphertext.values) }
                #expect(sealed.count == 1)
                #expect(sealed.first != bytes)
                #expect(sealed.first?.count == bytes.count + 28)
                let deleted = try await client.delete(URI(string: "/api/channels/\(channelId)"), headers: headers)
                #expect(deleted.status == .ok)
                let deletedBody = String(decoding: try await attachmentPreviewBody(deleted), as: UTF8.self)
                #expect(deletedBody == "{\"ok\":true}")
                let search = try await client.get(URI(string: "/api/messages/search?q=deletedmarker"), headers: headers)
                #expect(search.status == .ok)
                let searchBody = String(decoding: try await attachmentPreviewBody(search), as: UTF8.self)
                #expect(!searchBody.contains(channelId), "deleted channel search hits are excluded")
                let after = try await client.get(URI(string: "/api/attachments/\(attachment)/url"), headers: headers)
                #expect(after.status == .notFound, "deleted channel attachments are cloaked")
                let afterBody = try await attachmentPreviewBody(after)
                #expect(afterBody == Data(#"{"error":"Attachment not found"}"#.utf8))
                let remembered = try await client.get(URI(string: wire.url))
                #expect(remembered.status == .notFound, "the previously issued URL must also cloak the deleted channel")
                let rememberedBody = try await attachmentPreviewBody(remembered)
                #expect(rememberedBody == Data(#"{"error":"Attachment not found"}"#.utf8))
            }
        }
    }
}
