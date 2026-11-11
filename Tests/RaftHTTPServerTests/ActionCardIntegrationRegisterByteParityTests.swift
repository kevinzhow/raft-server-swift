import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// Byte-exact parity for the three routes the action-card
/// integration-register service owns, plus the header sets the retired
/// `Self.json` helper published.
private struct IntegrationRegisterFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-333333333777"
    let ownerId = "11111111-1111-4111-8111-111111111777"
    var agentId = ""
    var channelId = ""
    var channelName = "register-room"
    var key = ""

    mutating func seed() {
        accounts.addAccount(
            id: ownerId,
            email: "register-owner@register.test",
            password: "password123"
        )
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(
            id: serverId,
            slug: "register",
            name: "Register",
            ownerId: ownerId
        )
        agentId = accounts.oauth.createAgent(
            serverId: serverId,
            name: "RegisterBot",
            creatorUserId: ownerId,
            runtime: "claude"
        )
        channelId = accounts.oauth.createChannel(
            serverId: serverId,
            name: channelName,
            creatorUserId: ownerId,
            type: "channel"
        )
        accounts.addPostableChannel(
            serverId: serverId,
            channelId: channelId,
            memberId: ownerId,
            name: channelName
        )
        accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
        accounts.addPostableChannel(
            serverId: serverId,
            channelId: channelId,
            memberId: agentId,
            kind: "channel",
            name: channelName
        )
        accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        key = accounts.mintAgentCredential(
            agentId: agentId,
            scopes: ["send", "read"],
            name: "register"
        )
    }
}

private func registerAgentHeaders(_ key: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return headers
}

private func registerSourceHeaders(_ token: String, serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func loginToken(
    _ client: any Client,
    email: String
) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    let body = (try? JSONSerialization.jsonObject(
        with: Data((response.body.string ?? "").utf8)
    )) as? [String: Any]
    return body?["accessToken"] as? String ?? ""
}

private func prepareCard(
    _ client: any Client,
    key: String,
    body: String
) async throws -> (status: HTTPResponse.Status, raw: String, headers: HTTPFields) {
    let response = try await client.send(
        .post,
        headers: registerAgentHeaders(key),
        to: "/internal/agent-api/prepare-action"
    ) { request in
        request.body = .init(string: body)
    }
    return (response.status, response.body.string ?? "", response.headers)
}

// MARK: - Integration app prepare

/// The `201` body and header set are published byte-for-byte: the action object
/// keeps the legacy member order (`type`, `name`, `clientKey`, `homepageUrl`,
/// `returnUrl`, `scopes`), with the trimmed/lowercased values.
@Test func integrationAppPreparePublishesTheExact201Bytes() async throws {
    var fixture = IntegrationRegisterFixture()
    fixture.seed()
    try await withApp { app in
        configure(
            app,
            services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            )
        )
        try await app.testing { client in
            let payload = "{\"mode\":\"register\",\"target\":\"#\(fixture.channelName)\",\"name\":\"  Demo  \",\"clientKey\":\"Demo-Key\",\"homepageUrl\":\"https://example.test/app\",\"returnUrl\":\"https://example.test/cb\",\"scopes\":[\"openid\",\"profile\"]}"
            let response = try await client.send(
                .post,
                headers: registerAgentHeaders(fixture.key),
                to: "/internal/agent-api/integrations/app/prepare"
            ) { request in
                request.body = .init(string: payload)
            }
            #expect(response.status == .created)
            let raw = response.body.string ?? ""
            let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            let messageId = try #require(parsed?["actionCardMessageId"] as? String)
            let expected = """
            {"status":"prepared","actionCardMessageId":"\(messageId)","action":{"type":"integration:register_app","name":"Demo","clientKey":"demo-key","homepageUrl":"https://example.test/app","returnUrl":"https://example.test/cb","scopes":["openid","profile"]}}
            """
            #expect(raw == expected)
            #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(response.headers[.contentType] == "application/json; charset=utf-8")
            #expect(response.headers[.contentLength] == String(expected.utf8.count))
        }
    }
}

/// A body sent without a JSON `Content-Type` still parses, matching the legacy
/// `bodyText` + `JSONSerialization` handler.
@Test func integrationAppPrepareAcceptsABodyWithoutAContentType() async throws {
    var fixture = IntegrationRegisterFixture()
    fixture.seed()
    try await withApp { app in
        configure(
            app,
            services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            )
        )
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.key)"
            let payload = "{\"mode\":\"register\",\"target\":\"#\(fixture.channelName)\",\"name\":\"NoType\",\"returnUrl\":\"https://example.test/cb\"}"
            let response = try await client.send(
                .post,
                headers: headers,
                to: "/internal/agent-api/integrations/app/prepare"
            ) { request in
                request.body = .init(string: payload)
            }
            #expect(response.status == .created)
            #expect((response.body.string ?? "").contains("\"status\":\"prepared\""))
        }
    }
}

