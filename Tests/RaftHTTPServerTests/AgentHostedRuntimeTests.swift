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
        }
    }
}
