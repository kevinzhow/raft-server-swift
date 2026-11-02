import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func contextLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func contextHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func contextObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func publicChannelPermalinkResolvesShortIDsForNonJoinedMembers() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-%012d".replacingOccurrences(of: "%012d", with: "970001")
    let ownerId = "11111111-1111-4111-8111-000000970001"
    let senderId = "11111111-1111-4111-8111-000000970002"
    let recipientId = "11111111-1111-4111-8111-000000970003"
    let ownerEmail = "public-link-owner-970@slock.test"
    let senderEmail = "public-link-sender-970@slock.test"
    let recipientEmail = "public-link-recipient-970@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (senderId, senderEmail), (recipientId, recipientEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "public-link-970", name: "Public Link", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: senderId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: recipientId, role: "member")
    let target = accounts.oauth.createChannel(serverId: serverId, name: "public-link-target-970", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: target, memberId: ownerId, name: "public-link-target-970")
    let share = accounts.oauth.createChannel(serverId: serverId, name: "public-link-share-970", creatorUserId: senderId)
    accounts.addPostableChannel(serverId: serverId, channelId: share, memberId: senderId, name: "public-link-share-970")
    accounts.addPostableChannel(serverId: serverId, channelId: share, memberId: recipientId, name: "public-link-share-970")
    let message = accounts.addChannelMessageForTesting(channelId: target, content: "public channel permalink target", senderId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let sender = try await contextLogin(client, email: senderEmail)
            let recipient = try await contextLogin(client, email: recipientEmail)
            let permalink = "https://app.slock.ai/s/public-link-970/channel/\(target)?msg=\(message.prefix(8))"
            let sent = try await client.send(.post, headers: contextHeaders(sender, serverId), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(share)\",\"content\":\"please read \(permalink)\"}")
            }
            #expect(sent.status == .ok)
            #expect((try contextObject(sent)["content"] as? String)?.contains("https://app.slock.ai") == true)

            let context = try await client.get(
                URI(string: "/api/messages/context/\(message.prefix(8))?channelId=\(target)"),
                headers: contextHeaders(recipient, serverId)
            )
            #expect(context.status == .ok)
            let body = try contextObject(context)
            #expect(body["channelId"] as? String == target)
            #expect(body["targetMessageId"] as? String == message)
            #expect((body["messages"] as? [[String: Any]] ?? []).contains {
                $0["id"] as? String == message && $0["content"] as? String == "public channel permalink target"
            })
        }
    }
}

@Test func dmAndThreadContextResolveShortIDs() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000970010"
    let ownerId = "11111111-1111-4111-8111-000000970011"
    let peerId = "11111111-1111-4111-8111-000000970012"
    let ownerEmail = "dm-link-owner-970@slock.test"
    let peerEmail = "dm-link-recipient-970@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (peerId, peerEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "dm-link-970", name: "DM Link", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    let dm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: peerId)
    for member in [ownerId, peerId] {
        accounts.addPostableChannel(serverId: serverId, channelId: dm, memberId: member, kind: "dm", name: "dm")
    }
    let dmMessage = accounts.addChannelMessageForTesting(channelId: dm, content: "dm short id context target", senderId: ownerId)

    let parentChannel = accounts.oauth.createChannel(serverId: serverId, name: "thread-context-parent-970", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: parentChannel, memberId: ownerId, name: "thread-context-parent-970")
    let parentMessage = accounts.addChannelMessageForTesting(channelId: parentChannel, content: "thread parent", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: parentChannel, parentMessageId: parentMessage)
    for member in [ownerId] {
        accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: member, kind: "thread", parentChannelId: parentChannel, parentMessageId: parentMessage, name: "thread")
    }
    let reply = accounts.addChannelMessageForTesting(channelId: thread, content: "thread reply", senderId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let peer = try await contextLogin(client, email: peerEmail)
            let dmContext = try await client.get(
                URI(string: "/api/messages/context/\(dmMessage.prefix(8))?channelId=\(dm)"),
                headers: contextHeaders(peer, serverId)
            )
            #expect(dmContext.status == .ok)
            let dmBody = try contextObject(dmContext)
            #expect(dmBody["channelId"] as? String == dm)
            #expect(dmBody["targetMessageId"] as? String == dmMessage)

            let owner = try await contextLogin(client, email: ownerEmail)
            let threadContext = try await client.get(
                URI(string: "/api/messages/context/\(reply.prefix(8))?channelId=\(parentChannel)"),
                headers: contextHeaders(owner, serverId)
            )
            #expect(threadContext.status == .ok)
            let threadBody = try contextObject(threadContext)
            #expect(threadBody["channelId"] as? String == thread)
            #expect(threadBody["targetMessageId"] as? String == reply)
            let canonical = try #require(threadBody["canonicalTarget"] as? [String: Any])
            #expect(canonical["kind"] as? String == "thread")
            #expect(canonical["channelId"] as? String == parentChannel)
            #expect(canonical["threadParentMessageId"] as? String == parentMessage)
            #expect(canonical["threadChannelId"] as? String == thread)

            let threadRef = try await client.get(
                URI(string: "/api/messages/context/\(thread.prefix(8))?channelId=\(parentChannel)"),
                headers: contextHeaders(owner, serverId)
            )
            #expect(threadRef.status == .ok)
            let refBody = try contextObject(threadRef)
            #expect(refBody["channelId"] as? String == parentChannel)
            #expect(refBody["targetMessageId"] as? String == parentMessage)
        }
    }
}

