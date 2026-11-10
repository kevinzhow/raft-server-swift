import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import RaftObjectStorage
import Testing
import TestSupport
import Vapor
import VaporTesting

private func jointAttachmentMultipart(channelId: String, filename: String, content: String) -> (contentType: String, body: Data) {
    let boundary = "----raft-agent-upload"
    var data = Data()
    func append(_ string: String) { data.append(Data(string.utf8)) }
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"channelId\"\r\n\r\n")
    append("\(channelId)\r\n")
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
    append("Content-Type: text/plain\r\n\r\n")
    append(content)
    append("\r\n")
    append("--\(boundary)--\r\n")
    return ("multipart/form-data; boundary=\(boundary)", data)
}

/// Assert the real cold message carriers, after the existing physical download
/// assertions established that these IDs refer to actual retained file bodies.
private func expectColdLinkedAttachment(
    _ client: any TestClient, headers: HTTPFields, channel: String, message: String,
    attachment: String, filename: String, size: Int, aggregate: Bool = false,
    opaqueIDs: [String] = []
) async throws {
    var paths = ["/api/messages/channel/\(channel)",
                 "/api/messages/context/\(message)?channelId=\(channel)",
                 "/api/messages/sync?channel_id=\(channel)&since_seq=0"]
    if aggregate { paths.append("/api/messages/sync?since_seq=0") }
    for path in paths {
        let response = try await client.get(URI(string: path), headers: headers)
        #expect(response.status == .ok)
        let body = try JSONSerialization.jsonObject(with: try await attachmentPreviewBody(response))
        let rows = (body as? [[String: Any]]) ?? ((body as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
        let row = try #require(rows.first { $0["id"] as? String == message })
        let chips = try #require(row["attachments"] as? [[String: Any]])
        let linked = try #require(chips.first { $0["id"] as? String == attachment })
        #expect(linked["filename"] as? String == filename)
        #expect(linked["mimeType"] as? String == "text/plain")
        #expect(linked["sizeBytes"] as? Int == size)
        #expect(chips.allSatisfy { $0["storageKey"] == nil && $0["objectKey"] == nil })
        if !opaqueIDs.isEmpty {
            #expect(Array(chips.prefix(opaqueIDs.count)).compactMap { $0["id"] as? String } == opaqueIDs)
            for id in opaqueIDs {
                let opaque = try #require(chips.first { $0["id"] as? String == id })
                #expect(opaque["filename"] == nil && opaque["mimeType"] == nil && opaque["sizeBytes"] == nil)
            }
        }
    }
}

@Test(.timeLimit(.minutes(1))) func linkedJointAttachmentsResolveThroughSiblingProjectionsOnly() async throws {
    try await withSingleURLStorage { storage in
    let accounts = EmailLoginDirectory()
    let hostServer = "33333333-3333-4333-8333-000001019001"
    let peerServer = "33333333-3333-4333-8333-000001019002"
    let hostOwner = "11111111-1111-4111-8111-000001019001"
    let peerOwner = "11111111-1111-4111-8111-000001019002"
    let hostEmail = "joint-attach-host@slock.test"
    let peerEmail = "joint-attach-peer@slock.test"
    for (id, email) in [(hostOwner, hostEmail), (peerOwner, peerEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: hostServer, slug: "joint-attach-host", name: "Joint Attach Host", ownerId: hostOwner)
    accounts.oauth.addOwnedServer(id: peerServer, slug: "joint-attach-peer", name: "Joint Attach Peer", ownerId: peerOwner)
    let canonical = accounts.oauth.createChannel(serverId: hostServer, name: "joint-attach-storage", creatorUserId: hostOwner)
    accounts.addPostableChannel(serverId: hostServer, channelId: canonical, memberId: hostOwner, name: "joint-attach-storage")
    accounts.oauth.addChannelHuman(channelId: canonical, userId: hostOwner)
    let hostProjection = accounts.oauth.createChannel(serverId: hostServer, name: "joint-attach-room", creatorUserId: hostOwner, type: "joint")
    accounts.addPostableChannel(serverId: hostServer, channelId: hostProjection, memberId: hostOwner, kind: "joint", name: "joint-attach-room")
    accounts.oauth.addChannelHuman(channelId: hostProjection, userId: hostOwner)
    let peerProjection = accounts.oauth.createChannel(serverId: peerServer, name: "joint-attach-room", creatorUserId: peerOwner, type: "joint")
    accounts.addPostableChannel(serverId: peerServer, channelId: peerProjection, memberId: peerOwner, kind: "joint", name: "joint-attach-room")
    accounts.oauth.addChannelHuman(channelId: peerProjection, userId: peerOwner)
    accounts.addJointChannelProjection(localChannelId: hostProjection, canonicalChannelId: canonical, serverId: hostServer)
    accounts.addJointChannelProjection(localChannelId: peerProjection, canonicalChannelId: canonical, serverId: peerServer)

    let message = accounts.addChannelMessageForTesting(channelId: canonical, content: "joint attachment message", senderId: hostOwner)
    let linkedBytes = Data("joint linked attachment\n".utf8)
    let draftBytes = Data("joint draft attachment\n".utf8)
    let linked = accounts.addChannelAttachment(
        channelId: hostProjection,
        uploaderId: hostOwner,
        filename: "joint-linked.txt",
        mimeType: "text/plain",
        sizeBytes: linkedBytes.count,
        messageId: message,
        bytes: linkedBytes
    )
    let draft = accounts.addChannelAttachment(
        channelId: hostProjection,
        uploaderId: hostOwner,
        filename: "joint-draft.txt",
        mimeType: "text/plain",
        sizeBytes: draftBytes.count,
        bytes: draftBytes
    )
    accounts.configureAttachmentStorage(storage.storage)
    for (id, bytes) in [(linked, linkedBytes), (draft, draftBytes)] {
        let reference = try await storage.storage.put(attachmentID: id, bytes: bytes)
        accounts.messagesAndThreadsStore.withState { state in
            state.attachmentObjectReferences[id] = reference
            state.developmentAttachmentBytes.removeValue(forKey: id)
        }
    }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(peerEmail)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = peerServer
            headers[HTTPField.Name("Host")!] = "localhost"
            let linkedResponse = try await client.get(URI(string: "/api/attachments/\(linked)/url"), headers: headers)
            #expect(linkedResponse.status == .ok)
            let wire = try await singleURLWire(linkedResponse)
            let fetched = try await client.get(URI(string: wire.url))
            #expect(fetched.status == .ok)
            let plaintext = try await attachmentPreviewBody(fetched)
            #expect(plaintext == linkedBytes)
            try await expectColdLinkedAttachment(client, headers: headers, channel: peerProjection,
                message: message, attachment: linked, filename: "joint-linked.txt", size: linkedBytes.count)
            // A stale unbound ID is an opaque reference; the real linked host
            // still authorizes physical metadata across sibling projections.
            accounts.setMessageAttachmentIdsForTesting(messageId: message, attachmentIds: [draft, linked])
            try await expectColdLinkedAttachment(client, headers: headers, channel: peerProjection,
                message: message, attachment: linked, filename: "joint-linked.txt", size: linkedBytes.count,
                opaqueIDs: [draft])
            let draftResponse = try await client.get(URI(string: "/api/attachments/\(draft)/url"), headers: headers)
            #expect(draftResponse.status == .notFound)
            #expect((try JSONSerialization.jsonObject(with: Data((draftResponse.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Attachment not found")
        }
    }
    }
}

@Test func attachmentVisibilityFollowsItsMessageNotTheUploadChannel() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001019003"
    let ownerId = "11111111-1111-4111-8111-000001019003"
    let outsiderId = "11111111-1111-4111-8111-000001019004"
    let ownerEmail = "legacy-attach-owner@slock.test"
    let outsiderEmail = "legacy-attach-outsider@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (outsiderId, outsiderEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "legacy-attach", name: "Legacy Attach", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    let publicChannel = accounts.oauth.createChannel(serverId: serverId, name: "legacy-public", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: publicChannel, memberId: ownerId, name: "legacy-public")
    accounts.oauth.addChannelHuman(channelId: publicChannel, userId: ownerId)
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "legacy-private", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannel, memberId: ownerId, kind: "private", name: "legacy-private")
    accounts.oauth.addChannelHuman(channelId: privateChannel, userId: ownerId)
    let publicMessage = accounts.addChannelMessageForTesting(channelId: publicChannel, content: "public body", senderId: ownerId)
    let privateMessage = accounts.addChannelMessageForTesting(channelId: privateChannel, content: "private body", senderId: ownerId)
    let movedPublicBytes = Data("message-visible attachment\n".utf8)
    let movedPrivateBytes = Data("message-private attachment\n".utf8)
    let movedToPublic = accounts.addChannelAttachment(
        channelId: privateChannel,
        uploaderId: ownerId,
        filename: "moved.txt",
        mimeType: "text/plain",
        sizeBytes: movedPublicBytes.count,
        messageId: publicMessage,
        bytes: movedPublicBytes
    )
    let movedToPrivate = accounts.addChannelAttachment(
        channelId: publicChannel,
        uploaderId: ownerId,
        filename: "hidden.txt",
        mimeType: "text/plain",
        sizeBytes: movedPrivateBytes.count,
        messageId: privateMessage,
        bytes: movedPrivateBytes
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(outsiderEmail)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let visibleDownload = try await client.get(URI(string: "/api/attachments/\(movedToPublic)"), headers: headers)
            #expect(visibleDownload.status == .ok)
            #expect(visibleDownload.body.data == movedPublicBytes)
            #expect(visibleDownload.headers[.contentType] == "text/plain; charset=utf-8")
            #expect(visibleDownload.headers[.contentLength] == String(movedPublicBytes.count))
            #expect(try await client.get(URI(string: "/api/attachments/\(movedToPrivate)"), headers: headers).status == .notFound)
            accounts.setMessageAttachmentIdsForTesting(messageId: publicMessage,
                attachmentIds: [movedToPrivate, "unretained-review-id"])
            try await expectColdLinkedAttachment(client, headers: headers, channel: publicChannel,
                message: publicMessage, attachment: movedToPublic, filename: "moved.txt", size: movedPublicBytes.count,
                aggregate: true, opaqueIDs: [movedToPrivate, "unretained-review-id"])
        }
    }
}

