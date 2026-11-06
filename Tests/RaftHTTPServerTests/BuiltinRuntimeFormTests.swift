import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func builtinServesTheReleasedV1DefinitionAndLocalizedV2Form() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001021001"
    let ownerId = "11111111-1111-4111-8111-000001021001"
    let ownerEmail = "builtin-form-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "builtin-form", name: "Builtin Form", ownerId: ownerId)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "builtin-form-machine")
    accounts.setMachineRuntimesForTesting(machineId: machine, runtimes: ["builtin"])
    accounts.builtinCatalogMode = "supported"

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
                request.body = .init(string: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let base = "/api/servers/\(serverId)/machines/\(machine)"

            let definitionResponse = try await client.get(
                URI(string: "\(base)/runtime-form-definitions/builtin?schemaVersion=builtin-pi.create.v3"),
                headers: headers
            )
            #expect(definitionResponse.status == .ok)
            let definition = (try JSONSerialization.jsonObject(with: Data((definitionResponse.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(definition["protocolVersion"] as? Int == 1)
            #expect(definition["runtimeId"] as? String == "builtin")
            let schema = definition["dataSchema"] as? [String: Any] ?? [:]
            let properties = schema["properties"] as? [String: Any] ?? [:]
            #expect((properties["apiKey"] as? [String: Any])?["writeOnly"] as? Bool == true)
            #expect((properties["apiKey"] as? [String: Any])?["default"] == nil)
            #expect((properties["supportsImageInput"] as? [String: Any])?["type"] as? String == "boolean")
            #expect(schema["required"] as? [String] == ["providerId", "apiKey", "model"])
            let capabilities = definition["capabilities"] as? [String: Any] ?? [:]
            #expect(capabilities["writeOnlyPointers"] as? [String] == ["/apiKey"])
            #expect(capabilities["forbiddenPointers"] as? [String] == ["/hostUserState"])
            let sources = definition["optionSources"] as? [String: Any] ?? [:]
            #expect(Set(sources.keys) == Set(["provider", "model"]))

            let v2Response = try await client.get(URI(string: "\(base)/runtime-forms/v2/builtin"), headers: headers)
            #expect(v2Response.status == .ok)
            #expect(v2Response.headers[HTTPField.Name("Content-Language")!] == "en")
            let v2 = (try JSONSerialization.jsonObject(with: Data((v2Response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let fields = v2["fields"] as? [[String: Any]] ?? []
            #expect(fields.first { $0["key"] as? String == "providerId" }?["kind"] as? String == "select")
            #expect(fields.first { $0["key"] as? String == "providerId" }?["label"] as? String == "Provider")
            #expect(fields.first { $0["key"] as? String == "model" }?["kind"] as? String == "dependent_select")

            var zhHeaders = headers
            zhHeaders[HTTPField.Name("Accept-Language")!] = "zh-CN,zh;q=0.9,en;q=0.8"
            let zhResponse = try await client.get(URI(string: "\(base)/runtime-forms/v2/builtin"), headers: zhHeaders)
            #expect(zhResponse.status == .ok)
            #expect(zhResponse.headers[HTTPField.Name("Content-Language")!] == "zh-CN")
            #expect((zhResponse.headers[HTTPField.Name("Vary")!] ?? "").contains("Accept-Language"))
            let zh = (try JSONSerialization.jsonObject(with: Data((zhResponse.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let zhFields = zh["fields"] as? [[String: Any]] ?? []
            #expect(zhFields.first { $0["key"] as? String == "providerId" }?["label"] as? String == "提供方")

            let provider = try await client.get(URI(string: "\(base)/runtime-forms/v2/builtin/option-sources/provider"), headers: headers)
            #expect(provider.status == .ok)
            let providerBody = (try JSONSerialization.jsonObject(with: Data((provider.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(providerBody["kind"] as? String == "select")
            let options = providerBody["options"] as? [[String: Any]] ?? []
            #expect(options.contains { $0["value"] as? String == "deepseek" && $0["providerKind"] as? String == "preset" })

            let model = try await client.get(URI(string: "\(base)/runtime-form-definitions/builtin/option-sources/model?schemaVersion=builtin-pi.create.v3"), headers: headers)
            #expect(model.status == .ok)
            let modelBody = (try JSONSerialization.jsonObject(with: Data((model.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(modelBody["kind"] as? String == "dependent_select")
            #expect(((modelBody["optionsByValue"] as? [String: Any])?["deepseek"] as? [[String: Any]] ?? []).isEmpty == false)

            let stale = try await client.get(URI(string: "\(base)/runtime-form-definitions/builtin?schemaVersion=stale"), headers: headers)
            #expect(stale.status == .conflict)
            #expect(((try JSONSerialization.jsonObject(with: Data((stale.body.string ?? "").utf8))) as? [String: Any])?["issues"] as? NSArray == [["code": "stale_form_schema", "pointer": "/schemaVersion"]] as NSArray)
        }
    }
}
