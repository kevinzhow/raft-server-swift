import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct BodyBoundaryFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let ownerEmail: String
    let token: String
}

private func makeBodyBoundaryFixture(suffix: String) async throws -> (BodyBoundaryFixture, EmailLoginDirectory) {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 930_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 930_000 + number)
    let ownerEmail = "messages-body-boundary-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "messages-body-boundary-\(suffix)", name: "Messages Body Boundary", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "messages-body-boundary-channel-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "messages-body-boundary-channel-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    return (
        BodyBoundaryFixture(
            accounts: accounts,
            serverId: serverId,
            channelId: channel,
            ownerEmail: ownerEmail,
            token: ""
        ),
        accounts
    )
}

private func bodyBoundaryLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func bodyBoundarySend(
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

@Test func messageCreateRejectsInvalidFieldsBeforeWrites() async throws {
    let (fixture, accounts) = try await makeBodyBoundaryFixture(suffix: "961")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await bodyBoundaryLogin(client, email: fixture.ownerEmail)
            let before = accounts.humanMessageCount
            let cases = [
                "{\"channelId\":{\"id\":\"\(fixture.channelId)\"},\"content\":\"object channelId must not reach resolve\"}",
                "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"bad attachment element must not create message\",\"attachmentIds\":[\"not-a-uuid\"]}",
                "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"string false must not silently create task\",\"asTask\":\"false\"}",
            ]
            for body in cases {
                let response = try await bodyBoundarySend(client, token: token, serverId: fixture.serverId, body: body)
                #expect(response.status == .badRequest)
                let object = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
                #expect(object?["error"] is String)
                #expect(accounts.humanMessageCount == before)
            }
        }
    }
}

@Test func messageCreateRejectsUninstalledAndGatedAppReferences() async throws {
    let (fixture, accounts) = try await makeBodyBoundaryFixture(suffix: "962")
    accounts.enableComposerResourceReferences(serverId: fixture.serverId, enabled: true)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await bodyBoundaryLogin(client, email: fixture.ownerEmail)
            let enabledContent = "run [@Missing](<app:custom.missing>)"
            let enabled = try await bodyBoundarySend(
                client,
                token: token,
                serverId: fixture.serverId,
                body: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"\(enabledContent)\"}"
            )
            #expect(enabled.status == .badRequest)
            #expect(try JSONSerialization.jsonObject(with: Data((enabled.body.string ?? "").utf8)) as? NSDictionary == [
                "error": "App reference is not installed in this server",
            ] as NSDictionary)
            #expect(accounts.humanMessageCount == 0)

            accounts.enableComposerResourceReferences(serverId: fixture.serverId, enabled: false)
            let gatedContent = "see [@Reminder](<app:system.reminder>)"
            let gated = try await bodyBoundarySend(
                client,
                token: token,
                serverId: fixture.serverId,
                body: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"\(gatedContent)\"}"
            )
            #expect(gated.status == .badRequest)
            #expect(try JSONSerialization.jsonObject(with: Data((gated.body.string ?? "").utf8)) as? NSDictionary == [
                "error": "Computer and App references are not enabled in this server",
            ] as NSDictionary)
            #expect(accounts.humanMessageCount == 0)
        }
    }
}

@Test func messageCreateRejectsAChannelOutsideTheActiveServer() async throws {
    let (fixture, accounts) = try await makeBodyBoundaryFixture(suffix: "963")
    let otherServerId = "33333333-3333-4333-8333-000000931963"
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "messages-other-963", name: "Other", ownerId: fixture.accounts === accounts ? "11111111-1111-4111-8111-000000930963" : "unused")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await bodyBoundaryLogin(client, email: fixture.ownerEmail)
            let response = try await bodyBoundarySend(
                client,
                token: token,
                serverId: otherServerId,
                body: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"must not cross servers\"}"
            )
            #expect(response.status == .notFound)
            #expect(accounts.humanMessageCount == 0)
        }
    }
}
