import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct AgentCreateFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let memberId: String
    let ownerToken: String
    let memberToken: String
}

private func makeAgentCreateFixture(_ suffix: String) -> AgentCreateFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001080\(suffix)"
    let memberId = "11111111-1111-4111-8111-000001081\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001080\(suffix)"
    accounts.addAccount(id: ownerId, email: "create-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "create-member-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "create-\(suffix)", name: "Create \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    return AgentCreateFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        memberId: memberId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId)
    )
}

private func createHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func jsonEquals(_ lhs: [String: Any], _ rhs: [String: Any]) throws -> Bool {
    let left = try JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys])
    let right = try JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys])
    return left == right
}

private func createJSON(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private final class CreateEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(room: String, event: String, payload: String?)] = []
    func append(_ room: String, _ event: String, _ payload: String?) {
        lock.lock(); storage.append((room, event, payload)); lock.unlock()
    }
    var values: [(room: String, event: String, payload: String?)] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

private func createAgentBody(_ client: any Client, token: String, serverId: String, body: String) async throws -> ClientResponse {
    try await client.send(.post, headers: createHeaders(token, serverId), to: "/api/agents") { request in
        request.body = .init(string: body)
    }
}

@Test func agentCreateProjectsStructuredRuntimeConfigAndDerivedEnv() async throws {
    let f = makeAgentCreateFixture("001")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await createAgentBody(client, token: f.ownerToken, serverId: f.serverId, body: """
            {"name":"runtime-config-agent-001","runtimeConfig":{"version":1,"runtime":"claude","provider":{"kind":"custom","apiUrl":"https://gateway.example.test/v1","apiKey":"sk-ant-test"},"model":{"kind":"custom","name":"claude-opus-4-6"},"command":"claude-p","envVars":{"TEAM_FLAG":"enabled"}}}
            """)
            #expect(response.status == .ok)
            let created = try createJSON(response)
            #expect(created["runtime"] as? String == "claude")
            #expect(created["model"] as? String == "claude-opus-4-6")
            #expect(created["envVars"] as? [String: String] == [
                "TEAM_FLAG": "enabled",
                "ANTHROPIC_BASE_URL": "https://gateway.example.test/v1",
                "ANTHROPIC_API_KEY": "sk-ant-test",
                "ANTHROPIC_CUSTOM_MODEL_OPTION": "claude-opus-4-6",
            ])
            let config = try #require(created["runtimeConfig"] as? [String: Any])
            let expected: [String: Any] = [
                "version": 1,
                "runtime": "claude",
                "provider": ["kind": "custom", "apiUrl": "https://gateway.example.test/v1", "apiKey": ""],
                "model": ["kind": "custom", "name": "claude-opus-4-6"],
                "mode": ["kind": "default"],
                "reasoningEffort": NSNull(),
                "command": "claude-p",
                "envVars": ["TEAM_FLAG": "enabled"],
            ]
            #expect(try jsonEquals(config, expected))
            let agentId = try #require(created["id"] as? String)

            let memberList = try await client.get(URI(string: "/api/agents"), headers: createHeaders(f.memberToken, f.serverId))
            let memberRows = (try JSONSerialization.jsonObject(with: Data((memberList.body.string ?? "").utf8))) as? [[String: Any]] ?? []
            let memberRow = try #require(memberRows.first { $0["id"] as? String == agentId })
            #expect(memberRow["envVars"] == nil)
            #expect(memberRow["runtimeConfig"] == nil)
            #expect(memberRow["serverRole"] as? String == "member")

            let profile = try await client.get(URI(string: "/api/agents/\(agentId)"), headers: createHeaders(f.ownerToken, f.serverId))
            #expect(try createJSON(profile)["serverRole"] as? String == "member")
        }
    }
}

@Test func agentPatchKeepsDerivedClaudeEnvAndItsStoredProvider() async throws {
    let f = makeAgentCreateFixture("002")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let created = try await createAgentBody(client, token: f.ownerToken, serverId: f.serverId, body: """
            {"name":"runtime-config-agent-002","runtimeConfig":{"version":1,"runtime":"claude","provider":{"kind":"custom","apiUrl":"https://gateway.example.test/v1","apiKey":"sk-ant-test"},"model":{"kind":"custom","name":"claude-opus-4-6"},"command":"claude-p","envVars":{"TEAM_FLAG":"enabled"}}}
            """)
            let agentId = try #require((try createJSON(created))["id"] as? String)

            let patched = try await client.send(.patch, headers: createHeaders(f.ownerToken, f.serverId), to: URI(string: "/api/agents/\(agentId)")) { request in
                request.body = .init(string: """
                {"envVars":{"TEAM_FLAG":"changed","ANTHROPIC_BASE_URL":"https://should-strip.example.test","ANTHROPIC_API_KEY":"should-strip"}}
                """)
            }
            #expect(patched.status == .ok)
            let body = try createJSON(patched)
            #expect(body["envVars"] as? [String: String] == [
                "TEAM_FLAG": "changed",
                "ANTHROPIC_BASE_URL": "https://gateway.example.test/v1",
                "ANTHROPIC_API_KEY": "sk-ant-test",
                "ANTHROPIC_CUSTOM_MODEL_OPTION": "claude-opus-4-6",
            ])
            let config = try #require(body["runtimeConfig"] as? [String: Any])
            let expected: [String: Any] = [
                "version": 1,
                "runtime": "claude",
                "provider": ["kind": "custom", "apiUrl": "https://gateway.example.test/v1", "apiKey": ""],
                "model": ["kind": "custom", "name": "claude-opus-4-6"],
                "mode": ["kind": "default"],
                "reasoningEffort": NSNull(),
                "command": "claude-p",
                "envVars": ["TEAM_FLAG": "changed"],
            ]
            #expect(try jsonEquals(config, expected))
        }
    }
}

