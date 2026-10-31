import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func memberCanStopAndSessionResetButNotFullReset() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111601"
    let memberId = "11111111-1111-4111-8111-111111111602"
    let serverId = "33333333-3333-4333-8333-333333333652"
    accounts.addAccount(id: ownerId, email: "reset-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "reset-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "reset", name: "Reset", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "reset-agent", creatorUserId: ownerId)

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
                request.body = .init(string: "{\"email\":\"reset-member@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            #expect(try await client.send(.post, headers: headers, to: "/api/agents/\(agent)/stop").status == .ok)
            for mode in ["restart", "session"] {
                let reset = try await client.send(.post, headers: headers, to: "/api/agents/\(agent)/reset") { request in
                    request.body = .init(string: "{\"mode\":\"\(mode)\"}")
                }
                #expect(reset.status.code == 202)
                #expect((try JSONSerialization.jsonObject(with: Data((reset.body.string ?? "").utf8)) as? [String: Any])?["status"] as? String == "accepted")
            }
            let full = try await client.send(.post, headers: headers, to: "/api/agents/\(agent)/reset") { request in
                request.body = .init(string: "{\"mode\":\"full\"}")
            }
            #expect(full.status == .forbidden)
            #expect(((try JSONSerialization.jsonObject(with: Data((full.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String ?? "").contains("resetAgentWorkspace"))
        }
    }
}
