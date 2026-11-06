import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct FormCatalogFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let machineId: String
}

private final class RuntimeProbeRecorder: @unchecked Sendable {
    var probe: RuntimeModelProbeOutcome = .missingConfig
    var routedLocally = true
    var calls: [(runtime: String, force: Bool)] = []
}

private func makeFormCatalogFixture(suffix: String, runtimes: [String]) -> FormCatalogFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 900_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 900_000 + number)
    let ownerEmail = "form-catalog-owner-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "form-catalog-\(suffix)", name: "Form Catalog", ownerId: ownerId)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "form-catalog-\(suffix)")
    accounts.setMachineRuntimesForTesting(machineId: machine, runtimes: runtimes)
    return FormCatalogFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        machineId: machine
    )
}

private func formCatalogLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func formCatalogHeaders(_ token: String, _ serverId: String, v2: Bool = false) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    if v2 { headers[HTTPField.Name("X-Raft-Runtime-Form-V2")!] = "1" }
    return headers
}

private func formCatalogObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func runtimeFormURL(_ fixture: FormCatalogFixture, _ runtime: String) -> String {
    "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-forms/v2/\(runtime)"
}

private func optionSourceURL(_ fixture: FormCatalogFixture, _ runtime: String, _ source: String) -> String {
    "\(runtimeFormURL(fixture, runtime))/option-sources/\(source)"
}

private func v1FormURL(_ fixture: FormCatalogFixture, _ runtime: String) -> String {
    "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-form-definitions/\(runtime)?schemaVersion=\(runtime).create.v1"
}

private func v1SourceURL(_ fixture: FormCatalogFixture, _ runtime: String, _ source: String) -> String {
    "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-form-definitions/\(runtime)/option-sources/\(source)?schemaVersion=\(runtime).create.v1"
}

@Test func piServesItsV2FormBehindTheOptInMarkerOnly() async throws {
    let fixture = makeFormCatalogFixture(suffix: "1201", runtimes: ["pi"])
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await formCatalogLogin(client, email: fixture.ownerEmail)
            let optionsPath = "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-options"
            let optedIn = try await client.get(URI(string: optionsPath), headers: formCatalogHeaders(token, fixture.serverId, v2: true))
            let rows = try formCatalogObject(optedIn)["options"] as? [[String: Any]] ?? []
            let piRow = try #require(rows.first { $0["runtimeId"] as? String == "pi" })
            #expect(piRow["runtimeFormV2"] as? NSDictionary == ["protocolVersion": 2] as NSDictionary)
            #expect(piRow["formDefinitionRef"] == nil)

            let strict = try await client.get(URI(string: optionsPath), headers: formCatalogHeaders(token, fixture.serverId))
            let strictRow = try #require((try formCatalogObject(strict)["options"] as? [[String: Any]] ?? []).first { $0["runtimeId"] as? String == "pi" })
            #expect(strictRow["runtimeFormV2"] == nil)

            let form = try await client.get(URI(string: runtimeFormURL(fixture, "pi")), headers: formCatalogHeaders(token, fixture.serverId))
            #expect(form.status == .ok)
            let body = try formCatalogObject(form)
            #expect(body["protocolVersion"] as? Int == 2)
            #expect(body["runtimeId"] as? String == "pi")
            #expect(body["schemaVersion"] as? String == "pi.create.v1")
            #expect(body["requiredClientCapabilities"] as? [String] == [
                "select.custom_value", "choice.labels", "option_source.status",
            ])
            let dataSchema = try #require(body["dataSchema"] as? [String: Any])
            #expect(dataSchema["required"] as? [String] == ["provider", "model", "providerModel"])
            let properties = dataSchema["properties"] as? [String: Any] ?? [:]
            #expect(properties["provider"] != nil)
            #expect(properties["apiKey"] != nil)
            #expect(properties["providerModel"] != nil)
            #expect((body["optionSources"] as? [String: Any])?["provider"] != nil)

            let provider = try await client.get(URI(string: optionSourceURL(fixture, "pi", "provider")), headers: formCatalogHeaders(token, fixture.serverId))
            #expect(provider.status == .ok)
            #expect(try formCatalogObject(provider) as NSDictionary == [
                "protocolVersion": 1,
                "runtimeId": "pi",
                "schemaVersion": "pi.create.v1",
                "sourceId": "provider",
                "kind": "select",
                "pointer": "/provider",
                "options": [
                    ["value": "configured", "label": "Configured"],
                    ["value": "deepseek", "label": "DeepSeek"],
                ],
                "defaultValue": "configured",
                "customValueAllowed": false,
            ] as NSDictionary)

            for path in [v1FormURL(fixture, "pi"), v1SourceURL(fixture, "pi", "provider")] {
                let v1 = try await client.get(URI(string: path), headers: formCatalogHeaders(token, fixture.serverId))
                #expect(v1.status == .notFound)
                #expect(try formCatalogObject(v1)["issues"] as? NSArray == [[
                    "code": "unknown_form_runtime", "pointer": "/runtimeId",
                ]] as NSArray)
            }
        }
    }
}

