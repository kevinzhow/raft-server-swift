import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Byte-exact HTTP locks for the reaction/third-party delivery surface: status,
/// body text and the header policy the legacy replies published.

private func exactBodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private func expectExactJSONHeaderPolicy(
    _ response: ClientResponse, sourceLocation: SourceLocation = #_sourceLocation
) {
    // Complete app.ts:290 default; reactions and delivery ACKs do not override it.
    #expect(response.headers[HTTPField.Name("Cache-Control")!] == "private, no-store", sourceLocation: sourceLocation)
    #expect(response.headers[.contentType] == "application/json; charset=utf-8", sourceLocation: sourceLocation)
    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow", sourceLocation: sourceLocation)
    #expect(response.headers[.contentLength] == String(exactBodyText(response).utf8.count), sourceLocation: sourceLocation)
}

private func exactPost(
    _ client: any Client,
    _ path: String,
    body: String,
    authorization: String? = nil,
    serverId: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let authorization { headers[.authorization] = authorization }
    if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private struct ExactReactionFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let messageId: String
    let ownerId: String
    let ownerName: String
    let email: String
}

private func makeExactReactionFixture() -> ExactReactionFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-333333333920"
    let ownerId = "11111111-1111-4111-8111-111111111920"
    let channelId = "22222222-2222-4222-8222-222222222920"
    let ownerName = "byte-owner-920"
    let email = "byte-owner-920@slock.test"
    accounts.addAccount(id: ownerId, email: email, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.setAccountProfileForTesting(id: ownerId, name: ownerName)
    accounts.oauth.addOwnedServer(id: serverId, slug: "byte-server-920", name: "Byte", ownerId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "byte-room")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let messageId = accounts.addChannelMessageForTesting(
        channelId: channelId,
        content: "byte exact reaction",
        senderId: ownerId
    )
    return ExactReactionFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channelId,
        messageId: messageId,
        ownerId: ownerId,
        ownerName: ownerName,
        email: email
    )
}

