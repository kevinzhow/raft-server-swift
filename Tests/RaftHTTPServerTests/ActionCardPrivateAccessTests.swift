import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func makePrivateCarrierFixture() -> (accounts: EmailLoginDirectory, serverId: String, ownerId: String, outsiderId: String, agentId: String, privateChannel: String) {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001088001"
    let ownerId = "11111111-1111-4111-8111-000001088001"
    let outsiderId = "11111111-1111-4111-8111-000001088002"
    accounts.addAccount(id: ownerId, email: "card-owner@private.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: outsiderId, email: "card-outsider@private.test", password: "password123")
    accounts.markEmailVerified(userId: outsiderId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "private-card", name: "Private Card", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "private-card-agent", creatorUserId: ownerId, runtime: "claude")
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "private-card-channel", creatorUserId: ownerId, type: "private")
    accounts.oauth.addChannelHuman(channelId: privateChannel, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: privateChannel, agentId: agent)
    return (accounts, serverId, ownerId, outsiderId, agent, privateChannel)
}

@Test func privateCarrierActionCardsAreCloakedFromNonMembers() async throws {
    let f = makePrivateCarrierFixture()
    let cardId = f.accounts.addActionCardForTesting(
        serverId: f.serverId, agentId: f.agentId, carrierChannelId: f.privateChannel,
        actionType: "channel:create", state: "prepared"
    )
    let outsiderToken = f.accounts.mintAccessTokenForTesting(userId: f.outsiderId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(outsiderToken)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = f.serverId
            let execute = try await client.send(.post, headers: headers, to: URI(string: "/api/actions/\(cardId)/execute")) { request in
                request.body = .init(string: "{\"expectedState\":\"prepared\"}")
            }
            #expect(execute.status == .notFound)
            let mark = try await client.send(.post, headers: headers, to: URI(string: "/api/actions/\(cardId)/mark-executed")) { request in
                request.body = .init(string: "{\"result\":{\"kind\":\"channel\",\"id\":\"x\",\"name\":\"fake\"}}")
            }
            #expect(mark.status == .notFound)
            #expect(app_isPrepared(f.accounts, cardId))
        }
    }
}

private func app_isPrepared(_ accounts: EmailLoginDirectory, _ cardId: String) -> Bool {
    accounts.actionCardStateForTesting(messageId: cardId) == "prepared"
}

@Test func publicChannelReadAccessDoesNotGrantActionCardWriteAuthority() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001088011"
    let ownerId = "11111111-1111-4111-8111-000001088011"
    let readerId = "11111111-1111-4111-8111-000001088012"
    accounts.addAccount(id: ownerId, email: "public-card-owner@private.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: readerId, email: "public-card-reader@private.test", password: "password123")
    accounts.markEmailVerified(userId: readerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "public-card", name: "Public Card", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: readerId, role: "member")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "public-card-agent", creatorUserId: ownerId, runtime: "claude")
    let carrier = accounts.oauth.createChannel(serverId: serverId, name: "public-card-carrier", creatorUserId: ownerId)
    accounts.oauth.addChannelAgent(channelId: carrier, agentId: agent)
    let cardId = accounts.addActionCardForTesting(
        serverId: serverId, agentId: agent, carrierChannelId: carrier, actionType: "channel:create", state: "prepared"
    )
    let readerToken = accounts.mintAccessTokenForTesting(userId: readerId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(readerToken)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let execute = try await client.send(.post, headers: headers, to: URI(string: "/api/actions/\(cardId)/execute")) { request in
                request.body = .init(string: "{\"expectedState\":\"prepared\"}")
            }
            #expect(execute.status == .forbidden)
            let mark = try await client.send(.post, headers: headers, to: URI(string: "/api/actions/\(cardId)/mark-executed")) { request in
                request.body = .init(string: "{\"result\":{\"kind\":\"channel\",\"id\":\"x\",\"name\":\"fake\"}}")
            }
            #expect(mark.status == .forbidden)
            #expect(accounts.actionCardStateForTesting(messageId: cardId) == "prepared")
        }
    }
}