@Test func envVarsAreParsedAtTheBoundaryOnCreateAndPatch() async throws {
    let f = makeAgentCreateFixture("003")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let rejections: [(String, String, String)] = [
                ("reject-non-object-003", "\"TEAM_FLAG=1\"", "envVars must be an object"),
                ("reject-array-003", "[\"TEAM_FLAG\"]", "envVars must be an object"),
                ("reject-non-string-003", "{\"TEAM_FLAG\":1}", "envVars keys and values must be strings"),
                ("reject-bad-key-003", "{\"1BAD\":\"x\"}", "Invalid env var key \"1BAD\": must match [A-Za-z_][A-Za-z0-9_]*"),
                ("reject-null-byte-003", "{\"TEAM_FLAG\":\"ab\\u0000cd\"}", "envVars keys and values must not contain null bytes"),
            ]
            for (name, envJSON, reason) in rejections {
                let response = try await createAgentBody(client, token: f.ownerToken, serverId: f.serverId, body: """
                {"name":"\(name)","runtime":"claude","model":"sonnet","envVars":\(envJSON)}
                """)
                #expect(response.status == .badRequest, "\(name)")
                #expect(try createJSON(response)["error"] as? String == reason, "\(name)")
            }

            let valid = try await createAgentBody(client, token: f.ownerToken, serverId: f.serverId, body: """
            {"name":"parse-valid-003","runtime":"claude","model":"sonnet","envVars":{"TEAM_FLAG":"enabled"}}
            """)
            #expect(valid.status == .ok)
            let validBody = try createJSON(valid)
            let agentId = try #require(validBody["id"] as? String)
            #expect((validBody["envVars"] as? [String: String])?["TEAM_FLAG"] == "enabled")

            let nullEnv = try await createAgentBody(client, token: f.ownerToken, serverId: f.serverId, body: """
            {"name":"parse-null-env-003","runtime":"claude","model":"sonnet","envVars":null}
            """)
            #expect(nullEnv.status == .ok)
            let missingEnv = try await createAgentBody(client, token: f.ownerToken, serverId: f.serverId, body: """
            {"name":"parse-undefined-env-003","runtime":"claude","model":"sonnet"}
            """)
            #expect(missingEnv.status == .ok)

            let badPatch = try await client.send(.patch, headers: createHeaders(f.ownerToken, f.serverId), to: URI(string: "/api/agents/\(agentId)")) { request in
                request.body = .init(string: "{\"envVars\":{\"TEAM_FLAG\":1}}")
            }
            #expect(badPatch.status == .badRequest)
            #expect(try createJSON(badPatch)["error"] as? String == "envVars keys and values must be strings")

            let keep = try await client.send(.patch, headers: createHeaders(f.ownerToken, f.serverId), to: URI(string: "/api/agents/\(agentId)")) { request in
                request.body = .init(string: "{\"description\":\"renamed\"}")
            }
            #expect(keep.status == .ok)
            #expect((try createJSON(keep)["envVars"] as? [String: String])?["TEAM_FLAG"] == "enabled")

            let set = try await client.send(.patch, headers: createHeaders(f.ownerToken, f.serverId), to: URI(string: "/api/agents/\(agentId)")) { request in
                request.body = .init(string: "{\"envVars\":{\"TEAM_FLAG\":\"changed\"}}")
            }
            #expect(set.status == .ok)
            #expect((try createJSON(set)["envVars"] as? [String: String])?["TEAM_FLAG"] == "changed")
        }
    }
}