@Test func openCodeKimiGeminiAndAntigravityOptionSourcesStayInTheirLanes() async throws {
    let fixture = makeFormCatalogFixture(suffix: "1202", runtimes: ["opencode", "kimi", "gemini", "antigravity"])
    let recorder = RuntimeProbeRecorder()
    recorder.probe = .live(
        models: [
            RuntimeModelProbeModel(id: "a/one", label: "One"),
            RuntimeModelProbeModel(id: "b/two", label: "Two"),
        ],
        default: "b/two"
    )
    fixture.accounts.machineRuntimeModelProbe = { _, runtime, force in
        recorder.calls.append((runtime, force))
        return recorder.probe
    }
    fixture.accounts.machineRoutedLocally = { _ in recorder.routedLocally }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await formCatalogLogin(client, email: fixture.ownerEmail)
            let headers = formCatalogHeaders(token, fixture.serverId)

            let form = try await client.get(URI(string: runtimeFormURL(fixture, "opencode")), headers: headers)
            #expect(form.status == .ok)
            let formBody = try formCatalogObject(form)
            #expect(formBody["protocolVersion"] as? Int == 2)
            #expect(formBody["runtimeId"] as? String == "opencode")
            #expect(formBody["schemaVersion"] as? String == "opencode.create.v1")
            #expect((formBody["optionSources"] as? [String: Any])?["model"] != nil)

            let live = try await client.get(URI(string: optionSourceURL(fixture, "opencode", "model")), headers: headers)
            #expect(live.status == .ok)
            let liveBody = try formCatalogObject(live)
            #expect(liveBody["options"] as? NSArray == [
                ["value": "a/one", "label": "One"],
                ["value": "b/two", "label": "Two"],
            ] as NSArray)
            #expect(liveBody["defaultValue"] as? String == "b/two")
            #expect(recorder.calls.map(\.force) == [false])

            _ = try await client.get(URI(string: optionSourceURL(fixture, "opencode", "model") + "?refresh=1"), headers: headers)
            #expect(recorder.calls.map(\.force) == [false, true])

            recorder.probe = .missingConfig
            let fallback = try await client.get(URI(string: optionSourceURL(fixture, "opencode", "model")), headers: headers)
            #expect(fallback.status == .ok)
            let fallbackBody = try formCatalogObject(fallback)
            #expect(fallbackBody["defaultValue"] as? String == "default")
            #expect((fallbackBody["options"] as? [[String: Any]] ?? []).map { $0["value"] as? String } == [
                "default", "deepseek/deepseek-v4-pro",
                "openrouter/anthropic/claude-opus-4.5", "fusecode/opus[1m]",
            ])
            #expect(fallbackBody["status"] == nil)

            recorder.calls.removeAll()
            let kimi = try await client.get(URI(string: optionSourceURL(fixture, "kimi", "model")), headers: headers)
            #expect(kimi.status == .ok)
            #expect(try formCatalogObject(kimi) as NSDictionary == [
                "protocolVersion": 1,
                "runtimeId": "kimi",
                "schemaVersion": "kimi.edit.v1",
                "sourceId": "model",
                "kind": "select",
                "pointer": "/model",
                "options": [["value": "default", "label": "Configured Default"]],
                "defaultValue": "default",
            ] as NSDictionary)

            let gemini = try await client.get(URI(string: optionSourceURL(fixture, "gemini", "model")), headers: headers)
            #expect(gemini.status == .ok)
            #expect((try formCatalogObject(gemini)["options"] as? [[String: Any]] ?? []).map { $0["value"] as? String } == [
                "default", "gemini-3.1-pro-preview", "gemini-3-flash-preview", "gemini-2.5-pro", "gemini-2.5-flash",
            ])
            #expect(recorder.calls.isEmpty)

            let antigravity = try await client.get(URI(string: optionSourceURL(fixture, "antigravity", "model")), headers: headers)
            #expect(antigravity.status == .notFound)
            #expect(try formCatalogObject(antigravity)["issues"] as? NSArray == [[
                "code": "unknown_option_source", "pointer": "/sourceId",
            ]] as NSArray)

            for runtime in ["opencode", "kimi", "gemini", "antigravity"] {
                for path in [v1FormURL(fixture, runtime), v1SourceURL(fixture, runtime, "model")] {
                    let v1 = try await client.get(URI(string: path), headers: headers)
                    #expect(v1.status == .notFound)
                    #expect(try formCatalogObject(v1)["issues"] as? NSArray == [[
                        "code": "unknown_form_runtime", "pointer": "/runtimeId",
                    ]] as NSArray)
                }
            }
        }
    }
}

