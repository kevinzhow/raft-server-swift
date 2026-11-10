import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func runtimeAccountUsageIsReadOnlyAndLimitedToAdminsAndTheAttacher() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111652"
    let adminId = "11111111-1111-4111-8111-111111111653"
    let memberId = "11111111-1111-4111-8111-111111111654"
    let bystanderId = "11111111-1111-4111-8111-111111111655"
    let serverId = "33333333-3333-4333-8333-333333333682"
    for (id, email, role) in [
        (ownerId, "usage-read-owner@slock.test", "owner"),
        (adminId, "usage-read-admin@slock.test", "admin"),
        (memberId, "usage-read-member@slock.test", "member"),
        (bystanderId, "usage-read-bystander@slock.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "runtime-usage-read", name: "Runtime Usage Read", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "usage-machine")
    accounts.linkComputerForTesting(serverId: serverId, machineId: machine, attachedByUserId: memberId)
    accounts.setRuntimeAccountUsageForTesting(
        machineId: machine,
        provider: "codex",
        json: "{\"protocolVersion\":2,\"provider\":\"codex\",\"collectedAt\":\"2026-10-11T08:00:00.000Z\",\"staleAfter\":\"2026-10-11T08:30:00.000Z\",\"collectorVersion\":\"1.6.2\",\"accounts\":[{\"accountKey\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"maskedLabel\":\"run****email@company.com\",\"planLabel\":\"Pro\",\"health\":\"ok\",\"windows\":[]}]}",
        staleAfter: Date().addingTimeInterval(1800)
    )

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
            func get(_ bearer: String, _ path: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.get(URI(string: path), headers: headers)
            }
            func refresh(_ bearer: String, _ path: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: "{\"reason\":\"stale_or_missing\"}")
                }
            }
            let owner = try await token("usage-read-owner@slock.test")
            let admin = try await token("usage-read-admin@slock.test")
            let member = try await token("usage-read-member@slock.test")
            let bystander = try await token("usage-read-bystander@slock.test")
            let base = "/api/servers/\(serverId)/machines/\(machine)/runtime-account-usage/codex"

            for bearer in [owner, admin, member] {
                let response = try await get(bearer, base)
                #expect(response.status == .ok)
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                #expect(body?["state"] as? String == "fresh")
                let snapshot = body?["snapshot"] as? [String: Any]
                let accounts = snapshot?["accounts"] as? [[String: Any]] ?? []
                #expect(accounts.first?["maskedLabel"] as? String == "run****email@company.com")
                #expect((response.body.string ?? "").contains("runtime-email@company.com") == false)
            }
            #expect(try await get(bystander, base).status == .forbidden)
            #expect(try await get(owner, "/api/servers/\(serverId)/machines/\(machine)/runtime-account-usage/unknown").status == .notFound)

            #expect(try await refresh(bystander, "\(base)/refresh").status == .forbidden)
            let first = try await refresh(admin, "\(base)/refresh")
            #expect(first.status == .accepted)
            let firstBody = try JSONSerialization.jsonObject(with: Data((first.body.string ?? "").utf8)) as? [String: Any]
            #expect(firstBody?["accepted"] as? Bool == true)
            #expect(firstBody?["state"] as? String == "requested")
            let second = try await refresh(member, "\(base)/refresh")
            #expect(second.status == .accepted)
            let secondBody = try JSONSerialization.jsonObject(with: Data((second.body.string ?? "").utf8)) as? [String: Any]
            #expect(secondBody?["accepted"] as? Bool == false)
            #expect(secondBody?["state"] as? String == "cooldown")
        }
    }
}
