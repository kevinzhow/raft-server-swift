import Foundation
import HTTPTypes
import RaftHTTPServer
import RaftShared
import TestSupport
import Testing
import Vapor
import VaporTesting
@testable import RaftHTTP

private func builtinGolden(_ name: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

/// Public HTTP only; the declared offline catalog is not a live Computer or a
/// provider acceptance proof. The parser's exact schema/ref inputs are golden.
@Test func builtinV2BaseSchemaSourcesAndFormOnlyWritesFollowTheWebContract() async throws {
    let accounts = EmailLoginDirectory()
    let owner = "11111111-1111-4111-8111-000001110001"
    let member = "11111111-1111-4111-8111-000001110002"
    let server = "33333333-3333-4333-8333-000001110001"
    let otherServer = "33333333-3333-4333-8333-000001110002"
    for (id, email) in [(owner, "builtin-v2-owner@slock.test"), (member, "builtin-v2-member@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: server, slug: "builtin-v2", name: "Builtin V2", ownerId: owner)
    accounts.oauth.addMember(serverId: server, userId: member, role: "member")
    accounts.oauth.addOwnedServer(id: otherServer, slug: "builtin-v2-other", name: "Other", ownerId: owner)
    let machine = accounts.registerMachine(serverId: server, userId: owner, name: "Builtin V2 declared metadata")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var h = HTTPFields(); h[.contentType] = "application/json"
                let r = try await client.send(.post, headers: h, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                let object = try JSONSerialization.jsonObject(with: Data((r.body.string ?? "").utf8)) as? [String: Any]
                return try #require(object?["accessToken"] as? String)
            }
            let token = try await login("builtin-v2-owner@slock.test")
            let memberToken = try await login("builtin-v2-member@slock.test")
            func headers(_ bearer: String, serverID: String? = nil) -> HTTPFields {
                var h = HTTPFields(); h[.authorization] = "Bearer \(bearer)"; h[.contentType] = "application/json"
                h[HTTPField.Name("X-Server-Id")!] = serverID ?? server
                return h
            }
            func post(_ body: [String: JSONValue]) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(token), to: "/api/agents") { request in
                    request.body = .init(string: try JSONValue.object(body).string())
                }
            }
            func patch(_ id: String, _ body: [String: JSONValue], bearer: String? = nil, scope: String? = nil) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers(bearer ?? token, serverID: scope), to: "/api/agents/\(id)") { request in
                    request.body = .init(string: try JSONValue.object(body).string())
                }
            }
            func object(_ response: ClientResponse) throws -> [String: Any] {
                try #require(JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
            }
            let base = "/api/servers/\(server)/machines/\(machine)/runtime-forms/v2/builtin"
            let definition = try await client.get(URI(string: base), headers: headers(token))
            #expect(definition.status == .ok)
            let definitionBody = try object(definition)
            let golden = try builtinGolden("builtin-v2.form.json")
            #expect(NSDictionary(dictionary: definitionBody) == NSDictionary(dictionary: golden))
            #expect(definitionBody["fields"] == nil && definitionBody["revision"] == nil)
            #expect(definitionBody["requiredClientCapabilities"] as? [String] == ["option_source.status"])
            // These are the actual parseRuntimeFormV2 preconditions and source
            // descriptors; fields-list lookalikes never satisfy them.
            let properties = try #require((definitionBody["dataSchema"] as? [String: Any])?["properties"] as? [String: Any])
            let refs = try #require(definitionBody["optionSources"] as? [String: [String: Any]])
            #expect((properties["providerId"] as? [String: Any])?["x-optionSource"] as? String == "provider")
            #expect(refs["provider"]?["kind"] as? String == "select" && refs["provider"]?["pointer"] as? String == "/providerId")
            #expect(refs["model"]?["kind"] as? String == "dependent_select" && refs["model"]?["dependsOn"] as? String == "/providerId")
            let sourceGolden = try builtinGolden("builtin-v2.sources.json")
            let providers = try await client.get(URI(string: base + "/option-sources/provider"), headers: headers(token))
            #expect(providers.status == .ok)
            #expect(NSDictionary(dictionary: try object(providers)) == NSDictionary(dictionary: try #require(sourceGolden["provider"] as? [String: Any])))
            let models = try await client.get(URI(string: base + "/option-sources/model"), headers: headers(token))
            #expect(models.status == .ok)
            var modelGolden = try #require(sourceGolden["model"] as? [String: Any])
            modelGolden["status"] = "fallback"; modelGolden["reason"] = "machine_offline"; modelGolden["retryable"] = true
            #expect(NSDictionary(dictionary: try object(models)) == NSDictionary(dictionary: modelGolden))

            for (providerID, modelID) in (try #require(modelGolden["defaultValueByValue"] as? [String: String])).sorted(by: { $0.key < $1.key }) {
                let presetCreated = try await post(["name": .string("preset-\(providerID)"), "formDefinitionRef": .object(["protocolVersion": .integer(2), "runtimeId": .string("builtin")]),
                    "formValues": .object(["providerId": .string(providerID), "apiKey": .string("test-direct-key"), "model": .string(modelID)])])
                #expect(presetCreated.status == .ok)
                let presetID = try #require(try object(presetCreated)["id"] as? String)
                let presetEdit = try await client.get(URI(string: "/api/agents/\(presetID)/runtime-form"), headers: headers(token))
                let presetValues = try #require(try object(presetEdit)["values"] as? [String: Any])
                #expect(presetValues["providerId"] as? String == providerID && presetValues["model"] as? String == modelID)
                #expect(presetValues["apiKey"] == nil && presetValues["baseUrl"] == nil && presetValues["supportsImageInput"] == nil)
            }
            let ref: JSONValue = .object(["protocolVersion": .integer(2), "runtimeId": .string("builtin")])
            let secret = "test-only-builtin-direct-key"
            var values: [String: JSONValue] = ["providerId": .string("openai-compatible"), "apiKey": .string(" \(secret) "),
                "baseUrl": .string("https://gateway.example.test/v1"), "supportsImageInput": .bool(true),
                "model": .string("org/custom-model"), "loadLocalPlugins": .bool(true), "envVars": .object(["KEEP": .string("1"), "OPENAI_API_KEY": .string("must-not-survive")])]
            let created = try await post(["name": .string("builtin-form-only"), "runtime": .string("codex"), "model": .string("legacy-ignored"),
                "runtimeConfig": .object(["runtime": .string("codex")]), "formDefinitionRef": ref, "formValues": .object(values)])
            #expect(created.status == .ok)
            let id = try #require(try object(created)["id"] as? String)
            let detail = try await client.get(URI(string: "/api/agents/\(id)"), headers: headers(token))
            #expect(detail.status == .ok)
            #expect((try object(detail))["runtime"] as? String == "builtin")
            #expect(!(detail.body.string ?? "").contains(secret))
            let stored = try #require(accounts.oauth.agentRuntimeInfo(id: id)?.runtimeConfigJSON)
            let storedObject = try JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any]
            #expect((storedObject?["provider"] as? [String: Any])?["apiKey"] as? String == secret)
            #expect((storedObject?["provider"] as? [String: Any])?["supportsImageInput"] as? Bool == true)
            #expect(storedObject?["loadLocalPlugins"] as? Bool == true)
            #expect((storedObject?["envVars"] as? [String: String]) == ["KEEP": "1"])
            let edit = try await client.get(URI(string: "/api/agents/\(id)/runtime-form"), headers: headers(token))
            #expect(edit.status == .ok && !(edit.body.string ?? "").contains(secret))
            let editObject = try object(edit)
            #expect(NSDictionary(dictionary: try #require(editObject["dataSchema"] as? [String: Any])) == NSDictionary(dictionary: try #require(golden["dataSchema"] as? [String: Any])))
            #expect(editObject["writeOnlyKeepRequiresUnchanged"] as? [String: [String]] == ["/apiKey": ["/providerId", "/baseUrl"]])
            let editValues = try #require(editObject["values"] as? [String: Any])
            #expect(editValues["providerId"] as? String == "openai-compatible" && editValues["apiKey"] == nil)
            #expect(editValues["baseUrl"] as? String == "https://gateway.example.test/v1" && editValues["loadLocalPlugins"] as? Bool == true)
            values["apiKey"] = .string(""); values["envVars"] = .object(["KEEP": .string("1")])
            let unchanged = try await patch(id, ["formDefinitionRef": ref, "formValues": .object(values)])
            #expect(unchanged.status == .ok)
            #expect(accounts.oauth.agentRuntimeInfo(id: id)?.runtimeConfigJSON == stored)
            values["model"] = .string("org/next-model"); values["loadLocalPlugins"] = .bool(false)
            let changed = try await patch(id, ["formDefinitionRef": ref, "formValues": .object(values), "model": .string("legacy-ignored")])
            #expect(changed.status == .ok)
            let changedEdit = try await client.get(URI(string: "/api/agents/\(id)/runtime-form"), headers: headers(token))
            #expect((try object(changedEdit)["values"] as? [String: Any])?["model"] as? String == "org/next-model")
            let accepted = accounts.oauth.agentRuntimeInfo(id: id)?.runtimeConfigJSON
            values["baseUrl"] = .string("https://different.example.test/v1")
            let moved = try await patch(id, ["formDefinitionRef": ref, "formValues": .object(values)])
            #expect(moved.status == .badRequest)
            #expect(NSDictionary(dictionary: try object(moved)) == NSDictionary(dictionary: ["error": "runtimeConfig.provider.apiKey is required"]))
            #expect(accounts.oauth.agentRuntimeInfo(id: id)?.runtimeConfigJSON == accepted)
            #expect(try await patch(id, ["formDefinitionRef": ref, "formValues": .object(values)], bearer: memberToken).status == .forbidden)
            #expect(try await patch(id, ["formDefinitionRef": ref, "formValues": .object(values)], scope: otherServer).status == .notFound)
            let foreignEdit = try await client.get(URI(string: "/api/agents/\(id)/runtime-form"), headers: headers(token, serverID: otherServer))
            #expect(foreignEdit.status == .notFound)

            func invalid(_ badValues: JSONValue?, reference: JSONValue? = nil) async throws -> [String: Any] {
                var body: [String: JSONValue] = ["name": .string("bad-\(UUID().uuidString.prefix(8))"), "runtime": .string("builtin"), "formDefinitionRef": reference ?? ref]
                if let badValues { body["formValues"] = badValues }
                let reply = try await post(body); #expect(reply.status == .badRequest)
                return try object(reply)
            }
            let preset: [String: JSONValue] = ["providerId": .string("deepseek"), "apiKey": .string("test-key"), "model": .string("deepseek/deepseek-v4-pro")]
            for (bad, code, pointer) in [
                (nil as JSONValue?, "form_values_required", "/formValues"),
                (.object(["providerId": .string("nope")]), "select_valid_provider", "/formValues/providerId"),
                (.object(["providerId": .string("deepseek"), "model": .string("deepseek/deepseek-v4-pro")]), "api_key_required", "/formValues/apiKey"),
                (.object(preset.merging(["model": .string("unknown")]) { _, b in b }), "select_valid_provider_model", "/formValues/model"),
                (.object(preset.merging(["envVars": .object(["X": .integer(1)])]) { _, b in b }), "invalid_string_map", "/formValues/envVars")
            ] {
                let error = try await invalid(bad)
                #expect(error["issues"] as? [[String: String]] == [["code": code, "pointer": pointer]])
            }
            // The v2 builder checks map shape before fields, then ordinary
            // canonical validation checks names/NUL after provider/model/URL.
            for (env, message) in [
                (["BAD-KEY": JSONValue.string("x")], "Invalid runtimeConfig.envVars key \"BAD-KEY\": must match [A-Za-z_][A-Za-z0-9_]*"),
                (["KEEP": JSONValue.string("a\0b")], "runtimeConfig.envVars keys and values must not contain null bytes")
            ] {
                let rejectedCreate = try await invalid(.object(preset.merging(["envVars": .object(env)]) { _, b in b }))
                #expect(NSDictionary(dictionary: rejectedCreate) == NSDictionary(dictionary: ["error": "Runtime configuration is invalid",
                    "issues": [["code": "invalid_runtime_config", "pointer": "/formValues"]]]))
                let rejectedPatch = try await patch(id, ["formDefinitionRef": ref, "formValues": .object(values.merging([
                    "apiKey": .string("replacement-test-key"), "baseUrl": .string("https://gateway.example.test/v1"), "envVars": .object(env)
                ]) { _, b in b })])
                #expect(rejectedPatch.status == .badRequest)
                #expect(NSDictionary(dictionary: try object(rejectedPatch)) == NSDictionary(dictionary: ["error": message]))
                #expect(accounts.oauth.agentRuntimeInfo(id: id)?.runtimeConfigJSON == accepted)
            }
            let blankKeys = try await post(["name": .string("blank-rows-filtered"), "formDefinitionRef": ref,
                "formValues": .object(preset.merging(["envVars": .object(["": .integer(1), "  ": .null, "KEEP": .string("ok")])]) { _, b in b })])
            #expect(blankKeys.status == .ok)
            let blankID = try #require(try object(blankKeys)["id"] as? String)
            let blankEdit = try await client.get(URI(string: "/api/agents/\(blankID)/runtime-form"), headers: headers(token))
            #expect((try object(blankEdit)["values"] as? [String: Any])?["envVars"] as? [String: String] == ["KEEP": "ok"])
            for (url, error) in [("https://", "runtimeConfig.provider.baseUrl must be a valid URL"),
                                 ("https://user:password@gateway.example.test/v1", "runtimeConfig.provider.baseUrl must not contain credentials")] {
                let input = values.merging(["apiKey": .string("replacement-test-key"), "baseUrl": .string(url)]) { _, b in b }
                let badCreate = try await invalid(.object(input))
                #expect(NSDictionary(dictionary: badCreate) == NSDictionary(dictionary: ["error": "Runtime configuration is invalid",
                    "issues": [["code": "invalid", "pointer": "/formValues/baseUrl"]]]))
                let badPatch = try await patch(id, ["formDefinitionRef": ref, "formValues": .object(input)])
                #expect(badPatch.status == .badRequest)
                #expect(NSDictionary(dictionary: try object(badPatch)) == NSDictionary(dictionary: ["error": error]))
                #expect(accounts.oauth.agentRuntimeInfo(id: id)?.runtimeConfigJSON == accepted)
            }
            let legacy = try await post(["name": .string("legacy-no-ref"), "runtime": .string("builtin"), "formValues": .object(preset)])
            #expect(legacy.status == .badRequest)
            #expect(NSDictionary(dictionary: try object(legacy)) == NSDictionary(dictionary: ["error": "runtimeConfig.provider is required for runtime: builtin"]))
            let badRef = try await invalid(.object(preset), reference: .object(["protocolVersion": .integer(2), "runtimeId": .string("unknown")]))
            #expect((badRef["issues"] as? [[String: String]])?.first?["code"] == "unknown_form_runtime")
            let connection = try await post(["name": .string("unsupported-saved"), "runtime": .string("builtin"), "formDefinitionRef": ref,
                "formValues": .object(["providerId": .string("connection:11111111-1111-4111-8111-000001110099"), "model": .string("deepseek/deepseek-v4-pro")])])
            #expect(connection.status == .notFound)
            #expect((try object(connection))["code"] as? String == "provider_connections_disabled")
        }
    }
}