@Test func migrationExportActionCardRouteIsNotSupported() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-000001088021"
    accounts.addAccount(id: userId, email: "migration-card@private.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: "33333333-3333-4333-8333-000001088021", slug: "botiverse", name: "Botiverse", ownerId: userId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = "33333333-3333-4333-8333-000001088021"
            let response = try await client.send(.post, headers: headers, to: URI(string: "/api/actions/migration-export")) { request in
                request.body = .init(string: "{\"agentId\":\"x\",\"targetComputer\":\"y\",\"mode\":\"cooperative\"}")
            }
            #expect(response.status == .gone)
            #expect(response.body.string?.contains("migration_action_card_not_supported") == true)
        }
    }
}

@Test func actionCardTargetAccessAndInitialMemberScopeAreEnforced() async throws {
    let accounts = EmailLoginDirectory()
    let serverA = "33333333-3333-4333-8333-000001088031"
    let serverB = "33333333-3333-4333-8333-000001088032"
    let ownerA = "11111111-1111-4111-8111-000001088031"
    let ownerB = "11111111-1111-4111-8111-000001088032"
    accounts.addAccount(id: ownerA, email: "scope-a@private.test", password: "password123")
    accounts.markEmailVerified(userId: ownerA)
    accounts.addAccount(id: ownerB, email: "scope-b@private.test", password: "password123")
    accounts.markEmailVerified(userId: ownerB)
    accounts.oauth.addOwnedServer(id: serverA, slug: "scope-a", name: "Scope A", ownerId: ownerA)
    accounts.oauth.addOwnedServer(id: serverB, slug: "scope-b", name: "Scope B", ownerId: ownerB)
    let agentA = accounts.oauth.createAgent(serverId: serverA, name: "scope-agent-a", creatorUserId: ownerA, runtime: "claude")
    let agentB = accounts.oauth.createAgent(serverId: serverB, name: "scope-agent-b", creatorUserId: ownerB, runtime: "claude")
    let privateCarrier = accounts.oauth.createChannel(serverId: serverA, name: "scope-private-carrier", creatorUserId: ownerA, type: "private")
    accounts.oauth.addChannelHuman(channelId: privateCarrier, userId: ownerA)
    accounts.oauth.addChannelAgent(channelId: privateCarrier, agentId: agentA)
    let inaccessible = accounts.oauth.createChannel(serverId: serverA, name: "scope-private-target", creatorUserId: ownerA, type: "private")
    accounts.oauth.addChannelHuman(channelId: inaccessible, userId: ownerA)
    let agentKey = accounts.mintAgentCredential(agentId: agentA, scopes: ["send", "read"], name: "scope-key")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(agentKey)"
            headers[.contentType] = "application/json"

            func prepare(_ targetId: String, _ initial: String) async throws -> HTTPResponse.Status {
                let payload = "{\"target\":\"\(targetId)\",\"action\":{\"type\":\"channel:create\",\"name\":\"scope-created\",\"visibility\":\"private\"\(initial)}}"
                let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/prepare-action")) { request in
                    request.body = .init(string: payload)
                }
                return response.status
            }

            let inaccessibleStatus = try await prepare(inaccessible, "")
            #expect(inaccessibleStatus == .forbidden)
            let foreignAgentStatus = try await prepare(privateCarrier, ",\"initialAgents\":[\"\(agentB)\"]")
            #expect(foreignAgentStatus == .badRequest)
            let foreignHumanStatus = try await prepare(privateCarrier, ",\"initialHumans\":[\"\(ownerB)\"]")
            #expect(foreignHumanStatus == .badRequest)
            let safeStatus = try await prepare(privateCarrier, ",\"initialAgents\":[\"\(agentA)\"],\"initialHumans\":[\"\(ownerA)\"]")
            #expect(safeStatus == .created)
        }
    }
}
