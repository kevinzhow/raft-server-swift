import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentCreatorKeepsOnlyTheExactAgentAfterDemotionAndLosesItOnDeparture() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111264"
    let relatedId = "11111111-1111-4111-8111-111111111265"
    let serverId = "33333333-3333-4333-8333-333333333452"
    accounts.addAccount(id: ownerId, email: "agent-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: relatedId, email: "agent-related@slock.test", password: "password123")
    accounts.markEmailVerified(userId: relatedId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-rbac", name: "Agent RBAC", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: relatedId, role: "admin")
    let own = accounts.oauth.createAgent(serverId: serverId, name: "own", creatorUserId: relatedId, runtime: "managed")
    let ownExternal = accounts.oauth.createAgent(serverId: serverId, name: "own-ext", creatorUserId: relatedId, runtime: "external")
    let other = accounts.oauth.createAgent(serverId: serverId, name: "other", creatorUserId: ownerId, runtime: "managed")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"agent-related@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"

            func call(_ method: HTTPRequest.Method, _ path: String, body: String? = nil) async throws -> ClientResponse {
                try await client.send(method, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
            }

            accounts.oauth.addMember(serverId: serverId, userId: relatedId, role: "member")
            let patchOwn = try await call(.patch, "/api/agents/\(own)", body: "{\"description\":\"still mine after demotion\"}")
            #expect(patchOwn.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((patchOwn.body.string ?? "").utf8)) as? [String: Any])?["description"] as? String == "still mine after demotion")
            // This root has no retained execution runtime. The accepted creator
            // Stop200/full-reset202 scenes now run in the real PG opt-in test.
            let ownStop = try await call(.post, "/api/agents/\(own)/stop", body: "{}")
            #expect(ownStop.status == .internalServerError)
            #expect(ownStop.body.string == #"{"error":"Failed to stop agent"}"#)
            let ownReset = try await call(.post, "/api/agents/\(own)/reset", body: "{\"mode\":\"full\"}")
            #expect(ownReset.status == .internalServerError)
            #expect(ownReset.body.string == #"{"error":"Failed to reset agent"}"#)
            // Exact creator authority survives Guest demotion as well. Passing
            // authority still cannot turn this unbound root into an executor.
            accounts.oauth.addMember(serverId: serverId, userId: relatedId, role: "guest")
            let guestOwnStop = try await call(.post, "/api/agents/\(own)/stop", body: "{}")
            #expect(guestOwnStop.status == .internalServerError)
            #expect(guestOwnStop.body.string == #"{"error":"Failed to stop agent"}"#)
            let guestOwnReset = try await call(.post, "/api/agents/\(own)/reset", body: "{\"mode\":\"full\"}")
            #expect(guestOwnReset.status == .internalServerError)
            #expect(guestOwnReset.body.string == #"{"error":"Failed to reset agent"}"#)
            accounts.oauth.addMember(serverId: serverId, userId: relatedId, role: "member")
            #expect(try await call(.post, "/api/agents/\(ownExternal)/credentials", body: "{}").status == .created)
            #expect(try await call(.post, "/api/agents/\(own)/credentials", body: "{}").status == .badRequest)

            #expect(try await call(.patch, "/api/agents/\(other)", body: "{\"description\":\"must not widen\"}").status == .forbidden)
            #expect(try await call(.post, "/api/agents/\(other)/reset", body: "{\"mode\":\"full\"}").status == .forbidden)
            #expect(try await call(.delete, "/api/agents/\(other)").status == .forbidden)
            #expect(try await call(.post, "/api/agents/\(other)/credentials", body: "{}").status == .forbidden)

            #expect(try await call(.delete, "/api/agents/\(own)").status == .ok)

            let departed = accounts.oauth.createAgent(serverId: serverId, name: "departed", creatorUserId: relatedId, runtime: "managed")
            #expect(try await call(.patch, "/api/agents/\(departed)", body: "{\"description\":\"before departure\"}").status == .ok)
            accounts.oauth.removeMember(serverId: serverId, userId: relatedId)
            for (method, path, body) in [
                (HTTPRequest.Method.patch, "/api/agents/\(departed)", "{\"description\":\"after departure\"}"),
                (.post, "/api/agents/\(departed)/stop", "{}"),
                (.post, "/api/agents/\(departed)/reset", "{\"mode\":\"full\"}"),
                (.post, "/api/agents/\(departed)/migrate", "{}"),
                (.delete, "/api/agents/\(departed)", nil),
            ] {
                let response = try await call(method, path, body: body)
                #expect(response.status == .forbidden)
                #expect((try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Not a member of this server")
            }
            for method in [HTTPRequest.Method.post, .get] {
                let response = try await call(method, "/api/agents/\(departed)/credentials", body: method == .post ? "{}" : nil)
                #expect(response.status == .notFound)
                #expect((try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "agent_missing")
            }
        }
    }
}
