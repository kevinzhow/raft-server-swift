import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func machineRuntimeOptionsAndModelsUseTheMachineCapabilityList() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111650"
    let memberId = "11111111-1111-4111-8111-111111111651"
    let serverId = "33333333-3333-4333-8333-333333333681"
    for (id, email) in [
        (ownerId, "runtime-options-owner@slock.test"),
        (memberId, "runtime-options-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "runtime-options", name: "Runtime Options", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "runtime-machine")
    accounts.setMachineRuntimesForTesting(machineId: machine, runtimes: ["codex"])
    accounts.setMachineRuntimeModels(machineId: machine, runtime: "codex", models: [("gpt-5.4", "GPT 5.4")])

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
                return try await client.get(URI(string: path), headers: headers)
            }
            let owner = try await token("runtime-options-owner@slock.test")
            let member = try await token("runtime-options-member@slock.test")
            let base = "/api/servers/\(serverId)/machines/\(machine)"

            #expect(try await get(member, "\(base)/runtime-options").status == .forbidden)
            let optionsResponse = try await get(owner, "\(base)/runtime-options")
            #expect(optionsResponse.status == .ok)
            let optionsBody = try JSONSerialization.jsonObject(with: Data((optionsResponse.body.string ?? "").utf8)) as? [String: Any]
            #expect(optionsBody?["context"] as? String == "new_agent")
            #expect(optionsBody?["machineId"] as? String == machine)
            let options = optionsBody?["options"] as? [[String: Any]] ?? []
            let codex = options.first { $0["runtimeId"] as? String == "codex" }
            let claude = options.first { $0["runtimeId"] as? String == "claude" }
            let builtin = options.first { $0["runtimeId"] as? String == "builtin" }
            #expect(codex?["capabilityStatus"] as? String == "available")
            #expect(codex?["canSelectInThisContext"] as? Bool == true)
            #expect(claude?["capabilityStatus"] as? String == "not_installed")
            #expect(claude?["canSelectInThisContext"] as? Bool == false)
            #expect(builtin?["capabilityStatus"] as? String == "update_required")
            #expect(!options.contains { $0["runtimeId"] as? String == "grok" })

            #expect(try await get(member, "\(base)/runtime-models/codex").status == .forbidden)
            let modelsResponse = try await get(owner, "\(base)/runtime-models/codex")
            #expect(modelsResponse.status == .ok)
            let modelsBody = try JSONSerialization.jsonObject(with: Data((modelsResponse.body.string ?? "").utf8)) as? [String: Any]
            #expect(modelsBody?["kind"] as? String == "live")
            #expect(modelsBody?["default"] as? String == "gpt-5.4")
            let models = modelsBody?["models"] as? [[String: Any]] ?? []
            #expect(models.count == 1)
            #expect(models.first?["id"] as? String == "gpt-5.4")
            #expect(models.first?["label"] as? String == "GPT 5.4")
        }
    }
}
