import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ReactionFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let messageId: String
    let ownerId: String
    let ownerEmail: String
    let ownerDisplay: String
}

private func makeReactionFixture(suffix: String) -> ReactionFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 950_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 950_000 + number)
    let ownerEmail = "reaction-owner-\(suffix)@slock.test"
    let ownerDisplay = "Reaction Owner \(suffix)"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.setAccountProfileForTesting(id: ownerId, name: "reaction-owner-\(suffix)", displayName: ownerDisplay)
    accounts.oauth.addOwnedServer(id: serverId, slug: "reaction-server-\(suffix)", name: "Reaction Server", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "reaction-channel-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "reaction-channel-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let message = accounts.addChannelMessageForTesting(channelId: channel, content: "reactable message", senderId: ownerId)
    return ReactionFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channel,
        messageId: message,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        ownerDisplay: ownerDisplay
    )
}

private func reactionLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func reactionHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func reactionObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func messageReactionsAddIdempotentlyEnrichAndRemoveCleanly() async throws {
    let fixture = makeReactionFixture(suffix: "981")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await reactionLogin(client, email: fixture.ownerEmail)
            let headers = reactionHeaders(token, fixture.serverId)
            let path = "/api/messages/\(fixture.messageId)/reactions"

            let first = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                request.body = .init(string: "{\"emoji\":\"👍\"}")
            }
            #expect(first.status == .ok)
            #expect(try reactionObject(first)["reactions"] as? NSArray == [
                ["emoji": "👍", "count": 1, "reactorIds": [fixture.ownerId], "reactorNames": [fixture.ownerDisplay]] as NSDictionary
            ] as NSArray)

            let second = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                request.body = .init(string: "{\"emoji\":\"👍\"}")
            }
            #expect(second.status == .ok)
            let secondReactions = try reactionObject(second)["reactions"] as? [[String: Any]] ?? []
            #expect(secondReactions.first { $0["emoji"] as? String == "👍" }?["count"] as? Int == 1)

            let list = try await client.get("/api/messages/channel/\(fixture.channelId)", headers: headers)
            #expect(list.status == .ok)
            let rows = try reactionObject(list)["messages"] as? [[String: Any]] ?? []
            let row = try #require(rows.first { $0["id"] as? String == fixture.messageId })
            let listedReactions = row["reactions"] as? [[String: Any]] ?? []
            #expect(listedReactions.first?["count"] as? Int == 1)

            let remove = try await client.send(.delete, headers: headers, to: URI(string: path)) { request in
                request.body = .init(string: "{\"emoji\":\"👍\"}")
            }
            #expect(remove.status == .ok)
            #expect(try reactionObject(remove)["reactions"] as? NSArray == [] as NSArray)
            #expect(fixture.accounts.storedMessageReactionActors(messageId: fixture.messageId).isEmpty)
        }
    }
}

@Test func agentReactionsUseTheRuntimeDisplayName() async throws {
    let fixture = makeReactionFixture(suffix: "982")
    let agentName = "reaction-agent-982"
    let agentDisplay = "Reaction Agent 982"
    let agent = fixture.accounts.oauth.createAgent(
        serverId: fixture.serverId,
        name: agentName,
        displayName: agentDisplay,
        runtime: "codex"
    )
    fixture.accounts.oauth.addChannelAgent(channelId: fixture.channelId, agentId: agent)
    fixture.accounts.addChannelAgent(channelId: fixture.channelId, agentId: agent)
    let machineKey = fixture.accounts.registerMachineForAgent(serverId: fixture.serverId, agentId: agent)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await reactionLogin(client, email: fixture.ownerEmail)
            let humanHeaders = reactionHeaders(token, fixture.serverId)
            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(machineKey)"
            agentHeaders[.contentType] = "application/json"
            let agentPath = "/internal/agent/\(agent)/messages/\(fixture.messageId)/reactions"
            func agentMutate(_ method: HTTPRequest.Method) async throws -> ClientResponse {
                try await client.send(method, headers: agentHeaders, to: URI(string: agentPath)) { request in
                    request.body = .init(string: "{\"emoji\":\"👀\"}")
                }
            }

            let first = try await agentMutate(.post)
            #expect(first.status == .ok)
            #expect(try reactionObject(first)["reactions"] as? NSArray == [
                ["emoji": "👀", "count": 1, "reactorIds": [agent], "reactorNames": [agentDisplay]] as NSDictionary
            ] as NSArray)

            let second = try await agentMutate(.post)
            let secondReactions = try reactionObject(second)["reactions"] as? [[String: Any]] ?? []
            #expect(secondReactions.first?["count"] as? Int == 1)

            let human = try await client.send(.post, headers: humanHeaders, to: URI(string: "/api/messages/\(fixture.messageId)/reactions")) { request in
                request.body = .init(string: "{\"emoji\":\"👀\"}")
            }
            #expect(human.status == .ok)
            let combined = (try reactionObject(human)["reactions"] as? [[String: Any]] ?? [])
                .first { $0["emoji"] as? String == "👀" }
            #expect(combined?["count"] as? Int == 2)
            #expect(Set(combined?["reactorIds"] as? [String] ?? []) == Set([agent, fixture.ownerId]))

            let removed = try await agentMutate(.delete)
            #expect(removed.status == .ok)
            let remaining = (try reactionObject(removed)["reactions"] as? [[String: Any]] ?? [])
                .first { $0["emoji"] as? String == "👀" }
            #expect(remaining?["count"] as? Int == 1)
            #expect(remaining?["reactorIds"] as? [String] == [fixture.ownerId])
        }
    }
}

