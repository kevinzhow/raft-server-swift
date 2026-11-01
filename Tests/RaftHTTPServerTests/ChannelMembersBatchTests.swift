import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct MembersBatchFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let ownerId: String
    let ownerEmail: String
    let humanA: String
    let humanB: String
    let agentA: String
    let agentB: String
    let agentAName: String
    let agentBName: String
}

private func makeMembersBatchFixture(suffix: String) -> MembersBatchFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 920_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 920_000 + number)
    let humanA = String(format: "11111111-1111-4111-8111-%012d", 921_000 + number)
    let humanB = String(format: "11111111-1111-4111-8111-%012d", 922_000 + number)
    let ownerEmail = "member-batch-owner-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: humanA, email: "member-batch-a-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: humanA)
    accounts.addAccount(id: humanB, email: "member-batch-b-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: humanB)
    accounts.setAccountProfileForTesting(id: humanA, name: "member-batch-human-a-\(suffix)")
    accounts.setAccountProfileForTesting(id: humanB, name: "member-batch-human-b-\(suffix)")
    accounts.oauth.addOwnedServer(id: serverId, slug: "member-batch-\(suffix)", name: "Member Batch", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: humanA, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: humanB, role: "member")
    let agentAName = "member-batch-agent-a-\(suffix)"
    let agentBName = "member-batch-agent-b-\(suffix)"
    let agentA = accounts.oauth.createAgent(serverId: serverId, name: agentAName, runtime: "codex")
    let agentB = accounts.oauth.createAgent(serverId: serverId, name: agentBName, runtime: "codex")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "batch-target-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "batch-target-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    return MembersBatchFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channel,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        humanA: humanA,
        humanB: humanB,
        agentA: agentA,
        agentB: agentB,
        agentAName: agentAName,
        agentBName: agentBName
    )
}

private func batchLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func batchObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func channelMembersBatchAddsMixedMembersAndIsIdempotent() async throws {
    let fixture = makeMembersBatchFixture(suffix: "951")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await batchLogin(client, email: fixture.ownerEmail)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            func batch(_ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/api/channels/\(fixture.channelId)/members/batch") { request in
                    request.body = .init(string: body)
                }
            }

            let first = try await batch("{\"userIds\":[\"\(fixture.humanA)\",\"\(fixture.humanB)\",\"\(fixture.humanA)\"],\"agentIds\":[\"\(fixture.agentA)\",\"\(fixture.agentB)\",\"\(fixture.agentA)\"]}")
            #expect(first.status == .ok)
            #expect(try batchObject(first) as NSDictionary == [
                "ok": true,
                "added": [
                    "userIds": [fixture.humanA, fixture.humanB],
                    "agentIds": [fixture.agentA, fixture.agentB],
                ],
                "alreadyMembers": ["userIds": [], "agentIds": []],
            ] as NSDictionary)
            #expect(fixture.accounts.oauth.channelHumanIds(channelId: fixture.channelId).contains(fixture.humanA))
            #expect(fixture.accounts.oauth.channelHumanIds(channelId: fixture.channelId).contains(fixture.humanB))
            #expect(fixture.accounts.oauth.channelAgentIds(channelId: fixture.channelId).contains(fixture.agentA))
            #expect(fixture.accounts.oauth.channelAgentIds(channelId: fixture.channelId).contains(fixture.agentB))

            let notices = fixture.accounts.systemMessageContents(channelId: fixture.channelId).sorted()
            #expect(notices == [
                "@\(fixture.agentAName) was added to this channel.",
                "@\(fixture.agentBName) was added to this channel.",
                "@member-batch-human-a-951 was added to this channel.",
                "@member-batch-human-b-951 was added to this channel.",
            ].sorted())

            let retry = try await batch("{\"userIds\":[\"\(fixture.humanA)\",\"\(fixture.humanB)\"],\"agentIds\":[\"\(fixture.agentA)\",\"\(fixture.agentB)\"]}")
            #expect(retry.status == .ok)
            #expect(try batchObject(retry) as NSDictionary == [
                "ok": true,
                "added": ["userIds": [], "agentIds": []],
                "alreadyMembers": [
                    "userIds": [fixture.humanA, fixture.humanB],
                    "agentIds": [fixture.agentA, fixture.agentB],
                ],
            ] as NSDictionary)
            #expect(fixture.accounts.systemMessageContents(channelId: fixture.channelId).count == 4)
        }
    }
}

@Test func channelMembersBatchValidatesTheWholeBatchBeforeWriting() async throws {
    let fixture = makeMembersBatchFixture(suffix: "952")
    let missingUserId = "11111111-1111-4111-8111-111111111999"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await batchLogin(client, email: fixture.ownerEmail)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let response = try await client.send(.post, headers: headers, to: "/api/channels/\(fixture.channelId)/members/batch") { request in
                request.body = .init(string: "{\"userIds\":[\"\(fixture.humanA)\",\"\(missingUserId)\"],\"agentIds\":[]}")
            }
            #expect(response.status == .badRequest)
            #expect(try batchObject(response) as NSDictionary == [
                "error": "One or more users are not members of this server",
                "code": "users_not_in_server",
                "invalidUserIds": [missingUserId],
            ] as NSDictionary)
            #expect(!fixture.accounts.oauth.channelHumanIds(channelId: fixture.channelId).contains(fixture.humanA))
            #expect(fixture.accounts.systemMessageContents(channelId: fixture.channelId).isEmpty)
        }
    }
}
