import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct RandomIdFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let ownerEmail: String
    let targetId: String
    let targetName: String
}

private func makeRandomIdFixture(suffix: String) -> RandomIdFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 700_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 600_000 + number)
    let targetId = String(format: "11111111-1111-4111-8111-%012d", 610_000 + number)
    let ownerEmail = "messages-random-id-\(suffix)@slock.test"
    let targetName = "random-id-target-\(suffix)"
    for (id, email) in [(ownerId, ownerEmail), (targetId, "\(targetName)@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.setAccountProfileForTesting(id: targetId, name: targetName)
    accounts.oauth.addOwnedServer(id: serverId, slug: "messages-random-id-\(suffix)", name: "Messages Random ID", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: targetId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "messages-random-id-channel-\(suffix)", creatorUserId: ownerId)
    for member in [ownerId, targetId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: member, name: "messages-random-id-channel-\(suffix)")
    }
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channel, userId: targetId)
    return RandomIdFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channel,
        ownerEmail: ownerEmail,
        targetId: targetId,
        targetName: targetName
    )
}

private func randomIdLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func randomIdSend(
    _ client: any Client,
    token: String,
    serverId: String,
    body: String
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return try await client.send(.post, headers: headers, to: "/api/messages") { request in
        request.body = .init(string: body)
    }
}

private func randomIdObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func randomIdReplayReturnsTheOriginalFinalizedRow() async throws {
    let fixture = makeRandomIdFixture(suffix: "901")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await randomIdLogin(client, email: fixture.ownerEmail)
            let randomId = "msg-retry-901"
            let first = try await randomIdSend(
                client,
                token: token,
                serverId: fixture.serverId,
                body: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"same payload after lost response @\(fixture.targetName)\",\"randomId\":\"\(randomId)\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(fixture.targetId)\",\"name\":\"\(fixture.targetName)\"}]}"
            )
            #expect(first.status == .ok)
            let firstBody = try randomIdObject(first)
            #expect(firstBody["randomId"] as? String == randomId)
            #expect(firstBody["mentions"] as? NSArray == [
                ["type": "user", "id": fixture.targetId, "name": fixture.targetName] as NSDictionary
            ] as NSArray)
            let firstId = try #require(firstBody["id"] as? String)

            let second = try await randomIdSend(
                client,
                token: token,
                serverId: fixture.serverId,
                body: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"retry body should not overwrite original\",\"randomId\":\"\(randomId)\",\"mentions\":[]}"
            )
            #expect(second.status == .ok)
            #expect(try randomIdObject(second) as NSDictionary == firstBody as NSDictionary)
            #expect(fixture.accounts.humanMessageIds(channelId: fixture.channelId) == [firstId])
        }
    }
}

@Test func randomIdSentinelAndConcurrentReplaysKeepOneRow() async throws {
    let fixture = makeRandomIdFixture(suffix: "902")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await randomIdLogin(client, email: fixture.ownerEmail)

            let sentinel = try await randomIdSend(
                client,
                token: token,
                serverId: fixture.serverId,
                body: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"literal sentinel random id\",\"randomId\":\"invalid\"}"
            )
            #expect(sentinel.status == .ok)
            #expect(try randomIdObject(sentinel)["randomId"] as? String == "invalid")

            let randomId = "msg-race-902"
            let firstBody = "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"first controlled winner candidate @\(fixture.targetName)\",\"randomId\":\"\(randomId)\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(fixture.targetId)\",\"name\":\"\(fixture.targetName)\"}]}"
            let secondBody = "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"second controlled winner candidate @\(fixture.targetName)\",\"randomId\":\"\(randomId)\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(fixture.targetId)\",\"name\":\"\(fixture.targetName)\"}]}"
            async let winner = randomIdSend(client, token: token, serverId: fixture.serverId, body: firstBody)
            async let loser = randomIdSend(client, token: token, serverId: fixture.serverId, body: secondBody)
            let (firstResponse, secondResponse) = try await (winner, loser)
            #expect(firstResponse.status == .ok)
            #expect(secondResponse.status == .ok)
            let first = try randomIdObject(firstResponse)
            let second = try randomIdObject(secondResponse)
            #expect(first as NSDictionary == second as NSDictionary)
            #expect(first["randomId"] as? String == randomId)
            #expect(first["content"] as? String == "first controlled winner candidate @\(fixture.targetName)"
                || first["content"] as? String == "second controlled winner candidate @\(fixture.targetName)")
            #expect(first["mentions"] as? NSArray == [
                ["type": "user", "id": fixture.targetId, "name": fixture.targetName] as NSDictionary
            ] as NSArray)
            let raceId = try #require(first["id"] as? String)
            #expect(fixture.accounts.humanMessageIds(channelId: fixture.channelId).filter { $0 == raceId }.count == 1)
        }
    }
}