@Test func codexAndGrokReportOptionSourceStatusAcrossProbeOutcomes() async throws {
    let fixture = makeFormCatalogFixture(suffix: "1203", runtimes: ["codex", "grok", "opencode"])
    let recorder = RuntimeProbeRecorder()
    fixture.accounts.machineRuntimeModelProbe = { _, runtime, force in
        recorder.calls.append((runtime, force))
        return recorder.probe
    }
    fixture.accounts.machineRoutedLocally = { _ in recorder.routedLocally }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await formCatalogLogin(client, email: fixture.ownerEmail)
            let headers = formCatalogHeaders(token, fixture.serverId)

            recorder.probe = .missingConfig
            let codexFallback = try await client.get(URI(string: optionSourceURL(fixture, "codex", "model")), headers: headers)
            #expect(codexFallback.status == .ok)
            let codexBody = try formCatalogObject(codexFallback)
            #expect(codexBody["status"] as? String == "fallback")
            #expect(codexBody["reason"] as? String == "missing_config")
            #expect(codexBody["retryable"] as? Bool == false)
            #expect(codexBody["customValueAllowed"] as? Bool == true)
            #expect(codexBody["defaultValue"] as? String == "gpt-6.1-sol")
            #expect((codexBody["options"] as? [[String: Any]] ?? []).count == 17)

            let grokFallback = try await client.get(URI(string: optionSourceURL(fixture, "grok", "model")), headers: headers)
            let grokBody = try formCatalogObject(grokFallback)
            #expect(grokBody["status"] as? String == "fallback")
            #expect(grokBody["reason"] as? String == "missing_config")
            #expect(grokBody["retryable"] as? Bool == false)
            #expect(grokBody["customValueAllowed"] == nil)
            #expect((grokBody["options"] as? [[String: Any]] ?? []).map { $0["value"] as? String } == [
                "grok-4.5", "grok-4.6", "grok-composer-2.5-fast",
            ])

            recorder.probe = .live(models: [RuntimeModelProbeModel(id: "gpt-7-preview", label: "GPT-7 Preview")], default: nil)
            recorder.calls.removeAll()
            let retried = try await client.get(URI(string: optionSourceURL(fixture, "codex", "model") + "?refresh=1"), headers: headers)
            let retriedBody = try formCatalogObject(retried)
            #expect(retriedBody["status"] as? String == "live")
            #expect((retriedBody["options"] as? [[String: Any]] ?? []).map { $0["value"] as? String } == ["gpt-7-preview"])
            #expect(recorder.calls.map(\.force) == [true])

            for outcome in [
                RuntimeModelProbeOutcome.unsupported,
                .error(code: "detect_timeout", retryable: true),
                .failed,
            ] {
                recorder.probe = outcome
                let response = try await client.get(URI(string: optionSourceURL(fixture, "grok", "model")), headers: headers)
                let body = try formCatalogObject(response)
                let expectedReason = outcome == .unsupported ? "unsupported"
                    : outcome == .failed ? "probe_failed" : "probe_timeout"
                let expectedRetryable = expectedReason != "unsupported"
                #expect(body["status"] as? String == "fallback")
                #expect(body["reason"] as? String == expectedReason)
                #expect(body["retryable"] as? Bool == expectedRetryable)
                #expect(body["customValueAllowed"] == nil)
            }

            recorder.routedLocally = false
            recorder.calls.removeAll()
            let offline = try await client.get(URI(string: optionSourceURL(fixture, "codex", "model")), headers: headers)
            let offlineBody = try formCatalogObject(offline)
            #expect(offlineBody["status"] as? String == "fallback")
            #expect(offlineBody["reason"] as? String == "machine_offline")
            #expect(offlineBody["retryable"] as? Bool == true)
            #expect(recorder.calls.isEmpty)
            recorder.routedLocally = true

            for runtime in ["codex", "grok"] {
                for path in [v1FormURL(fixture, runtime), v1SourceURL(fixture, runtime, "model")] {
                    let v1 = try await client.get(URI(string: path), headers: headers)
                    #expect(v1.status == .notFound)
                    #expect(try formCatalogObject(v1)["issues"] as? NSArray == [[
                        "code": "unknown_form_runtime", "pointer": "/runtimeId",
                    ]] as NSArray)
                }
            }
        }
    }
}

