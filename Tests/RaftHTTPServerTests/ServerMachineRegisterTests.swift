import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func registeringAServerMachineReturnsItsKeyOnce() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111630"
    let memberId = "11111111-1111-4111-8111-111111111631"
    let serverId = "33333333-3333-4333-8333-333333333673"
    accounts.addAccount(id: ownerId, email: "register-machine@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "register-machine-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "register-machine", name: "Register Machine", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

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
            func register(_ bearer: String, body: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.post, headers: headers, to: "/api/servers/\(serverId)/machines") { request in
                    request.body = .init(string: body)
                }
            }

            let owner = try await token("register-machine@slock.test")
            let member = try await token("register-machine-member@slock.test")
            #expect(try await register(member, body: "{\"name\":\"member-machine\"}").status == .forbidden)
            #expect(try await register(owner, body: "{}").status == .badRequest)

            let created = try await register(owner, body: "{\"name\":\"owner-machine\"}")
            #expect(created.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any]
            let machine = body?["machine"] as? [String: Any]
            let machineId = machine?["id"] as? String ?? ""
            let apiKey = body?["apiKey"] as? String ?? ""
            #expect(machine?["name"] as? String == "owner-machine")
            #expect(machine?["serverId"] as? String == serverId)
            #expect(apiKey.hasPrefix("sk_machine_"))
            #expect(accounts.machineAPIKey(machineId: machineId) == apiKey)

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(owner)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let listed = try await client.get("/api/servers/\(serverId)/machines", headers: headers)
            let listedBody = try JSONSerialization.jsonObject(with: Data((listed.body.string ?? "").utf8)) as? [String: Any]
            #expect((listedBody?["machines"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == machineId })
        }
    }
}