@Test func agentUploadHonorsTheKillSwitchAndProLimit() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001019005"
    let ownerId = "11111111-1111-4111-8111-000001019005"
    let ownerEmail = "agent-upload-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-upload", name: "Agent Upload", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "agent-upload-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "agent-upload-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "agent-upload-machine")
    let machineKey = try #require(accounts.machineAPIKey(machineId: machine))
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "agent-upload-agent", runtime: "codex")
    accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)

    func withEnv(_ values: [String: String], _ run: () async throws -> Void) async rethrows {
        var previous: [String: String?] = [:]
        for (key, value) in values {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        try await run()
    }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func upload(_ key: String, _ content: String) async throws -> ClientResponse {
                let multipart = jointAttachmentMultipart(channelId: channel, filename: "hello.txt", content: content)
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = multipart.contentType
                return try await client.send(.post, headers: headers, to: URI(string: "/internal/agent/\(agent)/upload")) { request in
                    request.body = .init(data: multipart.body)
                }
            }
            try await withEnv(["ATTACHMENT_UPLOAD_ENABLED": "false"]) {
                let disabled = try await upload(machineKey, "hello")
                #expect(disabled.status == .serviceUnavailable)
                #expect((try JSONSerialization.jsonObject(with: Data((disabled.body.string ?? "").utf8)) as? [String: Any])?["errorCode"] as? String == "ATTACHMENT_UPLOAD_DISABLED")
            }
            try await withEnv(["ATTACHMENT_UPLOAD_ENABLED": "true"]) {
                let accepted = try await upload(machineKey, "hello")
                #expect(accepted.status == .ok)
                #expect(((try JSONSerialization.jsonObject(with: Data((accepted.body.string ?? "").utf8)) as? [String: Any])?["attachments"] as? [[String: Any]] ?? []).count == 1)
            }
        }
    }
}