@Test func reactionsRejectSystemArchivedDeletedAndNonMemberWrites() async throws {
    let fixture = makeReactionFixture(suffix: "983")
    let outsiderId = "11111111-1111-4111-8111-111111111983"
    fixture.accounts.addAccount(id: outsiderId, email: "reaction-outsider-983@slock.test", password: "password123")
    fixture.accounts.markEmailVerified(userId: outsiderId)
    fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: outsiderId, role: "member")
    let systemId = fixture.accounts.addChannelMessageForTesting(
        channelId: fixture.channelId,
        content: "system event",
        senderId: "system",
        senderType: "system",
        messageType: "system"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await reactionLogin(client, email: fixture.ownerEmail)
            let outsider = try await reactionLogin(client, email: "reaction-outsider-983@slock.test")
            let ownerHeaders = reactionHeaders(owner, fixture.serverId)
            let outsiderHeaders = reactionHeaders(outsider, fixture.serverId)
            func react(_ headers: HTTPFields, _ method: HTTPRequest.Method, _ messageId: String) async throws -> ClientResponse {
                try await client.send(method, headers: headers, to: URI(string: "/api/messages/\(messageId)/reactions")) { request in
                    request.body = .init(string: "{\"emoji\":\"👍\"}")
                }
            }

            #expect(try await react(ownerHeaders, .post, systemId).status == .badRequest)
            #expect(try await react(outsiderHeaders, .post, fixture.messageId).status == .forbidden)
            #expect(try await react(outsiderHeaders, .delete, fixture.messageId).status == .forbidden)

            fixture.accounts.archiveChannel(channelId: fixture.channelId)
            let archived = try await react(ownerHeaders, .post, fixture.messageId)
            #expect(archived.status == .conflict)
            #expect(try reactionObject(archived)["code"] as? String == "channel_archived")

            fixture.accounts.markChannelDeleted(channelId: fixture.channelId)
            #expect(try await react(ownerHeaders, .post, fixture.messageId).status == .notFound)
            #expect(try await react(ownerHeaders, .delete, fixture.messageId).status == .notFound)
        }
    }
}

