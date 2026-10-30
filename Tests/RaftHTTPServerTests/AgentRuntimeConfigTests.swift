import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentCreatePersistsRuntimeConfigAndStripsItFromMemberList() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111270"
    let memberId = "11111111-1111-4111-8111-111111111271"
    let serverId = "33333333-3333-4333-8333-333333333458"
    accounts.addAccount(id: ownerId, email: "runtime-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "runtime-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "runtime-config", name: "Runtime Config Server", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let creatorAgent = accounts.oauth.createAgent(
        serverId: serverId,
        name: "member-created-agent",
        creatorUserId: memberId,
        runtime: "codex",
        runtimeConfigJSON: "{}",
        envVarsJSON: "{\"CREATOR_VISIBLE\":\"true\"}"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            let ownerToken = try await login("runtime-owner@slock.test")
            let memberToken = try await login("runtime-member@slock.test")
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }

            let create = try await client.send(.post, headers: headers(ownerToken), to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"runtime-config-agent\",\"runtimeConfig\":{\"version\":1,\"runtime\":\"claude\",\"provider\":{\"kind\":\"custom\",\"apiUrl\":\"https://gateway.example.test/v1\",\"apiKey\":\"sk-ant-test\"},\"model\":{\"kind\":\"custom\",\"name\":\"claude-opus-4-6\"},\"command\":\"claude-p\",\"envVars\":{\"TEAM_FLAG\":\"enabled\"}}}")
            }
            #expect(create.status == .ok)
            let created = try JSONSerialization.jsonObject(with: Data((create.body.string ?? "").utf8)) as? [String: Any]
            let createdId = created?["id"] as? String ?? ""
            #expect(created?["runtime"] as? String == "claude")
            #expect(created?["model"] as? String == "claude-opus-4-6")
            let env = created?["envVars"] as? [String: String]
            #expect(env == [
                "TEAM_FLAG": "enabled",
                "ANTHROPIC_BASE_URL": "https://gateway.example.test/v1",
                "ANTHROPIC_API_KEY": "sk-ant-test",
                "ANTHROPIC_CUSTOM_MODEL_OPTION": "claude-opus-4-6",
            ])
            let runtimeConfig = created?["runtimeConfig"] as? [String: Any]
            #expect(runtimeConfig?["mode"] as? [String: Any] != nil)
            #expect(runtimeConfig?["reasoningEffort"] is NSNull)

            let patch = try await client.send(.patch, headers: headers(ownerToken), to: "/api/agents/\(createdId)") { request in
                request.body = .init(string: "{\"envVars\":{\"TEAM_FLAG\":\"changed\",\"ANTHROPIC_BASE_URL\":\"https://should-strip.example.test\",\"ANTHROPIC_API_KEY\":\"should-strip\"}}")
            }
            #expect(patch.status == .ok)
            let patched = try JSONSerialization.jsonObject(with: Data((patch.body.string ?? "").utf8)) as? [String: Any]
            #expect(patched?["envVars"] as? [String: String] == [
                "TEAM_FLAG": "changed",
                "ANTHROPIC_BASE_URL": "https://gateway.example.test/v1",
                "ANTHROPIC_API_KEY": "sk-ant-test",
                "ANTHROPIC_CUSTOM_MODEL_OPTION": "claude-opus-4-6",
            ])

            let memberList = try await client.send(.get, headers: headers(memberToken), to: "/api/agents")
            #expect(memberList.status == .ok)
            let rows = try JSONSerialization.jsonObject(with: Data((memberList.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            let visible = rows.first { $0["id"] as? String == createdId }
            #expect(visible != nil)
            #expect(visible?["runtimeConfig"] == nil)
            #expect(visible?["envVars"] == nil)
            let creatorVisible = rows.first { $0["id"] as? String == creatorAgent }
            #expect(creatorVisible?["envVars"] as? [String: String] == ["CREATOR_VISIBLE": "true"])

            let malformed = try await client.send(.get, headers: headers(ownerToken), to: "/api/agents/not-a-uuid")
            #expect(malformed.status == .notFound)
        }
    }
}