@Test func kimiSDKOffersTheManagedDefaultAndKeepsV1FailuresTyped() async throws {
    let fixture = makeFormCatalogFixture(suffix: "1204", runtimes: ["kimi-sdk"])
    let recorder = RuntimeProbeRecorder()
    fixture.accounts.machineRuntimeModelProbe = { _, _, _ in recorder.probe }
    fixture.accounts.machineRoutedLocally = { _ in recorder.routedLocally }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await formCatalogLogin(client, email: fixture.ownerEmail)
            let headers = formCatalogHeaders(token, fixture.serverId)
            let source = v1SourceURL(fixture, "kimi-sdk", "model")

            recorder.probe = .missingConfig
            let fallback = try await client.get(URI(string: source), headers: headers)
            #expect(fallback.status == .ok)
            let fallbackBody = try formCatalogObject(fallback)
            #expect(fallbackBody["options"] as? NSArray == [
                ["value": "kimi-code/kimi-for-coding", "label": "Kimi for Coding (default)"],
            ] as NSArray)
            #expect(fallbackBody["defaultValue"] as? String == "kimi-code/kimi-for-coding")
            #expect(fallbackBody["status"] == nil)

            recorder.probe = .error(code: "computer_offline", retryable: true)
            let offline = try await client.get(URI(string: source), headers: headers)
            #expect(offline.status == .ok)
            #expect(try formCatalogObject(offline)["defaultValue"] as? String == "kimi-code/kimi-for-coding")

            recorder.probe = .error(code: "", retryable: true)
            let failed = try await client.get(URI(string: source), headers: headers)
            #expect(failed.status == .conflict)
            #expect(try formCatalogObject(failed)["issues"] as? NSArray == [[
                "code": "runtime_model_source_error", "pointer": "/optionSources/model",
            ]] as NSArray)

            recorder.probe = .noModels
            let empty = try await client.get(URI(string: source), headers: headers)
            #expect(empty.status == .conflict)
            #expect(try formCatalogObject(empty)["issues"] as? NSArray == [[
                "code": "runtime_model_source_no_models", "pointer": "/optionSources/model",
            ]] as NSArray)

            recorder.probe = .unsupported
            let unsupported = try await client.get(URI(string: source), headers: headers)
            #expect(unsupported.status == .conflict)
            #expect(try formCatalogObject(unsupported)["issues"] as? NSArray == [[
                "code": "runtime_model_source_unsupported", "pointer": "/optionSources/model",
            ]] as NSArray)

            recorder.probe = .live(
                models: [
                    RuntimeModelProbeModel(
                        id: "kimi-code/k3",
                        label: "K3",
                        supportedReasoningEfforts: ["balanced-plus"],
                        defaultReasoningEffort: "balanced-plus"
                    ),
                    RuntimeModelProbeModel(id: "kimi-code/k2", label: "K2"),
                ],
                default: "kimi-code/k3"
            )
            let live = try await client.get(URI(string: source), headers: headers)
            #expect(live.status == .ok)
            let liveBody = try formCatalogObject(live)
            #expect(liveBody["options"] as? NSArray == [
                [
                    "value": "kimi-code/k3", "label": "K3",
                    "supportedReasoningEfforts": ["balanced-plus"],
                    "defaultReasoningEffort": "balanced-plus",
                ],
                ["value": "kimi-code/k2", "label": "K2"],
            ] as NSArray)
            #expect(liveBody["status"] == nil)

            let definition = try await client.get(
                URI(string: "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-form-definitions/kimi-sdk?schemaVersion=kimi-sdk.create.v1"),
                headers: headers
            )
            #expect(definition.status == .ok)
            let definitionBody = try formCatalogObject(definition)
            #expect(definitionBody["runtimeId"] as? String == "kimi-sdk")
            #expect((definitionBody["dataSchema"] as? [String: Any])?["required"] as? [String] == ["model"])
            #expect(Set((definitionBody["optionSources"] as? [String: Any] ?? [:]).keys) == Set(["model"]))

            let optionsPath = "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-options"
            let v1Row = try #require((try formCatalogObject(try await client.get(URI(string: optionsPath), headers: headers))["options"] as? [[String: Any]] ?? []).first { $0["runtimeId"] as? String == "kimi-sdk" })
            #expect(v1Row["formDefinitionRef"] as? NSDictionary == [
                "protocolVersion": 1, "runtimeId": "kimi-sdk", "schemaVersion": "kimi-sdk.create.v1",
            ] as NSDictionary)
            let v2Row = try #require((try formCatalogObject(try await client.get(URI(string: optionsPath), headers: formCatalogHeaders(token, fixture.serverId, v2: true)))["options"] as? [[String: Any]] ?? []).first { $0["runtimeId"] as? String == "kimi-sdk" })
            #expect(v2Row["runtimeFormV2"] as? NSDictionary == ["protocolVersion": 2] as NSDictionary)
            #expect(v2Row["formDefinitionRef"] == nil)
        }
    }
}

