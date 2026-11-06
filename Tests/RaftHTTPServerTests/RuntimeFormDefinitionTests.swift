import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func runtimeFormDefinitionsAndOptionSourcesAreProjectedForTheMachine() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111656"
    let memberId = "11111111-1111-4111-8111-111111111657"
    let serverId = "33333333-3333-4333-8333-333333333683"
    for (id, email) in [
        (ownerId, "runtime-form-owner@slock.test"),
        (memberId, "runtime-form-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "runtime-forms", name: "Runtime Forms", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "runtime-form-machine")
    accounts.setMachineRuntimesForTesting(machineId: machine, runtimes: ["builtin", "codex"])

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
            func get(_ bearer: String, _ path: String, language: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                if let language { headers[HTTPField.Name("Accept-Language")!] = language }
                return try await client.get(URI(string: path), headers: headers)
            }
            let owner = try await token("runtime-form-owner@slock.test")
            let member = try await token("runtime-form-member@slock.test")
            let base = "/api/servers/\(serverId)/machines/\(machine)"

            #expect(try await get(member, "\(base)/runtime-form-definitions/builtin?schemaVersion=builtin-pi.create.v3").status == .forbidden)
            let definition = try await get(owner, "\(base)/runtime-form-definitions/builtin?schemaVersion=builtin-pi.create.v3")
            #expect(definition.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((definition.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["protocolVersion"] as? Int == 1)
            #expect(body?["runtimeId"] as? String == "builtin")
            #expect(body?["schemaVersion"] as? String == "builtin-pi.create.v3")
            let dataSchema = body?["dataSchema"] as? [String: Any]
            let properties = dataSchema?["properties"] as? [String: Any]
            #expect((properties?["apiKey"] as? [String: Any])?["writeOnly"] as? Bool == true)
            #expect((properties?["supportsImageInput"] as? [String: Any])?["type"] as? String == "boolean")
            let capabilities = body?["capabilities"] as? [String: Any]
            #expect(capabilities?["writeOnlyPointers"] as? [String] == ["/apiKey"])
            #expect(capabilities?["forbiddenPointers"] as? [String] == ["/hostUserState"])
            let sources = body?["optionSources"] as? [String: Any]
            let sourceKeys = Set((sources ?? [:]).keys)
            #expect(sourceKeys == Set(["provider", "model"]))

            let stale = try await get(owner, "\(base)/runtime-form-definitions/builtin?schemaVersion=stale")
            #expect(stale.status == .conflict)
            let staleBody = try JSONSerialization.jsonObject(with: Data((stale.body.string ?? "").utf8)) as? [String: Any]
            #expect((staleBody?["issues"] as? [[String: Any]])?.first?["code"] as? String == "stale_form_schema")
            #expect(try await get(owner, "\(base)/runtime-form-definitions/unknown").status == .notFound)

            let provider = try await get(owner, "\(base)/runtime-form-definitions/builtin/option-sources/provider?schemaVersion=builtin-pi.create.v3")
            #expect(provider.status == .ok)
            let providerBody = try JSONSerialization.jsonObject(with: Data((provider.body.string ?? "").utf8)) as? [String: Any]
            #expect(providerBody?["sourceId"] as? String == "provider")
            #expect(providerBody?["kind"] as? String == "select")
            let options = providerBody?["options"] as? [[String: Any]] ?? []
            #expect(options.contains { $0["value"] as? String == "deepseek" && $0["providerKind"] as? String == "preset" })

            let model = try await get(owner, "\(base)/runtime-form-definitions/builtin/option-sources/model?schemaVersion=builtin-pi.create.v3")
            #expect(model.status == .ok)
            let modelBody = try JSONSerialization.jsonObject(with: Data((model.body.string ?? "").utf8)) as? [String: Any]
            #expect(modelBody?["kind"] as? String == "dependent_select")
            #expect(((modelBody?["optionsByValue"] as? [String: Any])?["deepseek"] as? [[String: Any]] ?? []).isEmpty == false)
            #expect(try await get(owner, "\(base)/runtime-form-definitions/builtin/option-sources/unknown?schemaVersion=builtin-pi.create.v3").status == .notFound)

            let v2 = try await get(owner, "\(base)/runtime-forms/v2/builtin")
            #expect(v2.status == .ok)
            #expect(v2.headers[HTTPField.Name("Content-Language")!] == "en")
            #expect(v2.headers[HTTPField.Name("Vary")!] == "Accept-Language")
            let v2Body = try JSONSerialization.jsonObject(with: Data((v2.body.string ?? "").utf8)) as? [String: Any]
            #expect(v2Body?["protocolVersion"] as? Int == 2)
            #expect((v2Body?["fields"] as? [[String: Any]])?.first?["key"] as? String == "providerId")
            #expect((v2Body?["fields"] as? [[String: Any]])?.contains { $0["key"] as? String == "model" } == true)
            let v2Source = try await get(owner, "\(base)/runtime-forms/v2/builtin/option-sources/provider")
            #expect(v2Source.status == .ok)
            #expect(try JSONSerialization.jsonObject(with: Data((v2Source.body.string ?? "").utf8)) as? [String: Any] != nil)

            let zh = try await get(owner, "\(base)/runtime-forms/v2/builtin", language: "zh-CN,zh;q=0.9")
            #expect(zh.status == .ok)
            #expect(zh.headers[HTTPField.Name("Content-Language")!] == "zh-CN")
            let zhBody = try JSONSerialization.jsonObject(with: Data((zh.body.string ?? "").utf8)) as? [String: Any]
            #expect((zhBody?["fields"] as? [[String: Any]])?.first?["label"] as? String == "提供方")
        }
    }
}
