import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func modelLabelCatalogIsMemberReadableAndWhitelisted() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111409"
    let memberId = "11111111-1111-4111-8111-111111111410"
    let guestId = "11111111-1111-4111-8111-111111111411"
    let outsiderId = "11111111-1111-4111-8111-111111111412"
    let serverId = "33333333-3333-4333-8333-333333333539"
    for (id, email) in [
        (ownerId, "catalog-owner@slock.test"),
        (memberId, "catalog-member@slock.test"),
        (guestId, "catalog-guest@slock.test"),
        (outsiderId, "catalog-outsider@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "model-catalog", name: "Model Catalog", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "model-catalog-computer")
    accounts.setMachineRuntimeModels(
        machineId: machineId,
        runtime: "codex",
        models: [("gpt-6-astra", "GPT-6-Astra"), ("gpt-5.6-sol", "GPT-5.6-Sol")]
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
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            func catalog(_ token: String) async throws -> ([String: Any], Int) {
                let response = try await client.send(.get, headers: headers(token), to: "/api/servers/\(serverId)/model-label-catalog")
                let body = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]) ?? [:]
                return (body, response.status.code)
            }
            let memberToken = try await login("catalog-member@slock.test")
            let guestToken = try await login("catalog-guest@slock.test")
            let outsiderToken = try await login("catalog-outsider@slock.test")

            let memberRead = try await catalog(memberToken)
            #expect(memberRead.1 == 200)
            let machines = memberRead.0["machines"] as? [String: Any]
            let machine = machines?[machineId] as? [String: Any]
            let runtimes = machine?["runtimes"] as? [String: Any]
            let codex = runtimes?["codex"] as? [String: Any]
            let models = codex?["models"] as? [[String: Any]] ?? []
            #expect(models.compactMap { $0["id"] as? String } == ["gpt-6-astra", "gpt-5.6-sol"])
            #expect(models.compactMap { $0["label"] as? String } == ["GPT-6-Astra", "GPT-5.6-Sol"])
            #expect(Set(codex?.keys ?? [:].keys) == ["models", "updatedAt"])
            #expect(models.allSatisfy { Set($0.keys) == ["id", "label"] })

            let guestRead = try await catalog(guestToken)
            #expect(guestRead.1 == 200)
            #expect((((guestRead.0["machines"] as? [String: Any])?[machineId] as? [String: Any])?["runtimes"] as? [String: Any])?["codex"] != nil)

            #expect(try await catalog(outsiderToken).1 == 403)
        }
    }
}
