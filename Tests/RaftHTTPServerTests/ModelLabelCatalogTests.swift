import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func modelLabelCatalogIsMemberReadableAndLabelOnly() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111658"
    let memberId = "11111111-1111-4111-8111-111111111659"
    let guestId = "11111111-1111-4111-8111-111111111660"
    let outsiderId = "11111111-1111-4111-8111-111111111661"
    let serverId = "33333333-3333-4333-8333-333333333684"
    for (id, email, role) in [
        (ownerId, "label-owner@slock.test", "owner"),
        (memberId, "label-member@slock.test", "member"),
        (guestId, "label-guest@slock.test", "guest"),
        (outsiderId, "label-outsider@slock.test", nil),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "labels", name: "Labels", ownerId: id)
        } else if let role {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "label-machine")
    accounts.setMachineRuntimeModels(machineId: machine, runtime: "codex", models: [("gpt-6-astra", "GPT-6-Astra"), ("gpt-5.6-sol", "GPT-5.6-Sol")])

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
            func catalog(_ bearer: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.get("/api/servers/\(serverId)/model-label-catalog", headers: headers)
            }
            let owner = try await token("label-owner@slock.test")
            let member = try await token("label-member@slock.test")
            let guest = try await token("label-guest@slock.test")
            let outsider = try await token("label-outsider@slock.test")

            for bearer in [owner, member, guest] {
                let response = try await catalog(bearer)
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                let machines = body?["machines"] as? [String: Any]
                let runtime = (machines?[machine] as? [String: Any])?["runtimes"] as? [String: Any]
                let codex = runtime?["codex"] as? [String: Any]
                let models = codex?["models"] as? [[String: Any]] ?? []
                #expect(models.map { $0["id"] as? String } == ["gpt-6-astra", "gpt-5.6-sol"])
                #expect(models.map { $0["label"] as? String } == ["GPT-6-Astra", "GPT-5.6-Sol"])
                let modelKeys = Set((models.first ?? [:]).keys)
                let codexKeys = Set((codex ?? [:]).keys)
                #expect(modelKeys == Set(["id", "label"]))
                #expect(codexKeys == Set(["models", "updatedAt"]))
            }
            #expect(try await catalog(outsider).status == .forbidden)
        }
    }
}
