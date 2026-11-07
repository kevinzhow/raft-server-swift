import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import RaftRealtime
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The executable's LedgerRealtimeAuth delegates, over this case's actual owners.
private struct ReadRevokeSocketAuth: RealtimeAuthorizing {
    let core: AuthCoreService
    let membership: SocketMembershipService

    func userId(forAccessToken token: String) -> String? {
        core.sessionIdentity(accessToken: token)?.userId
    }

    func sessionFamilyId(forAccessToken token: String) -> String? {
        core.sessionIdentity(accessToken: token)?.familyId
    }

    func serverRole(serverId: String, userId: String) -> String? {
        membership.serverRole(serverId: serverId, userId: userId)
    }

    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        membership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }

    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String? {
        membership.syncMessages(serverId: serverId, userId: userId, lastSeq: lastSeq, limit: limit)?.jsonBody()
    }
}

private struct ReadRevokeServers: Sendable {
    let fixed: RealtimeServer
    let general: RealtimeServer

    init(accounts: EmailLoginDirectory) async throws {
        let auth = ReadRevokeSocketAuth(core: accounts.authCore, membership: accounts.socketMembership)
        let fixed = try await RealtimeServer.start(auth: auth)
        let general: RealtimeServer
        do {
            general = try await RealtimeServer.start(auth: auth)
        } catch {
            try? await fixed.close()
            throw error
        }
        self.fixed = fixed
        self.general = general
    }

    func close() async throws {
        do {
            try await general.close()
        } catch {
            try? await fixed.close()
            throw error
        }
        try await fixed.close()
    }
}

private func readRevokePost(
    _ client: any Client, _ path: String, body: String,
    token: String? = nil, serverId: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let token { headers[.authorization] = "Bearer \(token)" }
    if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
    return try await client.send(.post, headers: headers, to: URI(string: path)) {
        $0.body = .init(string: body)
    }
}

private func readRevokeObject(_ response: ClientResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
}

private func readRevokeConnect(
    _ server: RealtimeServer, token: String, serverId: String
) async throws -> SocketIOTestClient {
    let socket = try await SocketIOTestClient(port: server.port)
    do {
        _ = try #require(await socket.waitForText { $0.hasPrefix("0") })
        socket.send("40{\"token\":\"\(token)\",\"serverId\":\"\(serverId)\"}")
        _ = try #require(await socket.waitForText { $0 == "42[\"rooms:joined\"]" })
        return socket
    } catch {
        socket.close()
        throw error
    }
}

/// Observe every application frame before a unique marker on this session queue.
/// This is received wire data; no producer-side callback is recorded.
private func readRevokeFrames(
    _ socket: SocketIOTestClient, hub: RealtimeHub, userId: String, start: Int
) async throws -> [String] {
    let nonce = UUID().uuidString.lowercased()
    let payload = "{\"nonce\":\"\(nonce)\"}"
    let fence = "42[\"test:read-revoke-fence\",\(payload)]"
    hub.emit(room: "user:\(userId)", event: "test:read-revoke-fence", payloadJSON: payload)
    _ = try #require(await socket.waitForText { $0 == fence })
    let frames = socket.textFrames
    let end = try #require(frames.indices.first { $0 >= start && frames[$0] == fence })
    return Array(frames[start..<end].filter { $0.hasPrefix("42") })
}

private func readRevokeRoomProbe(
    _ socket: SocketIOTestClient, hub: RealtimeHub, userId: String, channelId: String
) async throws {
    // Threads are not in the automatic channel/private/dm handshake room list.
    // This explicit transport subscription makes the receipt filter observable.
    hub.joinUserSessions(userId: userId, room: "channel:\(channelId)")
    let nonce = UUID().uuidString.lowercased()
    let payload = "{\"nonce\":\"\(nonce)\"}"
    let probe = "42[\"test:read-revoke-probe\",\(payload)]"
    hub.emit(room: "channel:\(channelId)", event: "test:read-revoke-probe", payloadJSON: payload)
    _ = try #require(await socket.waitForText { $0 == probe })
}

private func readRevokeReceipt(channelId: String, agentId: String, seq: Int) -> String {
    "42[\"scope_read:updated\",{\"scopeId\":\"\(channelId)\",\"peerKind\":\"agent\",\"peerId\":\"\(agentId)\",\"maxReadSeq\":\(seq)}]"
}

