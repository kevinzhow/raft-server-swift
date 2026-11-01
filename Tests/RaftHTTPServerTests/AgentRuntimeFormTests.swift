import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentRuntimeFormProjectsStoredValuesWithoutSecrets() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111698"
    let memberId = "11111111-1111-4111-8111-111111111699"
    let serverId = "33333333-3333-4333-8333-333333333706"
    for (id, email, role) in [
        (ownerId, "runtime-form-owner@slock.test", "owner"),
        (memberId, "runtime-form-member@slock.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "agent-runtime-form", name: "Agent Runtime Form", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    let gemini = accounts.oauth.createAgent(
        serverId: serverId,
        name: "gemini-form",
        runtime: "gemini",
        runtimeConfigJSON: "{\"version\":1,\"runtime\":\"gemini\",\"model\":{\"kind\":\"preset\",\"id\":\"gemini-2.5-pro\"},\"envVars\":{\"OLD\":\"1\"}}"
    )
    let claudeSecret = "sk-claude-stored-secret"
    let claude = accounts.oauth.createAgent(
        serverId: serverId,
        name: "claude-form",
        runtime: "claude",
        runtimeConfigJSON: "{\"version\":1,\"runtime\":\"claude\",\"provider\":{\"kind\":\"custom\",\"apiUrl\":\"https://gateway.example.test\",\"apiKey\":\"\(claudeSecret)\"},\"model\":{\"kind\":\"preset\",\"id\":\"sonnet\"},\"reasoningEffort\":\"high\",\"envVars\":{\"KEEP\":\"1\"},\"command\":\"/opt/claude\"}"
    )
    let antigravity = accounts.oauth.createAgent(
        serverId: serverId,
        name: "antigravity-form",
        runtime: "antigravity",
        runtimeConfigJSON: "{\"version\":1,\"runtime\":\"antigravity\",\"model\":{\"kind\":\"custom\",\"name\":\"agy-picked\"},\"envVars\":{\"OLD\":\"1\"}}"
    )
    let external = accounts.oauth.createAgent(serverId: serverId, name: "external-form", runtime: "external")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func token(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func form(_ bearer: String, _ agentId: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.get("/api/agents/\(agentId)/runtime-form", headers: headers)
            }
            let owner = try await token("runtime-form-owner@slock.test")
            let member = try await token("runtime-form-member@slock.test")

            #expect(try await form(member, gemini).status == .forbidden)
            let geminiResponse = try await form(owner, gemini)
            #expect(geminiResponse.status == .ok)
            #expect(geminiResponse.status == .ok)
            let geminiBody = try JSONSerialization.jsonObject(with: Data((geminiResponse.body.string ?? "").utf8)) as? [String: Any]
            #expect(geminiBody?["protocolVersion"] as? Int == 2)
            #expect(geminiBody?["runtimeId"] as? String == "gemini")
            let geminiValues = geminiBody?["values"] as? [String: Any]
            #expect(geminiValues?["model"] as? String == "gemini-2.5-pro")
            #expect((geminiValues?["envVars"] as? [String: String]) == ["OLD": "1"])

            let claudeResponse = try await form(owner, claude)
            #expect(claudeResponse.status == .ok)
            #expect((claudeResponse.body.string ?? "").contains(claudeSecret) == false)
            let claudeBody = try JSONSerialization.jsonObject(with: Data((claudeResponse.body.string ?? "").utf8)) as? [String: Any]
            let claudeValues = claudeBody?["values"] as? [String: Any]
            #expect(claudeValues?["provider"] as? String == "custom")
            #expect(claudeValues?["apiUrl"] as? String == "https://gateway.example.test")
            #expect(claudeValues?["model"] as? String == "sonnet")
            #expect(claudeValues?["reasoningEffort"] as? String == "high")
            #expect(claudeValues?["fastMode"] as? Bool == false)
            #expect(claudeValues?["command"] as? String == "/opt/claude")
            #expect((claudeValues?["envVars"] as? [String: String]) == ["KEEP": "1"])
            #expect((claudeBody?["capabilities"] as? [String: Any])?["writeOnlyPointers"] as? [String] == ["/apiKey"])

            let antigravityBody = try JSONSerialization.jsonObject(with: Data((try await form(owner, antigravity).body.string ?? "").utf8)) as? [String: Any]
            #expect((antigravityBody?["values"] as? [String: Any])?["model"] == nil)
            #expect(try await form(owner, external).status == .notFound)
            #expect(try await form(owner, "missing").status == .notFound)
        }
    }
}