@Test func builtinAndKimiV2SourcesReportStatusInsteadOfHardFailures() async throws {
    let fixture = makeFormCatalogFixture(suffix: "1205", runtimes: ["builtin", "kimi-sdk"])
    let recorder = RuntimeProbeRecorder()
    fixture.accounts.machineRuntimeModelProbe = { _, _, _ in recorder.probe }
    fixture.accounts.machineRoutedLocally = { _ in recorder.routedLocally }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await formCatalogLogin(client, email: fixture.ownerEmail)
            let headers = formCatalogHeaders(token, fixture.serverId)
            let kimi = optionSourceURL(fixture, "kimi-sdk", "model")
            let builtin = optionSourceURL(fixture, "builtin", "model")

            for runtime in ["kimi-sdk", "builtin"] {
                let form = try await client.get(URI(string: runtimeFormURL(fixture, runtime)), headers: headers)
                #expect(form.status == .ok)
                let capabilities = try formCatalogObject(form)["requiredClientCapabilities"] as? [String] ?? []
                #expect(capabilities.contains("option_source.status"))
            }

            recorder.probe = .missingConfig
            let missing = try formCatalogObject(try await client.get(URI(string: kimi), headers: headers))
            #expect(missing["status"] as? String == "fallback")
            #expect(missing["reason"] as? String == "missing_config")
            #expect(missing["retryable"] as? Bool == false)
            #expect(missing["defaultValue"] as? String == "kimi-code/kimi-for-coding")

            recorder.probe = .error(code: "computer_offline", retryable: true)
            let offline = try formCatalogObject(try await client.get(URI(string: kimi), headers: headers))
            #expect(offline["status"] as? String == "fallback")
            #expect(offline["reason"] as? String == "machine_offline")
            #expect(offline["retryable"] as? Bool == true)

            for (probe, reason, retryable) in [
                (RuntimeModelProbeOutcome.error(code: "", retryable: true), "probe_failed", true),
                (.error(code: "detect_timeout", retryable: true), "probe_timeout", true),
                (.noModels, "no_models", true),
                (.unsupported, "unsupported", false),
            ] {
                recorder.probe = probe
                let body = try formCatalogObject(try await client.get(URI(string: kimi), headers: headers))
                #expect(body["status"] as? String == "unavailable")
                #expect(body["reason"] as? String == reason)
                #expect(body["retryable"] as? Bool == retryable)
                #expect(body["options"] as? [Any] != nil)
                #expect((body["options"] as? [Any])?.isEmpty == true)
            }

            recorder.probe = .live(models: [RuntimeModelProbeModel(id: "kimi-code/k3", label: "K3")], default: "kimi-code/k3")
            let liveKimi = try formCatalogObject(try await client.get(URI(string: kimi), headers: headers))
            #expect(liveKimi["status"] as? String == "live")
            #expect(liveKimi["reason"] == nil)

            let live = try formCatalogObject(try await client.get(URI(string: builtin), headers: headers))
            #expect(live["status"] as? String == "live")
            let provider = try formCatalogObject(try await client.get(URI(string: optionSourceURL(fixture, "builtin", "provider")), headers: headers))
            #expect(provider["status"] == nil)

            fixture.accounts.builtinCatalogMode = "offline"
            let bundled = try formCatalogObject(try await client.get(URI(string: builtin), headers: headers))
            #expect(bundled["status"] as? String == "fallback")
            #expect(bundled["reason"] as? String == "machine_offline")
            #expect(((bundled["optionsByValue"] as? [String: Any])?["deepseek"] as? [[String: Any]] ?? []).isEmpty == false)

            fixture.accounts.builtinCatalogMode = "timeout"
            let timedOut = try await client.get(URI(string: builtin), headers: headers)
            #expect(timedOut.status == .ok)
            let timedOutBody = try formCatalogObject(timedOut)
            #expect(timedOutBody["status"] as? String == "unavailable")
            #expect(timedOutBody["reason"] as? String == "probe_timeout")
            #expect(timedOutBody["retryable"] as? Bool == true)
            #expect((timedOutBody["optionsByValue"] as? [String: Any])?.isEmpty == true)

            fixture.accounts.builtinCatalogMode = "legacy"
            let legacy = try await client.get(URI(string: builtin), headers: headers)
            #expect(legacy.status == .conflict)
            #expect(try formCatalogObject(legacy)["code"] as? String == "builtin_catalog_capability_required")

            fixture.accounts.builtinCatalogMode = "timeout"
            let v1Builtin = try await client.get(
                URI(string: "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-form-definitions/builtin/option-sources/model?schemaVersion=builtin-pi.create.v3"),
                headers: headers
            )
            #expect(v1Builtin.status == .conflict)
            #expect(try formCatalogObject(v1Builtin)["issues"] as? NSArray == [[
                "code": "builtin_catalog_unavailable", "pointer": "/optionSources/model",
            ]] as NSArray)
        }
    }
}