@Test func familyRevokeClosesOnlyTheSelectedFamilyOnItsFixedHost() async throws {
    let accounts = EmailLoginDirectory()
    let servers = try await ReadRevokeServers(accounts: accounts)
    do {
        accounts.realtimeRelay.install { room, event, payload in
            servers.general.hub.emit(room: room, event: event, payloadJSON: payload)
        }
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: accounts, realtime: servers.fixed.hub
            ))
            try await app.testing { client in
                let email = "revoke-\(UUID().uuidString.lowercased())@production.test"
                let registered = try await readRevokePost(
                    client, "/api/auth/register",
                    body: "{\"email\":\"\(email)\",\"password\":\"password123\",\"acceptTerms\":true,\"termsVersion\":\"\(AuthLegalPolicy.termsVersion)\",\"privacyVersion\":\"\(AuthLegalPolicy.privacyVersion)\"}"
                )
                #expect(registered.status == .ok)
                let registration = try readRevokeObject(registered)
                let user = try #require(registration["user"] as? [String: Any])
                let userId = try #require(user["id"] as? String)
                let firstToken = try #require(registration["accessToken"] as? String)
                let login = try await readRevokePost(
                    client, "/api/auth/login", body: "{\"email\":\"\(email)\",\"password\":\"password123\"}"
                )
                #expect(login.status == .ok)
                let secondToken = try #require(try readRevokeObject(login)["accessToken"] as? String)
                let firstFamily = try #require(accounts.authCore.sessionIdentity(accessToken: firstToken)?.familyId)
                let secondFamily = try #require(accounts.authCore.sessionIdentity(accessToken: secondToken)?.familyId)
                #expect(firstFamily != secondFamily)
                let serverId = UUID().uuidString.lowercased()
                accounts.oauth.addOwnedServer(id: serverId, slug: "revoke-wire", name: "Revoke Wire", ownerId: userId)

                let pushRegistration = try await readRevokePost(
                    client, "/api/push/registrations",
                    body: #"{"installationId":"production-revoke","provider":"apns","env":"production","topic":"ai.slock.app","deviceToken":"production-token"}"#,
                    token: firstToken, serverId: serverId
                )
                #expect(pushRegistration.status == .ok)
                let capability = try #require(try readRevokeObject(pushRegistration)["revoke_capability"] as? String)
                let nonce = try #require(capability.split(separator: ".").last.map(String.init))
                let changedPrefix = "different-prefix.\(nonce)"
                let push = accounts.managedMCPPush
                let target = try #require(push.familyRevokeTarget(capability: changedPrefix))
                #expect(target.userId == userId)
                #expect(target.familyId == firstFamily)

                let selected = try await readRevokeConnect(servers.fixed, token: firstToken, serverId: serverId)
                defer { selected.close() }
                let survivor = try await readRevokeConnect(servers.fixed, token: secondToken, serverId: serverId)
                defer { survivor.close() }
                let otherHost = try await readRevokeConnect(servers.general, token: firstToken, serverId: serverId)
                defer { otherHost.close() }
                let revoked = try await readRevokePost(
                    client, "/api/push/family-revoke", body: "{\"capability\":\"\(changedPrefix)\"}"
                )
                #expect(revoked.status == .noContent)
                #expect(await selected.waitForClose())
                // Both compared families are non-nil. The legacy Hub also closes
                // same-user nil-family sessions; this case does not alter that rule.
                for (socket, hub) in [(survivor, servers.fixed.hub), (otherHost, servers.general.hub)] {
                    #expect(try await readRevokeFrames(socket, hub: hub, userId: userId, start: socket.textFrames.count) == [])
                }
                let retained = try #require(push.familyRevokeTarget(capability: changedPrefix))
                #expect(retained.userId == userId)
                #expect(retained.familyId == firstFamily)
                #expect(push.familyRevokeTarget(capability: changedPrefix)?.familyId == firstFamily)
            }
        }
    } catch {
        try? await servers.close()
        throw error
    }
    try await servers.close()
}