@Test func jointChannelPermalinkUsesTheCallerLocalProjection() async throws {
    let accounts = EmailLoginDirectory()
    let hostId = "33333333-3333-4333-8333-000000970020"
    let guestId = "33333333-3333-4333-8333-000000970021"
    let hostOwner = "11111111-1111-4111-8111-000000970022"
    let guestOwner = "11111111-1111-4111-8111-000000970023"
    let outsider = "11111111-1111-4111-8111-000000970024"
    let hostEmail = "joint-link-host-970@slock.test"
    let guestEmail = "joint-link-guest-970@slock.test"
    let outsiderEmail = "joint-link-outsider-970@slock.test"
    for (id, email) in [(hostOwner, hostEmail), (guestOwner, guestEmail), (outsider, outsiderEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: hostId, slug: "joint-link-host-970", name: "Host", ownerId: hostOwner)
    accounts.oauth.addOwnedServer(id: guestId, slug: "joint-link-guest-970", name: "Guest", ownerId: guestOwner)
    accounts.oauth.addMember(serverId: guestId, userId: outsider, role: "member")
    let hostProjection = accounts.oauth.createChannel(serverId: hostId, name: "joint-link-room-970", creatorUserId: hostOwner, type: "joint")
    let guestProjection = accounts.oauth.createChannel(serverId: guestId, name: "joint-link-room-970", creatorUserId: guestOwner, type: "joint")
    accounts.addPostableChannel(serverId: hostId, channelId: hostProjection, memberId: hostOwner, kind: "joint", name: "joint-link-room-970")
    accounts.addPostableChannel(serverId: guestId, channelId: guestProjection, memberId: guestOwner, kind: "joint", name: "joint-link-room-970")
    accounts.addJointChannelProjection(localChannelId: hostProjection, canonicalChannelId: hostProjection, serverId: hostId)
    accounts.addJointChannelProjection(localChannelId: guestProjection, canonicalChannelId: hostProjection, serverId: guestId)
    let message = accounts.addChannelMessageForTesting(channelId: hostProjection, content: "joint permalink target", senderId: hostOwner)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let guest = try await contextLogin(client, email: guestEmail)
            let context = try await client.get(
                URI(string: "/api/messages/context/\(message.prefix(8))?channelId=\(guestProjection)"),
                headers: contextHeaders(guest, guestId)
            )
            #expect(context.status == .ok)
            let body = try contextObject(context)
            #expect(body["channelId"] as? String == guestProjection)
            #expect(body["targetMessageId"] as? String == message)
            #expect((body["messages"] as? [[String: Any]] ?? []).allSatisfy { $0["channelId"] as? String == guestProjection })

            let outsiderToken = try await contextLogin(client, email: outsiderEmail)
            let denied = try await client.get(
                URI(string: "/api/messages/context/\(message.prefix(8))?channelId=\(guestProjection)"),
                headers: contextHeaders(outsiderToken, guestId)
            )
            #expect(denied.status == .notFound)
        }
    }
}