@Test func reactionActorPagesBindCursorsAndStaleOnEveryMutation() async throws {
    let fixture = makeReactionFixture(suffix: "984")
    let memberId = "11111111-1111-4111-8111-111111111984"
    let memberEmail = "reaction-page-member-984@slock.test"
    fixture.accounts.addAccount(id: memberId, email: memberEmail, password: "password123")
    fixture.accounts.markEmailVerified(userId: memberId)
    fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: memberId, role: "member")
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: fixture.channelId, memberId: memberId, name: "reaction-channel-984")
    fixture.accounts.oauth.addChannelHuman(channelId: fixture.channelId, userId: memberId)
    let agent = fixture.accounts.oauth.createAgent(serverId: fixture.serverId, name: "reaction-page-agent-984", runtime: "codex")
    fixture.accounts.oauth.addChannelAgent(channelId: fixture.channelId, agentId: agent)
    fixture.accounts.addChannelAgent(channelId: fixture.channelId, agentId: agent)
    let machineKey = fixture.accounts.registerMachineForAgent(serverId: fixture.serverId, agentId: agent)
    let agentApiKey = fixture.accounts.mintAgentCredential(agentId: agent, scopes: ["reactions"], name: "reaction-page-agent-api-984")
    let otherMessage = fixture.accounts.addChannelMessageForTesting(
        channelId: fixture.channelId,
        content: "reaction page other target",
        senderId: fixture.ownerId
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await reactionLogin(client, email: fixture.ownerEmail)
            let member = try await reactionLogin(client, email: memberEmail)
            let ownerHeaders = reactionHeaders(owner, fixture.serverId)
            let memberHeaders = reactionHeaders(member, fixture.serverId)
            for headers in [ownerHeaders, memberHeaders] {
                let add = try await client.send(.post, headers: headers, to: URI(string: "/api/messages/\(fixture.messageId)/reactions")) { request in
                    request.body = .init(string: "{\"emoji\":\"👀\"}")
                }
                #expect(add.status == .ok)
            }

            func page(_ query: String, headers: HTTPFields) async throws -> ClientResponse {
                try await client.get(URI(string: "/api/messages/\(fixture.messageId)/reactions/actors?\(query)"), headers: headers)
            }
            let first = try await page("emoji=%F0%9F%91%80&limit=1", headers: ownerHeaders)
            #expect(first.status == .ok)
            let firstBody = try reactionObject(first)
            #expect(firstBody["discussionVersion"] as? Int == 2)
            let firstActors = firstBody["actors"] as? [[String: Any]] ?? []
            #expect(firstActors.count == 1)
            #expect((firstActors.first?["actorRef"] as? [String: Any])?["kind"] as? String == "user")
            let firstCursor = try #require(firstBody["nextCursor"] as? String)
            let encodedCursor = firstCursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? firstCursor

            let principalReplay = try await page("emoji=%F0%9F%91%80&cursor=\(encodedCursor)", headers: memberHeaders)
            #expect(principalReplay.status == .badRequest)
            #expect(try reactionObject(principalReplay)["code"] as? String == "invalid_reaction_actors_cursor")

            let wrongMessage = try await client.get(
                URI(string: "/api/messages/\(otherMessage)/reactions/actors?emoji=%F0%9F%91%80&cursor=\(encodedCursor)"),
                headers: ownerHeaders
            )
            #expect(wrongMessage.status == .badRequest)
            let wrongEmoji = try await page("emoji=%F0%9F%91%8D&cursor=\(encodedCursor)", headers: ownerHeaders)
            #expect(wrongEmoji.status == .badRequest)

            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(machineKey)"
            agentHeaders[.contentType] = "application/json"
            let agentAdd = try await client.send(.post, headers: agentHeaders, to: URI(string: "/internal/agent/\(agent)/messages/\(fixture.messageId)/reactions")) { request in
                request.body = .init(string: "{\"emoji\":\"👀\"}")
            }
            #expect(agentAdd.status == .ok)

            let stale = try await page("emoji=%F0%9F%91%80&cursor=\(encodedCursor)", headers: ownerHeaders)
            #expect(stale.status == .conflict)
            #expect(try reactionObject(stale) as NSDictionary == [
                "error": "Reaction discussion changed while reading this page",
                "code": "reaction_discussion_version_changed",
                "currentDiscussionVersion": 3,
                "rebaselineRequired": true,
            ] as NSDictionary)

            let legacyPage = try await page("emoji=%F0%9F%91%80&limit=1", headers: ownerHeaders)
            let legacyBody = try reactionObject(legacyPage)
            let legacyCursor = try #require(legacyBody["nextCursor"] as? String)
            let encodedLegacy = legacyCursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? legacyCursor

            var apiHeaders = HTTPFields()
            apiHeaders[.authorization] = "Bearer \(agentApiKey)"
            apiHeaders[.contentType] = "application/json"
            let apiRemove = try await client.send(.delete, headers: apiHeaders, to: URI(string: "/internal/agent-api/messages/\(fixture.messageId)/reactions")) { request in
                request.body = .init(string: "{\"emoji\":\"👀\"}")
            }
            #expect(apiRemove.status == .ok)
            let apiStale = try await page("emoji=%F0%9F%91%80&cursor=\(encodedLegacy)", headers: ownerHeaders)
            #expect(apiStale.status == .conflict)
            #expect(try reactionObject(apiStale)["currentDiscussionVersion"] as? Int == 4)

            let apiRestore = try await client.send(.post, headers: apiHeaders, to: URI(string: "/internal/agent-api/messages/\(fixture.messageId)/reactions")) { request in
                request.body = .init(string: "{\"emoji\":\"👀\"}")
            }
            #expect(apiRestore.status == .ok)
            let fresh = try await page("emoji=%F0%9F%91%80&limit=100", headers: ownerHeaders)
            #expect(fresh.status == .ok)
            let freshBody = try reactionObject(fresh)
            #expect(freshBody["discussionVersion"] as? Int == 5)
            let refs = (freshBody["actors"] as? [[String: Any]] ?? []).compactMap { actor -> String? in
                guard let ref = actor["actorRef"] as? [String: Any],
                      let kind = ref["kind"] as? String, let id = ref["id"] as? String else { return nil }
                return "\(kind):\(id)"
            }
            #expect(Set(refs) == Set(["user:\(fixture.ownerId)", "user:\(memberId)", "agent:\(agent)"]))
        }
    }
}