private func exactLogin(_ client: any Client, email: String) async throws -> String {
    let response = try await exactPost(
        client,
        "/api/auth/login",
        body: "{\"email\":\"\(email)\",\"password\":\"password123\"}"
    )
    return ((try JSONSerialization.jsonObject(with: Data(exactBodyText(response).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
}

@Test func reactionPostPublishesTheExactLegacyAckAndHeaders() async throws {
    let fixture = makeExactReactionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await exactLogin(client, email: fixture.email)
            let path = "/api/messages/\(fixture.messageId)/reactions"
            let response = try await exactPost(
                client,
                path,
                body: "{\"emoji\":\"👍\"}",
                authorization: "Bearer \(token)",
                serverId: fixture.serverId
            )
            #expect(response.status == .ok)
            expectExactJSONHeaderPolicy(response)
            #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(response.headers[.contentType] == "application/json; charset=utf-8")
            #expect(exactBodyText(response) == """
            {"reactions":[{"emoji":"👍","count":1,"reactorIds":["\(fixture.ownerId)"],"reactorNames":["\(fixture.ownerName)"]}],"commentRef":null,"attachments":[],"reactionViewer":{"serverId":"\(fixture.serverId)","messageId":"\(fixture.messageId)","viewerVersion":1,"reactedEmojis":["👍"]}}
            """)
        }
    }
}

@Test func reactionAuthAndBodyRefusalsKeepTheirBytesAndHeaderPolicy() async throws {
    let fixture = makeExactReactionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let path = "/api/messages/\(fixture.messageId)/reactions"
            let unauthenticated = try await exactPost(
                client,
                path,
                body: "{\"emoji\":\"👍\"}",
                serverId: fixture.serverId
            )
            #expect(unauthenticated.status == .unauthorized)
            expectExactJSONHeaderPolicy(unauthenticated)
            #expect(unauthenticated.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
            #expect(exactBodyText(unauthenticated) == """
            {"error":"Missing or invalid Authorization header","code":"auth_required"}
            """)

            let token = try await exactLogin(client, email: fixture.email)
            let noEmoji = try await exactPost(
                client,
                path,
                body: "{\"emoji\":\"not emoji\"}",
                authorization: "Bearer \(token)",
                serverId: fixture.serverId
            )
            #expect(noEmoji.status == .badRequest)
            expectExactJSONHeaderPolicy(noEmoji)
            #expect(exactBodyText(noEmoji) == #"{"error":"A valid emoji is required"}"#)

            let missing = try await exactPost(
                client,
                "/api/messages/99999999-9999-4999-8999-999999999999/reactions",
                body: "{\"emoji\":\"👍\"}",
                authorization: "Bearer \(token)",
                serverId: fixture.serverId
            )
            #expect(missing.status == .notFound)
            expectExactJSONHeaderPolicy(missing)
            #expect(exactBodyText(missing) == #"{"error":"Message not found"}"#)
        }
    }
}

@Test func reactionActorsPagePublishesTheExactLegacyBody() async throws {
    let fixture = makeExactReactionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await exactLogin(client, email: fixture.email)
            _ = try await exactPost(
                client,
                "/api/messages/\(fixture.messageId)/reactions",
                body: "{\"emoji\":\"👀\"}",
                authorization: "Bearer \(token)",
                serverId: fixture.serverId
            )
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let page = try await client.send(
                .get,
                headers: headers,
                to: URI(string: "/api/messages/\(fixture.messageId)/reactions/actors?emoji=%F0%9F%91%80")
            )
            #expect(page.status == .ok)
            expectExactJSONHeaderPolicy(page)
            #expect(exactBodyText(page) == """
            {"discussion":{"root":{"kind":"message","serverId":"\(fixture.serverId)","id":"\(fixture.messageId)"},"relation":{"kind":"reactionActors","emoji":"👀"},"parentScope":{"serverId":"\(fixture.serverId)","scopeKind":"channel","scopeId":"\(fixture.channelId)"}},"discussionVersion":1,"actors":[{"actorRef":{"kind":"user","id":"\(fixture.ownerId)"}}],"nextCursor":null}
            """)
        }
    }
}

@Test func thirdPartyDeliveredKeepsItsExactShapeAndRefusals() async throws {
    let fixture = makeExactReactionFixture()
    let agent = fixture.accounts.oauth.createAgent(
        serverId: fixture.serverId,
        name: "byte-delivery-agent-920",
        runtime: "codex"
    )
    let key = fixture.accounts.mintAgentCredential(
        agentId: agent,
        scopes: ["read"],
        name: "byte-delivery-920"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let path = "/internal/agent-api/third-party-events/delivered"
            let delivered = try await exactPost(
                client,
                path,
                body: "{\"eventIds\":[\"00000000-0000-4000-8000-000000000920\"]}",
                authorization: "Bearer \(key)"
            )
            #expect(delivered.status == .ok)
            expectExactJSONHeaderPolicy(delivered)
            #expect(exactBodyText(delivered) == #"{"ok":true,"delivered":0}"#)

            let empty = try await exactPost(
                client,
                path,
                body: "{\"eventIds\":[]}",
                authorization: "Bearer \(key)"
            )
            #expect(empty.status == .badRequest)
            expectExactJSONHeaderPolicy(empty)
            #expect(exactBodyText(empty) == """
            {"error":"eventIds must be a non-empty array","code":"event_ids_invalid"}
            """)

            let malformed = try await exactPost(
                client,
                path,
                body: "{\"eventIds\":[\"nope\"]}",
                authorization: "Bearer \(key)"
            )
            #expect(malformed.status == .badRequest)
            expectExactJSONHeaderPolicy(malformed)
            #expect(exactBodyText(malformed) == """
            {"error":"eventIds must contain third-party event ids","code":"event_ids_invalid"}
            """)

            let unauthenticated = try await exactPost(
                client,
                path,
                body: "{\"eventIds\":[\"00000000-0000-4000-8000-000000000920\"]}"
            )
            #expect(unauthenticated.status == .unauthorized)
            expectExactJSONHeaderPolicy(unauthenticated)
            #expect(exactBodyText(unauthenticated) == """
            {"error":"Missing agent credential"}
            """)
        }
    }
}