@Test func jointThreadPermalinkResolvesThroughTheGuestLocalThread() async throws {
    let accounts = EmailLoginDirectory()
    let hostId = "33333333-3333-4333-8333-000000970030"
    let guestId = "33333333-3333-4333-8333-000000970031"
    let hostOwner = "11111111-1111-4111-8111-000000970032"
    let guestOwner = "11111111-1111-4111-8111-000000970033"
    let hostEmail = "joint-thread-host-970@slock.test"
    let guestEmail = "joint-thread-guest-970@slock.test"
    for (id, email) in [(hostOwner, hostEmail), (guestOwner, guestEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: hostId, slug: "joint-thread-host-970", name: "Host", ownerId: hostOwner)
    accounts.oauth.addOwnedServer(id: guestId, slug: "joint-thread-guest-970", name: "Guest", ownerId: guestOwner)
    let hostProjection = accounts.oauth.createChannel(serverId: hostId, name: "joint-thread-room-970", creatorUserId: hostOwner, type: "joint")
    let guestProjection = accounts.oauth.createChannel(serverId: guestId, name: "joint-thread-room-970", creatorUserId: guestOwner, type: "joint")
    accounts.addPostableChannel(serverId: hostId, channelId: hostProjection, memberId: hostOwner, kind: "joint", name: "joint-thread-room-970")
    accounts.addPostableChannel(serverId: guestId, channelId: guestProjection, memberId: guestOwner, kind: "joint", name: "joint-thread-room-970")
    accounts.addJointChannelProjection(localChannelId: hostProjection, canonicalChannelId: hostProjection, serverId: hostId)
    accounts.addJointChannelProjection(localChannelId: guestProjection, canonicalChannelId: hostProjection, serverId: guestId)
    let parent = accounts.addChannelMessageForTesting(channelId: hostProjection, content: "joint thread parent", senderId: hostOwner)
    let canonicalThread = accounts.oauth.createThreadChannel(parentChannelId: hostProjection, parentMessageId: parent)
    let guestThread = accounts.oauth.createThreadChannel(parentChannelId: guestProjection, parentMessageId: parent)
    accounts.addPostableChannel(serverId: guestId, channelId: guestThread, memberId: guestOwner, kind: "thread", parentChannelId: guestProjection, parentMessageId: parent, name: "thread")
    accounts.addJointChannelProjection(localChannelId: guestThread, canonicalChannelId: canonicalThread, serverId: guestId)
    let reply = accounts.addChannelMessageForTesting(channelId: canonicalThread, content: "joint thread reply target", senderId: hostOwner)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let guest = try await contextLogin(client, email: guestEmail)
            let context = try await client.get(
                URI(string: "/api/messages/context/\(reply.prefix(8))?channelId=\(guestProjection)"),
                headers: contextHeaders(guest, guestId)
            )
            #expect(context.status == .ok)
            let body = try contextObject(context)
            #expect(body["channelId"] as? String == guestThread)
            #expect(body["targetMessageId"] as? String == reply)
            let canonical = try #require(body["canonicalTarget"] as? [String: Any])
            #expect(canonical["kind"] as? String == "thread")
            #expect(canonical["channelId"] as? String == guestProjection)
            #expect(canonical["threadChannelId"] as? String == guestThread)
            #expect(canonical["threadParentMessageId"] as? String == parent)
            #expect((body["messages"] as? [[String: Any]] ?? []).contains {
                $0["id"] as? String == reply && $0["channelId"] as? String == guestThread
            })

            let local = try await client.get(
                URI(string: "/api/messages/context/\(reply.prefix(8))?channelId=\(guestThread)"),
                headers: contextHeaders(guest, guestId)
            )
            #expect(local.status == .ok)
            let localBody = try contextObject(local)
            #expect(localBody["channelId"] as? String == guestThread)
            #expect(localBody["targetMessageId"] as? String == reply)
        }
    }
}