@Test func reactionActorReadCloaksAndRejectsInvalidInputs() async throws {
    let fixture = makeReactionFixture(suffix: "985")
    let outsiderId = "11111111-1111-4111-8111-111111111985"
    let outsiderEmail = "reaction-read-outsider-985@slock.test"
    fixture.accounts.addAccount(id: outsiderId, email: outsiderEmail, password: "password123")
    fixture.accounts.markEmailVerified(userId: outsiderId)
    fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: outsiderId, role: "member")
    let otherServerId = "33333333-3333-4333-8333-333333333986"
    fixture.accounts.oauth.addOwnedServer(id: otherServerId, slug: "reaction-other-985", name: "Other", ownerId: fixture.ownerId)

    let privateChannel = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "reaction-private-985", creatorUserId: fixture.ownerId, type: "private")
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: privateChannel, memberId: fixture.ownerId, kind: "private", name: "reaction-private-985")
    fixture.accounts.oauth.addChannelHuman(channelId: privateChannel, userId: fixture.ownerId)
    let privateMessage = fixture.accounts.addChannelMessageForTesting(channelId: privateChannel, content: "private actor read", senderId: fixture.ownerId)
    fixture.accounts.addMessageReactionForTesting(messageId: privateMessage, emoji: "👍", reactorId: fixture.ownerId, reactorType: "user")

    let publicChannel = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "reaction-public-985", creatorUserId: fixture.ownerId)
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: publicChannel, memberId: fixture.ownerId, name: "reaction-public-985")
    fixture.accounts.oauth.addChannelHuman(channelId: publicChannel, userId: fixture.ownerId)
    fixture.accounts.insertHumanMessage(id: "eeeeeeee-1111-4111-8111-111111111111", channelId: publicChannel, senderId: fixture.ownerId, content: "collision one")
    fixture.accounts.insertHumanMessage(id: "eeeeeeee-2222-4222-8222-222222222222", channelId: publicChannel, senderId: fixture.ownerId, content: "collision two")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await reactionLogin(client, email: fixture.ownerEmail)
            let outsider = try await reactionLogin(client, email: outsiderEmail)
            let ownerHeaders = reactionHeaders(owner, fixture.serverId)
            let outsiderHeaders = reactionHeaders(outsider, fixture.serverId)
            func actors(_ path: String, _ headers: HTTPFields) async throws -> ClientResponse {
                try await client.get(URI(string: path), headers: headers)
            }

            let privateRead = try await actors("/api/messages/\(privateMessage)/reactions/actors?emoji=%F0%9F%91%8D", outsiderHeaders)
            #expect(privateRead.status == .notFound)

            fixture.accounts.archiveChannel(channelId: privateChannel)
            let archived = try await actors("/api/messages/\(privateMessage)/reactions/actors?emoji=%F0%9F%91%8D", ownerHeaders)
            #expect(archived.status == .conflict)
            #expect(try reactionObject(archived)["code"] as? String == "channel_archived")

            let collision = try await actors("/api/messages/eeeeeeee/reactions/actors?emoji=%F0%9F%91%8D", ownerHeaders)
            #expect(collision.status == .badRequest)

            let wrongServerHeaders = reactionHeaders(owner, otherServerId)
            let wrongServer = try await actors("/api/messages/eeeeeeee-1111-4111-8111-111111111111/reactions/actors?emoji=%F0%9F%91%8D", wrongServerHeaders)
            #expect(wrongServer.status == .notFound)

            let invalidEmoji = try await actors("/api/messages/eeeeeeee-1111-4111-8111-111111111111/reactions/actors?emoji=not%20emoji", ownerHeaders)
            #expect(invalidEmoji.status == .badRequest)
            #expect(try reactionObject(invalidEmoji)["code"] as? String == "invalid_reaction_emoji")

            let invalidCursor = try await actors("/api/messages/eeeeeeee-1111-4111-8111-111111111111/reactions/actors?emoji=%F0%9F%91%8D&cursor=tampered", ownerHeaders)
            #expect(invalidCursor.status == .badRequest)
            #expect(try reactionObject(invalidCursor)["code"] as? String == "invalid_reaction_actors_cursor")
        }
    }
}