@Test func attachmentReadsRejectRevokedSessionsAndRetiredUsers() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001019006"
    let ownerId = "11111111-1111-4111-8111-000001019006"
    let ownerEmail = "attachment-revoked-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "attachment-revoked", name: "Attachment Revoked", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "attachment-revoked-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "attachment-revoked-room")
    let attachmentBytes = Data("revoked session attachment\n".utf8)
    let attachment = accounts.addChannelAttachment(channelId: channel, uploaderId: ownerId, filename: "revoked.txt",
        mimeType: "text/plain", sizeBytes: attachmentBytes.count, bytes: attachmentBytes)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let beforeRevocation = try await client.get(URI(string: "/api/attachments/\(attachment)"), headers: headers)
            #expect(beforeRevocation.status == .ok)
            #expect(beforeRevocation.body.data == attachmentBytes)
            #expect(beforeRevocation.headers[.contentType] == "text/plain; charset=utf-8")
            #expect(beforeRevocation.headers[.contentLength] == String(attachmentBytes.count))

            accounts.revokeAccessTokenForTesting(token)
            #expect(try await client.get(URI(string: "/api/attachments/\(attachment)"), headers: headers).status == .unauthorized)
            #expect(try await client.get(URI(string: "/api/attachments/\(attachment)/url?serverId=\(serverId)&token=\(token)")).status == .unauthorized)

            var freshHeaders = HTTPFields()
            freshHeaders[.contentType] = "application/json"
            let relogin = try await client.send(.post, headers: freshHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}")
            }
            let fresh = (try JSONSerialization.jsonObject(with: Data((relogin.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            accounts.retireUserForTesting(userId: ownerId)
            var retiredHeaders = HTTPFields()
            retiredHeaders[.authorization] = "Bearer \(fresh)"
            retiredHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let retiredRead = try await client.get(URI(string: "/api/attachments/\(attachment)"), headers: retiredHeaders)
            #expect(retiredRead.status == .unauthorized)
            let retiredURL = try await client.get(URI(string: "/api/attachments/\(attachment)/url"), headers: retiredHeaders)
            #expect(retiredURL.status == .unauthorized, "retired url status=\(retiredURL.status) body=\(retiredURL.body.string ?? "")")
        }
    }
}