@Test func agentCreateOpensAEmptyCreatorDmForTheOwnerOnly() async throws {
    let f = makeAgentCreateFixture("004")
    let events = CreateEvents()
    f.accounts.realtimeEmitter = { room, event, payload in events.append(room, event, payload) }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let created = try await createAgentBody(client, token: f.ownerToken, serverId: f.serverId, body: """
            {"name":"creator-dm-agent-004","runtime":"codex"}
            """)
            #expect(created.status == .ok)
            let agentId = try #require((try createJSON(created))["id"] as? String)

            let ownerDms = try await client.get(URI(string: "/api/channels/dm"), headers: createHeaders(f.ownerToken, f.serverId))
            let ownerRows = (try JSONSerialization.jsonObject(with: Data((ownerDms.body.string ?? "").utf8))) as? [[String: Any]] ?? []
            let creatorDm = try #require(ownerRows.first { $0["peerType"] as? String == "agent" && $0["peerId"] as? String == agentId })
            #expect(creatorDm["lastMessageAt"] is NSNull)
            #expect(creatorDm["type"] as? String == "dm")

            let memberDms = try await client.get(URI(string: "/api/channels/dm"), headers: createHeaders(f.memberToken, f.serverId))
            let memberRows = (try JSONSerialization.jsonObject(with: Data((memberDms.body.string ?? "").utf8))) as? [[String: Any]] ?? []
            #expect(!memberRows.contains { $0["peerType"] as? String == "agent" && $0["peerId"] as? String == agentId })

            let reused = try await client.send(.post, headers: createHeaders(f.ownerToken, f.serverId), to: "/api/channels/dm") { request in
                request.body = .init(string: "{\"agentId\":\"\(agentId)\"}")
            }
            #expect(reused.status == .ok)
            #expect(try createJSON(reused)["id"] as? String == creatorDm["id"] as? String)

            let dmId = try #require(creatorDm["id"] as? String)
            let dmNew = events.values.filter { $0.event == "dm:new" }
            let payloads = dmNew.compactMap { entry -> String? in
                ((try? JSONSerialization.jsonObject(with: Data((entry.payload ?? "").utf8))) as? [String: Any])?["channelId"] as? String
            }
            #expect(payloads.allSatisfy { $0 == dmId })
            #expect(Set(dmNew.map(\.room)) == Set(["channel:\(dmId)", "user:\(f.ownerId)"]))
        }
    }
}

@Test func agentPatchUpdatesRuntimeValuesAndRejectsAnUnknownRestartMode() async throws {
    let f = makeAgentCreateFixture("005")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let created = try await createAgentBody(client, token: f.ownerToken, serverId: f.serverId, body: """
            {"name":"runtime-values-agent-005","runtime":"claude","model":"sonnet"}
            """)
            let agentId = try #require((try createJSON(created))["id"] as? String)

            let patched = try await client.send(.patch, headers: createHeaders(f.ownerToken, f.serverId), to: URI(string: "/api/agents/\(agentId)")) { request in
                request.body = .init(string: """
                {"displayName":"Runtime Renamed","runtime":"codex","model":"gpt-5.6-sol","reasoningEffort":"high","restartMode":"session"}
                """)
            }
            #expect(patched.status == .ok)
            let body = try createJSON(patched)
            #expect(body["displayName"] as? String == "Runtime Renamed")
            #expect(body["runtime"] as? String == "codex")
            #expect(body["model"] as? String == "gpt-5.6-sol")
            #expect(body["reasoningEffort"] as? String == "high")

            let invalid = try await client.send(.patch, headers: createHeaders(f.ownerToken, f.serverId), to: URI(string: "/api/agents/\(agentId)")) { request in
                request.body = .init(string: "{\"restartMode\":\"bogus\"}")
            }
            #expect(invalid.status == .badRequest)
            #expect(try createJSON(invalid)["error"] as? String == "Invalid restart mode: bogus")
        }
    }
}

@Test func agentPatchPreservesTheHostDiscoveredCodexPresetModel() async throws {
    let f = makeAgentCreateFixture("006")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let created = try await createAgentBody(client, token: f.ownerToken, serverId: f.serverId, body: """
            {"name":"dynamic-model-agent-006","runtime":"codex","model":"gpt-5.5"}
            """)
            let agentId = try #require((try createJSON(created))["id"] as? String)

            let patched = try await client.send(.patch, headers: createHeaders(f.ownerToken, f.serverId), to: URI(string: "/api/agents/\(agentId)")) { request in
                request.body = .init(string: """
                {"runtime":"codex","model":"gpt-5.6-sol","runtimeConfig":{"version":1,"runtime":"codex","model":{"kind":"preset","id":"gpt-5.6-sol"},"mode":{"kind":"default"},"reasoningEffort":null,"envVars":null},"reasoningEffort":null}
                """)
            }
            #expect(patched.status == .ok)
            let body = try createJSON(patched)
            #expect(body["model"] as? String == "gpt-5.6-sol")
            let config = try #require(body["runtimeConfig"] as? [String: Any])
            let model = try #require(config["model"] as? [String: Any])
            #expect(model["kind"] as? String == "preset")
            #expect(model["id"] as? String == "gpt-5.6-sol")
        }
    }
}
