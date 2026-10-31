import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentCreatorIsProjectedAndOnlyAdminsCanPatchIt() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111580"
    let memberId = "11111111-1111-4111-8111-111111111581"
    let serverId = "33333333-3333-4333-8333-333333333640"
    accounts.addAccount(id: ownerId, email: "creator-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "creator-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "creator", name: "Creator", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

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
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("creator-owner@slock.test")
            let memberToken = try await login("creator-member@slock.test")
            let created = try await client.send(.post, headers: headers(ownerToken), to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"creator-agent\",\"runtime\":\"codex\"}")
            }
            #expect(created.status == .ok)
            let createdBody = try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any]
            let agent = createdBody?["id"] as? String ?? ""
            let creator = createdBody?["creator"] as? [String: Any]
            #expect(creator?["type"] as? String == "human")
            #expect(creator?["id"] as? String == ownerId)

            let get = try await client.send(.get, headers: headers(ownerToken), to: "/api/agents/\(agent)")
            #expect(((try JSONSerialization.jsonObject(with: Data((get.body.string ?? "").utf8)) as? [String: Any])?["creator"] as? [String: Any])?["id"] as? String == ownerId)

            let forbidden = try await client.send(.patch, headers: headers(memberToken), to: "/api/agents/\(agent)/creator") { request in
                request.body = .init(string: "{\"creatorType\":\"user\",\"creatorId\":\"\(memberId)\"}")
            }
            #expect(forbidden.status == .notFound)

            let patched = try await client.send(.patch, headers: headers(ownerToken), to: "/api/agents/\(agent)/creator") { request in
                request.body = .init(string: "{\"creatorType\":\"user\",\"creatorId\":\"\(memberId)\"}")
            }
            #expect(patched.status == .ok)
            let after = try await client.send(.get, headers: headers(ownerToken), to: "/api/agents/\(agent)")
            #expect(((try JSONSerialization.jsonObject(with: Data((after.body.string ?? "").utf8)) as? [String: Any])?["creator"] as? [String: Any])?["id"] as? String == memberId)
        }
    }
}