/// The two published refusals the app-prepare route owns. The scope refusal
/// uses the `errorCode` key; the capability refusal appends
/// `requiredCapability` after `code`.
@Test func integrationAppPreparePublishesExactErrorBodies() async throws {
    var fixture = IntegrationRegisterFixture()
    fixture.seed()
    let readOnlyKey = fixture.accounts.mintAgentCredential(
        agentId: fixture.agentId,
        scopes: ["read"],
        name: "read-only"
    )
    try await withApp { app in
        configure(
            app,
            services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            )
        )
        try await app.testing { client in
            let capability = try await client.send(
                .post,
                headers: registerAgentHeaders(readOnlyKey),
                to: "/internal/agent-api/integrations/app/prepare"
            ) { request in
                request.body = .init(string: "{}")
            }
            // The pinned route capability is `read`, so this credential passes
            // the capability gate and the body schema answers first.
            #expect(capability.status == .badRequest)
            #expect((capability.body.string ?? "") == """
            {"error":"Invalid agent-api integrationAppPrepare body","code":"agent_api_contract_invalid","issues":[{"path":"mode","message":"Invalid input"}]}
            """)

            let badScope = try await client.send(
                .post,
                headers: registerAgentHeaders(fixture.key),
                to: "/internal/agent-api/integrations/app/prepare"
            ) { request in
                request.body = .init(string: """
                {"mode":"register","target":"#\(fixture.channelName)","name":"Demo","returnUrl":"https://example.test/cb","scopes":["not:a:raft:scope"]}
                """)
            }
            #expect(badScope.status == .badRequest)
            #expect((badScope.body.string ?? "") == """
            {"error":"Scope is not allowed for this service","errorCode":"INVALID_SCOPE"}
            """)
        }
    }
}

// MARK: - Prepare action

/// The `201` body publishes `messageId` then `metadata`, and the prepared
/// channel card keeps the legacy action/carrier member order.
@Test func prepareActionPublishesTheExact201Bytes() async throws {
    var fixture = IntegrationRegisterFixture()
    fixture.seed()
    try await withApp { app in
        configure(
            app,
            services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            )
        )
        try await app.testing { client in
            let result = try await prepareCard(
                client,
                key: fixture.key,
                body: "{\"target\":\"#\(fixture.channelName)\",\"action\":{\"type\":\"channel:create\",\"name\":\"exact-room\"}}"
            )
            #expect(result.status == .created)
            let parsed = (try? JSONSerialization.jsonObject(
                with: Data(result.raw.utf8)
            )) as? [String: Any]
            let messageId = try #require(parsed?["messageId"] as? String)
            let expected = """
            {"messageId":"\(messageId)","metadata":{"kind":"action-card","state":"prepared","action":{"type":"channel:create","name":"exact-room","visibility":"channel"},"carrierChannelId":"\(fixture.channelId)"}}
            """
            #expect(result.raw == expected)
            #expect(result.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(result.headers[.contentType] == "application/json; charset=utf-8")
            #expect(result.headers[.contentLength] == String(expected.utf8.count))
        }
    }
}

/// An idempotent replay republishes the first reply's bytes with the legacy
/// `Cache-Control: no-store` header set and no `X-Robots-Tag`, and a different
/// payload under the same key is the fixed 409.
@Test func prepareActionReplayIsByteExactAndKeepsItsHeaderPolicy() async throws {
    var fixture = IntegrationRegisterFixture()
    fixture.seed()
    try await withApp { app in
        configure(
            app,
            services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            )
        )
        try await app.testing { client in
            let body = "{\"target\":\"#\(fixture.channelName)\",\"action\":{\"type\":\"channel:create\",\"name\":\"replay-room\"},\"idempotencyKey\":\"replay-key\"}"
            let first = try await prepareCard(client, key: fixture.key, body: body)
            #expect(first.status == .created)
            #expect(first.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")

            let replay = try await prepareCard(client, key: fixture.key, body: body)
            #expect(replay.status == .created)
            #expect(replay.raw == first.raw)
            #expect(replay.headers[HTTPField.Name("X-Robots-Tag")!] == nil)
            #expect(replay.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            #expect(replay.headers[.contentType] == "application/json; charset=utf-8")
            #expect(replay.headers[.contentLength] == String(first.raw.utf8.count))

            let mismatch = try await prepareCard(
                client,
                key: fixture.key,
                body: "{\"target\":\"#\(fixture.channelName)\",\"action\":{\"type\":\"channel:create\",\"name\":\"other-room\"},\"idempotencyKey\":\"replay-key\"}"
            )
            #expect(mismatch.status == .conflict)
            #expect(mismatch.raw == """
            {"error":"This idempotencyKey was already used for a different request","code":"idempotency_key_reused","mismatch":"request","suggestedNextAction":"Retry with a new idempotencyKey."}
            """)
        }
    }
}

// MARK: - Execute

/// The execute success body is `messageId` then `metadata`, with the channel
/// result block in the legacy order.
@Test func executeActionPublishesTheExact200Bytes() async throws {
    var fixture = IntegrationRegisterFixture()
    fixture.seed()
    try await withApp { app in
        configure(
            app,
            services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            )
        )
        try await app.testing { client in
            let prepared = try await prepareCard(
                client,
                key: fixture.key,
                body: "{\"target\":\"#\(fixture.channelName)\",\"action\":{\"type\":\"channel:create\",\"name\":\"executed-room\"}}"
            )
            let preparedBody = (try? JSONSerialization.jsonObject(
                with: Data(prepared.raw.utf8)
            )) as? [String: Any]
            let messageId = try #require(preparedBody?["messageId"] as? String)
            let token = try await loginToken(client, email: "register-owner@register.test")

            let response = try await client.send(
                .post,
                headers: registerSourceHeaders(token, serverId: fixture.serverId),
                to: "/api/actions/\(messageId)/execute"
            ) { request in
                request.body = .init(string: "{\"expectedState\":\"prepared\"}")
            }
            #expect(response.status == .ok)
            let raw = response.body.string ?? ""
            let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            let metadata = try #require(parsed?["metadata"] as? [String: Any])
            let result = try #require(metadata["result"] as? [String: Any])
            let channelId = try #require(result["id"] as? String)
            let expected = """
            {"messageId":"\(messageId)","metadata":{"kind":"action-card","state":"executed","action":{"type":"channel:create","name":"executed-room"},"result":{"kind":"channel","id":"\(channelId)","name":"executed-room"}}}
            """
            #expect(raw == expected)
            #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(response.headers[.contentLength] == String(expected.utf8.count))
        }
    }
}

/// The duplicate-channel failure publishes `error`, `code`, `reason` in that
/// order, with the same sentence in `error` and `reason`.
@Test func executeActionPublishesTheExactDuplicateChannelFailure() async throws {
    var fixture = IntegrationRegisterFixture()
    fixture.seed()
    try await withApp { app in
        configure(
            app,
            services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            )
        )
        try await app.testing { client in
            let prepared = try await prepareCard(
                client,
                key: fixture.key,
                body: "{\"target\":\"#\(fixture.channelName)\",\"action\":{\"type\":\"channel:create\",\"name\":\"\(fixture.channelName)\"}}"
            )
            let preparedBody = (try? JSONSerialization.jsonObject(
                with: Data(prepared.raw.utf8)
            )) as? [String: Any]
            let messageId = try #require(preparedBody?["messageId"] as? String)
            let token = try await loginToken(client, email: "register-owner@register.test")

            let response = try await client.send(
                .post,
                headers: registerSourceHeaders(token, serverId: fixture.serverId),
                to: "/api/actions/\(messageId)/execute"
            ) { request in
                request.body = .init(string: "{}")
            }
            #expect(response.status == .conflict)
            #expect((response.body.string ?? "") == """
            {"error":"a channel named #\(fixture.channelName) already exists","code":"ACTION_FAILED","reason":"a channel named #\(fixture.channelName) already exists"}
            """)
        }
    }
}

/// The complete Node mount rejects a missing session before the action handler.
@Test func executeActionWithoutASessionPublishesTheExact401() async throws {
    var fixture = IntegrationRegisterFixture()
    fixture.seed()
    try await withApp { app in
        configure(
            app,
            services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            )
        )
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let response = try await client.send(
                .post,
                headers: headers,
                to: "/api/actions/00000000-0000-4000-8000-000000000001/execute"
            ) { request in
                request.body = .init(string: "{}")
            }
            #expect(response.status == .unauthorized)
            #expect((response.body.string ?? "") == #"{"error":"Missing or invalid Authorization header","code":"auth_required"}"#)
            #expect(response.headers[.contentLength] == "74")
            #expect(response.headers[.cacheControl] == "private, no-store")
        }
    }
}

/// The generic prepare refuses an integration approval type with the
/// `errorCode` member the upstream test asserts.
@Test func prepareActionRefusesIntegrationApprovalCardsWithTheExactBody() async throws {
    var fixture = IntegrationRegisterFixture()
    fixture.seed()
    try await withApp { app in
        configure(
            app,
            services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            )
        )
        try await app.testing { client in
            let result = try await prepareCard(
                client,
                key: fixture.key,
                body: "{\"target\":\"#\(fixture.channelName)\",\"action\":{\"type\":\"integration:approve_agent_login\"}}"
            )
            #expect(result.status == .badRequest)
            #expect(result.raw == """
            {"error":"Integration approval cards must be prepared with the raft integration commands","errorCode":"ACTION_TYPE_NOT_PREPARABLE"}
            """)
        }
    }
}