@Test func jointReactionActorDiscussionUsesTheRequesterLocalScope() async throws {
    let accounts = EmailLoginDirectory()
    let hostId = "33333333-3333-4333-8333-333333333987"
    let guestId = "33333333-3333-4333-8333-333333333988"
    let hostOwner = "11111111-1111-4111-8111-111111111987"
    let guestOwner = "11111111-1111-4111-8111-111111111988"
    let hostEmail = "reaction-joint-host-987@slock.test"
    let guestEmail = "reaction-joint-guest-987@slock.test"
    for (id, email) in [(hostOwner, hostEmail), (guestOwner, guestEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: hostId, slug: "reaction-joint-host-987", name: "Host", ownerId: hostOwner)
    accounts.oauth.addOwnedServer(id: guestId, slug: "reaction-joint-guest-987", name: "Guest", ownerId: guestOwner)
    let hostProjection = accounts.oauth.createChannel(serverId: hostId, name: "reaction-joint-room-987", creatorUserId: hostOwner, type: "joint")
    let guestProjection = accounts.oauth.createChannel(serverId: guestId, name: "reaction-joint-room-987", creatorUserId: guestOwner, type: "joint")
    accounts.addPostableChannel(serverId: hostId, channelId: hostProjection, memberId: hostOwner, kind: "joint", name: "reaction-joint-room-987")
    accounts.addPostableChannel(serverId: guestId, channelId: guestProjection, memberId: guestOwner, kind: "joint", name: "reaction-joint-room-987")
    accounts.oauth.addChannelHuman(channelId: hostProjection, userId: hostOwner)
    accounts.oauth.addChannelHuman(channelId: guestProjection, userId: guestOwner)
    accounts.addJointChannelProjection(localChannelId: hostProjection, canonicalChannelId: hostProjection, serverId: hostId)
    accounts.addJointChannelProjection(localChannelId: guestProjection, canonicalChannelId: hostProjection, serverId: guestId)
    let message = accounts.addChannelMessageForTesting(channelId: hostProjection, content: "joint actor page", senderId: hostOwner)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let hostToken = try await reactionLogin(client, email: hostEmail)
            let guestToken = try await reactionLogin(client, email: guestEmail)
            for (token, serverId) in [(hostToken, hostId), (guestToken, guestId)] {
                let add = try await client.send(.post, headers: reactionHeaders(token, serverId), to: URI(string: "/api/messages/\(message)/reactions")) { request in
                    request.body = .init(string: "{\"emoji\":\"👀\"}")
                }
                #expect(add.status == .ok)
            }
            let guestPage = try await client.get(
                URI(string: "/api/messages/\(message)/reactions/actors?emoji=%F0%9F%91%80&limit=1"),
                headers: reactionHeaders(guestToken, guestId)
            )
            #expect(guestPage.status == .ok)
            let guestBody = try reactionObject(guestPage)
            let discussion = try #require(guestBody["discussion"] as? [String: Any])
            #expect((discussion["root"] as? [String: Any])?["serverId"] as? String == guestId)
            #expect((discussion["parentScope"] as? [String: Any])?["scopeId"] as? String == guestProjection)
            let cursor = try #require(guestBody["nextCursor"] as? String)
            let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cursor
            let peerReplay = try await client.get(
                URI(string: "/api/messages/\(message)/reactions/actors?emoji=%F0%9F%91%80&cursor=\(encoded)"),
                headers: reactionHeaders(hostToken, hostId)
            )
            #expect(peerReplay.status == .badRequest)
            #expect(try reactionObject(peerReplay)["code"] as? String == "invalid_reaction_actors_cursor")
        }
    }
}

