import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func hostedRuntimeStatusIsCreatorOrAdminOnly() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111700"
    let memberId = "11111111-1111-4111-8111-111111111701"
    let serverId = "33333333-3333-4333-8333-333333333707"
    for (id, email, role) in [
        (ownerId, "hosted-owner@slock.test", "owner"),
        (memberId, "hosted-member@slock.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "hosted", name: "Hosted", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "hosted-agent", creatorUserId: ownerId)

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
            func status(_ bearer: String, _ agentId: String = agent) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.get("/api/agents/\(agentId)/hosted-runtime", headers: headers)
            }
            let owner = try await token("hosted-owner@slock.test")
            let member = try await token("hosted-member@slock.test")

            let missing = try await status(owner)
            #expect(missing.status == .notFound)
            #expect((try JSONSerialization.jsonObject(with: Data((missing.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "hosted_runtime_missing")

            accounts.setHostedRuntimeForTesting(agentId: agent, provider: "openai", model: "gpt-5.6-luna", state: "active", retryNeedsModel: true)
            #expect(try await status(member).status == .forbidden)
            let response = try await status(owner)
            #expect(response.status == .ok)
            #expect(response.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let hosted = body?["hostedRuntime"] as? [String: Any]
            #expect(hosted?["agentId"] as? String == agent)
            #expect(hosted?["provider"] as? String == "openai")
            #expect(hosted?["model"] as? String == "gpt-5.6-luna")
            #expect(hosted?["state"] as? String == "active")
            #expect(hosted?["retryNeedsModel"] as? Bool == true)
            #expect(body?["onboardingSetup"] is NSNull)
            #expect(try await status(owner, "missing").status == .notFound)

            func usage(_ bearer: String, _ query: String = "") async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.get("/api/agents/\(agent)/hosted-runtime/usage\(query)", headers: headers)
            }
            #expect(try await usage(owner).status == .conflict)
            let usageJSON = "{\"raftAgentId\":\"\(agent)\",\"bucket\":\"1d\",\"from\":\"2026-09-25T00:00:00.000Z\",\"to\":\"2026-10-02T00:00:00.000Z\",\"asOf\":\"2026-10-02T00:00:00.000Z\",\"partial\":false,\"rows\":[{\"at\":\"2026-10-01T00:00:00.000Z\",\"resource\":\"model.tokens\",\"dimensions\":{\"model\":\"m1\",\"kind\":\"input\"},\"unit\":\"tokens\",\"quantity\":10}]}"
            accounts.setHostedUsageForTesting(agentId: agent, json: usageJSON)
            #expect(try await usage(member).status == .forbidden)
            let usageResponse = try await usage(owner)
            #expect(usageResponse.status == .ok)
            #expect(usageResponse.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            let usageBody = try JSONSerialization.jsonObject(with: Data((usageResponse.body.string ?? "").utf8)) as? [String: Any]
            #expect(usageBody?["bucket"] as? String == "1d")
            #expect((usageBody?["rows"] as? [[String: Any]] ?? []).count == 1)
            #expect(try await usage(owner, "?bucket=5m").status == .badRequest)
            #expect(try await usage(owner, "?from=yesterday").status == .badRequest)
            #expect(try await usage(owner, "?from=2026-02-01T00:00:00Z&to=2026-01-01T00:00:00Z").status == .badRequest)
            #expect(try await usage(owner, "?from=2026-01-01T00:00:00Z&to=2026-03-01T00:00:00Z").status == .badRequest)
        }
    }
}