@Test func startupScopeReadFilteringAndConfigureReplacementKeepDistinctFrames() async throws {
    let accounts = EmailLoginDirectory()
    let userId = UUID().uuidString.lowercased()
    let serverId = UUID().uuidString.lowercased()
    let foreignServerId = UUID().uuidString.lowercased()
    accounts.addAccount(id: userId, email: "\(userId)@production-read.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    for (id, slug) in [(serverId, "read-wire"), (foreignServerId, "read-foreign")] {
        accounts.oauth.addOwnedServer(id: id, slug: slug, name: slug, ownerId: userId)
    }
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "read-agent", creatorUserId: userId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "read-channel", creatorUserId: userId)
    let privateId = accounts.oauth.createChannel(serverId: serverId, name: "read-private", creatorUserId: userId, type: "private")
    let dmId = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: userId, secondUserId: agentId)
    let allId = try #require(accounts.oauth.allChannelId(serverId: serverId))
    let threadId = accounts.oauth.createChannel(serverId: serverId, name: "read-thread", creatorUserId: userId, type: "thread")
    let noMemberId = accounts.oauth.createChannel(serverId: serverId, name: "read-no-agent", creatorUserId: userId)
    let foreignId = accounts.oauth.createChannel(serverId: foreignServerId, name: "read-foreign", creatorUserId: userId)
    let scopes = [(channelId, "read-channel", "channel"), (privateId, "read-private", "private"),
                  (dmId, "read-dm", "dm"), (allId, "all", "channel"), (threadId, "read-thread", "thread")]
    for (id, name, kind) in scopes {
        accounts.addPostableChannel(serverId: serverId, channelId: id, memberId: userId, kind: kind, name: name)
        accounts.oauth.addChannelHuman(channelId: id, userId: userId)
        accounts.oauth.addChannelAgent(channelId: id, agentId: agentId)
    }
    accounts.oauth.addChannelAgent(channelId: foreignId, agentId: agentId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    let receiver = try JSONDecoder().decode(
        ChannelReadAllRequest.self, from: Data("{\"receiver\":{\"kind\":\"agent\",\"id\":\"\(agentId)\"}}".utf8)
    )
    let tools = accounts.managedMCPToolExecution
    let servers = try await ReadRevokeServers(accounts: accounts)
    do {
        accounts.realtimeRelay.install { room, event, payload in
            servers.general.hub.emit(room: room, event: event, payloadJSON: payload)
        }
        tools.installReadUpdateObserver { serverId, channelId, agentId, seq in
            guard tools.shouldEmitStartupScopeRead(serverId: serverId, channelId: channelId, agentId: agentId) else { return }
            servers.fixed.hub.emitScopeReadUpdated(serverId: serverId, scopeId: channelId, agentId: agentId, maxReadSeq: seq)
        }
        let fixed = try await readRevokeConnect(servers.fixed, token: token, serverId: serverId)
        defer { fixed.close() }
        let general = try await readRevokeConnect(servers.general, token: token, serverId: serverId)
        defer { general.close() }
        for (id, _, _) in scopes {
            try await readRevokeRoomProbe(fixed, hub: servers.fixed.hub, userId: userId, channelId: id)
            try await readRevokeRoomProbe(general, hub: servers.general.hub, userId: userId, channelId: id)
        }
        #expect(!tools.shouldEmitStartupScopeRead(serverId: serverId, channelId: channelId, agentId: agentId))
        let disabledMessage = accounts.oauth.createMessageRecord(channelId: channelId, content: "receipts off", senderId: userId)
        let disabledFixedStart = fixed.textFrames.count
        let disabledGeneralStart = general.textFrames.count
        let disabledRead = try tools.markChannelReadAll(authorization: "Bearer \(token)", serverId: serverId, channelId: channelId, body: receiver)
        #expect(disabledRead.seq == disabledMessage.seq)
        #expect(disabledRead.readStateVersion == 1)
        #expect(try await readRevokeFrames(fixed, hub: servers.fixed.hub, userId: userId, start: disabledFixedStart) == [])
        #expect(try await readRevokeFrames(general, hub: servers.general.hub, userId: userId, start: disabledGeneralStart) == [])

        accounts.enableReadReceiptsForServer(serverId)
        #expect(!tools.shouldEmitStartupScopeRead(serverId: serverId, channelId: UUID().uuidString.lowercased(), agentId: agentId))
        #expect(!tools.shouldEmitStartupScopeRead(serverId: serverId, channelId: foreignId, agentId: agentId))
        #expect(!tools.shouldEmitStartupScopeRead(serverId: serverId, channelId: allId, agentId: agentId))
        #expect(!tools.shouldEmitStartupScopeRead(serverId: serverId, channelId: threadId, agentId: agentId))
        #expect(!tools.shouldEmitStartupScopeRead(serverId: serverId, channelId: noMemberId, agentId: agentId))
        var startupResponses: [ChannelReadAllResponse] = []
        for (id, _, kind) in scopes {
            let permitted = id != allId && kind != "thread"
            #expect(tools.shouldEmitStartupScopeRead(serverId: serverId, channelId: id, agentId: agentId) == permitted)
            let message = accounts.oauth.createMessageRecord(channelId: id, content: "startup read", senderId: userId)
            let fixedStart = fixed.textFrames.count
            let generalStart = general.textFrames.count
            let read = try tools.markChannelReadAll(authorization: "Bearer \(token)", serverId: serverId, channelId: id, body: receiver)
            #expect(read.seq == message.seq)
            #expect(read.readStateVersion == (id == channelId ? disabledRead.readStateVersion + 1 : 1))
            startupResponses.append(read)
            let expected = permitted ? [readRevokeReceipt(channelId: id, agentId: agentId, seq: message.seq)] : []
            #expect(try await readRevokeFrames(fixed, hub: servers.fixed.hub, userId: userId, start: fixedStart) == expected)
            #expect(try await readRevokeFrames(general, hub: servers.general.hub, userId: userId, start: generalStart) == [])
        }
        let priorResponses = startupResponses
        // This is the real full configure replacement of the same notification
        // slot, not a second observer installed by this test. Its predicate is lax.
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: accounts, realtime: servers.fixed.hub
            ))
            try await app.testing { client in
                for (index, scope) in scopes.enumerated() {
                    let id = scope.0
                    let message = accounts.oauth.createMessageRecord(channelId: id, content: "configured read", senderId: userId)
                    let fixedStart = fixed.textFrames.count
                    let generalStart = general.textFrames.count
                    let expectedRead = ChannelReadAllResponse(seq: message.seq, readStateVersion: priorResponses[index].readStateVersion + 1)
                    let response = try await readRevokePost(
                        client, "/api/channels/\(id)/read-all",
                        body: "{\"receiver\":{\"kind\":\"agent\",\"id\":\"\(agentId)\"}}", token: token, serverId: serverId
                    )
                    #expect(response.status == .ok)
                    #expect(response.body.string == expectedRead.jsonBody.render())
                    #expect(try await readRevokeFrames(fixed, hub: servers.fixed.hub, userId: userId, start: fixedStart) == [])
                    #expect(try await readRevokeFrames(general, hub: servers.general.hub, userId: userId, start: generalStart) == [readRevokeReceipt(channelId: id, agentId: agentId, seq: message.seq)])
                }
                accounts.realtimeRelay.install { room, event, payload in
                    servers.fixed.hub.emit(room: room, event: event, payloadJSON: payload)
                }
                let message = accounts.oauth.createMessageRecord(channelId: channelId, content: "rebound relay read", senderId: userId)
                let fixedStart = fixed.textFrames.count
                let generalStart = general.textFrames.count
                let response = try await readRevokePost(
                    client, "/api/channels/\(channelId)/read-all",
                    body: "{\"receiver\":{\"kind\":\"agent\",\"id\":\"\(agentId)\"}}", token: token, serverId: serverId
                )
                #expect(response.status == .ok)
                #expect(response.body.string == ChannelReadAllResponse(seq: message.seq, readStateVersion: priorResponses[0].readStateVersion + 2).jsonBody.render())
                #expect(try await readRevokeFrames(fixed, hub: servers.fixed.hub, userId: userId, start: fixedStart) == [readRevokeReceipt(channelId: channelId, agentId: agentId, seq: message.seq)])
                #expect(try await readRevokeFrames(general, hub: servers.general.hub, userId: userId, start: generalStart) == [])
            }
        }
    } catch {
        try? await servers.close()
        throw error
    }
    try await servers.close()
}