@Test func reactionActorPaginationHidesDirectoryMembersBeforePaging() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-333333333989"
    let ownerId = "11111111-1111-4111-8111-111111111989"
    let memberId = "11111111-1111-4111-8111-111111111990"
    let otherId = "11111111-1111-4111-8111-111111111991"
    let memberEmail = "reaction-directory-member-989@slock.test"
    let ownerEmail = "reaction-directory-owner-989@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (memberId, memberEmail), (otherId, "reaction-directory-other-989@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "reaction-directory-989", name: "Directory", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: otherId, role: "member")
    accounts.setHideHumansFromMembers(serverId: serverId, hidden: true)
    let allChannel = accounts.oauth.createChannel(serverId: serverId, name: "all", creatorUserId: ownerId)
    for member in [ownerId, memberId, otherId] {
        accounts.addPostableChannel(serverId: serverId, channelId: allChannel, memberId: member, name: "all")
    }
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "reaction-directory-agent-989", runtime: "codex")
    accounts.addChannelAgent(channelId: allChannel, agentId: agent)
    let message = accounts.addChannelMessageForTesting(channelId: allChannel, content: "hidden directory reaction target", senderId: ownerId)
    for id in [ownerId, memberId, otherId] {
        accounts.addMessageReactionForTesting(messageId: message, emoji: "👀", reactorId: id, reactorType: "user")
    }
    accounts.addMessageReactionForTesting(messageId: message, emoji: "👀", reactorId: agent, reactorType: "agent")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let memberToken = try await reactionLogin(client, email: memberEmail)
            let ownerToken = try await reactionLogin(client, email: ownerEmail)
            let memberHeaders = reactionHeaders(memberToken, serverId)
            let ownerHeaders = reactionHeaders(ownerToken, serverId)
            var refs: [String] = []
            var cursor: String?
            var firstCursor: String?
            repeat {
                var path = "/api/messages/\(message)/reactions/actors?emoji=%F0%9F%91%80&limit=1"
                if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                    path += "&cursor=\(encoded)"
                }
                let response = try await client.get(URI(string: path), headers: memberHeaders)
                #expect(response.status == .ok)
                let body = try reactionObject(response)
                refs += (body["actors"] as? [[String: Any]] ?? []).compactMap { actor in
                    guard let ref = actor["actorRef"] as? [String: Any],
                          let kind = ref["kind"] as? String, let id = ref["id"] as? String else { return nil }
                    return "\(kind):\(id)"
                }
                let next = body["nextCursor"] as? String
                firstCursor = firstCursor ?? next
                cursor = next
            } while cursor != nil
            #expect(refs == ["agent:\(agent)", "user:\(memberId)"])

            accounts.setHideHumansFromMembers(serverId: serverId, hidden: false)
            let firstEncoded = (firstCursor ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let changed = try await client.get(
                URI(string: "/api/messages/\(message)/reactions/actors?emoji=%F0%9F%91%80&cursor=\(firstEncoded)"),
                headers: memberHeaders
            )
            #expect(changed.status == .conflict)
            #expect(try reactionObject(changed)["code"] as? String == "reaction_actor_visibility_changed")

            let ownerResponse = try await client.get(
                URI(string: "/api/messages/\(message)/reactions/actors?emoji=%F0%9F%91%80&limit=100"),
                headers: ownerHeaders
            )
            #expect(ownerResponse.status == .ok)
            let ownerRefs = Set((try reactionObject(ownerResponse)["actors"] as? [[String: Any]] ?? []).compactMap { actor -> String? in
                guard let ref = actor["actorRef"] as? [String: Any],
                      let kind = ref["kind"] as? String, let id = ref["id"] as? String else { return nil }
                return "\(kind):\(id)"
            })
            #expect(ownerRefs == Set(["user:\(ownerId)", "user:\(memberId)", "user:\(otherId)", "agent:\(agent)"]))
        }
    }
}
