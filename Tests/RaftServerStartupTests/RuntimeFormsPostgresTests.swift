import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RaftMachineSocket
import RaftShared
import Testing
@testable import RaftServer

private let runtimeFormsPGEnabled = ProcessInfo.processInfo.environment["RAFT_MACHINE_QUERY_PG_ACCEPTANCE"] == "1"

/// Controlled protocol inputs over real PG/HTTP/NIO. This does not attest to
/// installed CLIs, provider credentials, an official Computer, or a model turn.
@Test(.enabled(if: runtimeFormsPGEnabled), .serialized, .timeLimit(.minutes(4)))
func postgresRuntimeFormSourcesUseActualMachineQueries() async throws {
    guard let url = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_TEST_DATABASE_URL"], !url.isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    let fixture = try await AgentExecutionPostgresFixture.start(databaseURL: url)
    var machine: ControlledMachineProtocolPeer?
    do {
        let token = try await fixture.login(fixture.ownerEmail)
        let attachment = try await fixture.http("POST", "/api/computer/attach", token: token,
            body: .init(["serverSlug": .string(fixture.slug), "name": .string("Runtime forms protocol peer")]))
        try #require(attachment.status == 201)
        let machineId = try attachment.object().requireString("machineId")
        let peer = try await ControlledMachineProtocolPeer.connect(port: fixture.machineServer.port,
            key: attachment.object().requireString("apiKey"))
        machine = peer
        let runtimes = ["builtin", "kimi-sdk", "codex", "grok", "opencode", "kimi", "gemini", "antigravity", "pi"]
        try await peer.socket.send(.init([
            "type": .string("ready"), "daemonInstanceId": .string(peer.daemonId),
            "capabilities": .array(["agent:start", "agent:stop", "agent:deliver", "workspace:files", "agent:runtime-outcome-v1"].map(JSONValue.string)),
            "runtimes": .array(runtimes.map(JSONValue.string)), "runningAgents": .array([]),
            "runtimeDetection": .object(["status": .string("complete")]),
        ]))
        try await peer.socket.applicationFence()
        let wire = RuntimeFormsQueryWire(fixture: fixture, peer: peer, token: token, machineId: machineId)

        // Definitions and static sources remain available without a probe result.
        for runtime in runtimes {
            let definition = try await fixture.http("GET", wire.definition(runtime), token: token)
            #expect(definition.status == 200)
            #expect(try definition.object().integer("protocolVersion") == 2)
        }
        for runtime in ["opencode", "kimi", "gemini", "antigravity", "codex", "grok", "pi"] {
            let rejected = try await fixture.http("GET", wire.definition(runtime, version: 1), token: token)
            #expect(rejected.status == 404)
            #expect(try rejected.object().array("issues") == [.object([
                "code": .string("unknown_form_runtime"), "pointer": .string("/runtimeId"),
            ])])
        }
        let noAuth = try await fixture.http("GET", wire.source("codex"))
        #expect(noAuth.status == 401)
        let member = try await fixture.login(fixture.memberEmail)
        #expect(try await fixture.http("GET", wire.source("codex"), token: member).status == 403)

        let one = runtimeFormsModel("a/one", "One")
        let two = runtimeFormsModel("b/two", "Two")
        let openModels = runtimeFormsLive([one, two], defaultModel: "b/two")
        for refresh in [false, true] {
            let reply = try await wire.reply("opencode", refresh: refresh, outcome: openModels)
            #expect(reply.status == 200)
            let body = try reply.object()
            #expect(body.array("options") == [runtimeFormsOption("a/one", "One"), runtimeFormsOption("b/two", "Two")])
            #expect(body.string("defaultValue") == "b/two")
            #expect(body.fields["status"] == nil)
        }
        let openFallback = try await wire.reply("opencode", outcome: .object(["kind": .string("missing_config")]))
        #expect(openFallback.status == 200)
        #expect(try openFallback.object().string("defaultValue") == "default")
        #expect(try runtimeFormsValues(openFallback) == ["default", "deepseek/deepseek-v4-pro", "openrouter/anthropic/claude-opus-4.5", "fusecode/opus[1m]"])
        #expect(try openFallback.object().fields["status"] == nil)

        // The same raw live model/option inputs formerly supplied by the recorder.
        let codexLive = try await wire.reply("codex", refresh: true,
            outcome: runtimeFormsLive([runtimeFormsModel("gpt-7-preview", "GPT-7 Preview")]))
        try runtimeFormsStatus(codexLive, status: "live")
        #expect(try runtimeFormsValues(codexLive) == ["gpt-7-preview"])
        #expect(try codexLive.object().string("defaultValue") == "gpt-7-preview")
        #expect(try codexLive.object().bool("customValueAllowed") == true)
        // Carries ServerRuntimeUsageTests' former stored-cache positive to the wire.
        let usageLive = try await wire.reply("codex",
            outcome: runtimeFormsLive([runtimeFormsModel("gpt-5.4", "GPT 5.4")], defaultModel: "gpt-5.4"))
        try runtimeFormsStatus(usageLive, status: "live")
        #expect(try runtimeFormsValues(usageLive) == ["gpt-5.4"])
        #expect(try usageLive.object().bool("customValueAllowed") == true)

        let failures: [(JSONValue, String, Bool)] = [
            (.object(["kind": .string("missing_config")]), "missing_config", false),
            (.object(["kind": .string("no_models")]), "no_models", true),
            (.object(["kind": .string("unsupported")]), "unsupported", false),
            (runtimeFormsError("detect_timeout"), "probe_timeout", true),
            (runtimeFormsError("computer_offline"), "machine_offline", true),
            (runtimeFormsError("probe_failed"), "probe_failed", true),
        ]
        for runtime in ["codex", "grok"] {
            for (outcome, reason, retryable) in failures {
                let reply = try await wire.reply(runtime, outcome: outcome)
                try runtimeFormsStatus(reply, status: "fallback", reason: reason, retryable: retryable)
                if runtime == "codex" {
                    #expect(try reply.object().string("defaultValue") == "gpt-6.1-sol")
                    #expect(try runtimeFormsValues(reply).count == 17)
                    #expect(try reply.object().bool("customValueAllowed") == true)
                } else {
                    #expect(try runtimeFormsValues(reply) == ["grok-4.5", "grok-4.6", "grok-composer-2.5-fast"])
                    #expect(try reply.object().fields["customValueAllowed"] == nil)
                }
            }
        }
        let grokLive = try await wire.reply("grok", outcome: runtimeFormsLive([runtimeFormsModel("grok-wire", "Grok wire")]))
        try runtimeFormsStatus(grokLive, status: "live")
        #expect(try runtimeFormsValues(grokLive) == ["grok-wire"])
        #expect(try grokLive.object().fields["customValueAllowed"] == nil)

        let managed = [runtimeFormsOption("kimi-code/kimi-for-coding", "Kimi for Coding (default)")]
        for outcome in [JSONValue.object(["kind": .string("missing_config")]), runtimeFormsError("computer_offline")] {
            let v1 = try await wire.reply("kimi-sdk", version: 1, outcome: outcome)
            #expect(v1.status == 200)
            #expect(try v1.object().array("options") == managed)
            #expect(try v1.object().string("defaultValue") == "kimi-code/kimi-for-coding")
            #expect(try v1.object().fields["status"] == nil)
            let v2 = try await wire.reply("kimi-sdk", outcome: outcome)
            try runtimeFormsStatus(v2, status: "fallback",
                reason: outcome == .object(["kind": .string("missing_config")]) ? "missing_config" : "machine_offline",
                retryable: outcome == .object(["kind": .string("missing_config")]) ? false : true)
            #expect(try v2.object().array("options") == managed)
            #expect(try v2.object().string("defaultValue") == "kimi-code/kimi-for-coding")
        }
        let k3 = runtimeFormsModel("kimi-code/k3", "K3", reasoning: "balanced-plus")
        let k2 = runtimeFormsModel("kimi-code/k2", "K2")
        for version in [1, 2] {
            let live = try await wire.reply("kimi-sdk", version: version,
                outcome: runtimeFormsLive([k3, k2], defaultModel: "kimi-code/k3"))
            #expect(live.status == 200)
            let body = try live.object()
            #expect(body.array("options") == [runtimeFormsOption("kimi-code/k3", "K3", reasoning: "balanced-plus"), runtimeFormsOption("kimi-code/k2", "K2")])
            #expect(body.string("defaultValue") == "kimi-code/k3")
            #expect(body.string("status") == (version == 2 ? "live" : nil))
            #expect(body.fields["reason"] == nil && body.fields["retryable"] == nil)
        }
        for (outcome, reason, retryable) in failures where reason != "missing_config" && reason != "machine_offline" {
            let v1 = try await wire.reply("kimi-sdk", version: 1, outcome: outcome)
            #expect(v1.status == 409)
            let issue = reason == "no_models" ? "runtime_model_source_no_models"
                : reason == "unsupported" ? "runtime_model_source_unsupported" : "runtime_model_source_error"
            #expect(try v1.object().array("issues") == [.object(["code": .string(issue), "pointer": .string("/optionSources/model")])])
            let v2 = try await wire.reply("kimi-sdk", outcome: outcome)
            try runtimeFormsStatus(v2, status: "unavailable", reason: reason, retryable: retryable)
            #expect(try v2.object().array("options") == [])
            #expect(try v2.object().string("defaultValue") == "")
        }

        // Node's generated provider rows are canonical raw IDs, not the old
        // synthetic deepseek-chat catalog. Only the declared DeepSeek slice is locked.
        let builtinLive = runtimeFormsLive([
            runtimeFormsModel("deepseek/deepseek-v4-pro", "DeepSeek V4 Pro"),
            runtimeFormsModel("deepseek/deepseek-flash", "DeepSeek V4.1 Flash"),
        ], catalog: true)
        let expectedBuiltin = [runtimeFormsOption("deepseek/deepseek-v4-pro", "DeepSeek V4 Pro"),
                               runtimeFormsOption("deepseek/deepseek-flash", "DeepSeek V4.1 Flash")]
        for version in [1, 2] {
            let reply = try await wire.reply("builtin", version: version, outcome: builtinLive)
            #expect(reply.status == 200)
            let body = try reply.object()
            #expect(body.object("optionsByValue")?.array("deepseek") == expectedBuiltin)
            #expect(body.string("status") == (version == 2 ? "live" : nil))
            #expect(body.fields["reason"] == nil && body.fields["retryable"] == nil)
            let legacy = try await wire.reply("builtin", version: version,
                outcome: runtimeFormsLive([runtimeFormsModel("deepseek/deepseek-v4-pro", "DeepSeek V4 Pro")]))
            #expect(legacy.status == 409)
            #expect(try legacy.object().string("code") == "builtin_catalog_capability_required")
        }
        for (outcome, reason, retryable) in failures {
            // An answered non-live outcome is not a transport-offline fallback.
            let v1 = try await wire.reply("builtin", version: 1, outcome: outcome)
            #expect(v1.status == 409)
            #expect(try v1.object().array("issues") == [.object([
                "code": .string("builtin_catalog_unavailable"), "pointer": .string("/optionSources/model"),
            ])])
            let v2 = try await wire.reply("builtin", outcome: outcome)
            try runtimeFormsStatus(v2, status: "unavailable", reason: reason, retryable: retryable)
            #expect(try v2.object().object("optionsByValue")?.fields.isEmpty == true)
            // Node unavailableSource clears options only; provider metadata survives.
            #expect(try v2.object().object("defaultValueByValue")?.fields == [
                "deepseek": .string("deepseek/deepseek-v4-pro"),
                "moonshotai": .string("moonshotai/kimi-k2.6"),
            ])
            #expect(try v2.object().object("customValueAllowedByValue")?.fields == [
                "deepseek": .bool(false), "moonshotai": .bool(false),
            ])
        }

        // Real unanswered requests outlive the production registry's 20-second
        // deadline. A daemon-returned detect_timeout above is a different input.
        let codexTimeout = try await wire.reply("codex", outcome: nil)
        try runtimeFormsStatus(codexTimeout, status: "fallback", reason: "probe_timeout", retryable: true)
        #expect(try runtimeFormsValues(codexTimeout).count == 17)
        for version in [1, 2] {
            let timed = try await wire.reply("builtin", version: version, outcome: nil)
            #expect(timed.status == 200)
            let body = try timed.object()
            #expect(body.object("optionsByValue")?.array("deepseek")?.isEmpty == false)
            if version == 2 { try runtimeFormsStatus(timed, status: "fallback", reason: "probe_timeout", retryable: true) }
            else { #expect(body.fields["status"] == nil) }
        }
        await peer.socket.close()
        machine = nil
        try await protocolPGEventually { await fixture.executionConnection.registry.connectionEpoch(machineId: machineId) == nil }
        for version in [1, 2] {
            let reply = try await runtimeFormsHTTP(fixture, path: wire.source("builtin", version: version), token: token)
            #expect(reply.status == 200)
            let body = try reply.object()
            #expect(body.object("optionsByValue")?.array("deepseek")?.isEmpty == false)
            if version == 2 { try runtimeFormsStatus(reply, status: "fallback", reason: "machine_offline", retryable: true) }
            else { #expect(body.fields["status"] == nil) }
        }
        let offlineCodex = try await runtimeFormsHTTP(fixture, path: wire.source("codex"), token: token)
        try runtimeFormsStatus(offlineCodex, status: "fallback", reason: "machine_offline", retryable: true)
        await fixture.close()
    } catch {
        await fixture.close(machine: machine)
        throw error
    }
}

private struct RuntimeFormsQueryWire: Sendable {
    let fixture: AgentExecutionPostgresFixture
    let peer: ControlledMachineProtocolPeer
    let token: String
    let machineId: String
    var base: String { "/api/servers/\(fixture.serverId)/machines/\(machineId)" }
    func definition(_ runtime: String, version: Int = 2) -> String {
        if version == 2 { return "\(base)/runtime-forms/v2/\(runtime)" }
        return "\(base)/runtime-form-definitions/\(runtime)?schemaVersion=\(runtime).create.v1"
    }
    func source(_ runtime: String, version: Int = 2, refresh: Bool = false) -> String {
        let path = version == 2 ? "\(base)/runtime-forms/v2/\(runtime)/option-sources/model"
            : "\(base)/runtime-form-definitions/\(runtime)/option-sources/model?schemaVersion=\(runtime == "builtin" ? "builtin-pi.create.v3" : runtime + ".create.v1")"
        return refresh ? path + (version == 2 ? "?refresh=1" : "&refresh=1") : path
    }
    func reply(_ runtime: String, version: Int = 2, refresh: Bool = false, outcome: JSONValue?) async throws -> ProtocolPGHTTPResponse {
        let boundary = peer.socket.count
        let request = Task { try await runtimeFormsHTTP(fixture, path: source(runtime, version: version, refresh: refresh), token: token) }
        defer { request.cancel() }
        let frame = try await peer.socket.nextObject(since: boundary) { $0.string("type") == "machine:runtime_models:detect" && $0.string("runtime") == runtime }
        let requestId = try frame.requireString("requestId")
        #expect(UUID(uuidString: requestId) != nil)
        let expectedKeys: Set<String> = refresh ? ["type", "requestId", "runtime", "force"] : ["type", "requestId", "runtime"]
        #expect(Set(frame.fields.keys) == expectedKeys)
        if refresh { #expect(frame.bool("force") == true) }
        else { #expect(frame.fields["force"] == nil) }
        if let outcome {
            try await peer.socket.send(.init(["type": .string("machine:runtime_models:result"),
                "requestId": .string(requestId), "outcome": outcome]))
        }
        let response = try await request.value
        if response.status == 200 {
            let body = try response.object()
            #expect(body.string("runtimeId") == runtime)
            #expect(body.string("sourceId") == "model")
            #expect(body.string("pointer") == "/model")
        }
        return response
    }
}

private func runtimeFormsHTTP(_ fixture: AgentExecutionPostgresFixture, path: String, token: String) async throws -> ProtocolPGHTTPResponse {
    guard path.hasPrefix("/"), !path.hasPrefix("//"), let url = URL(string: path, relativeTo: fixture.baseURL),
          url.host == "127.0.0.1", url.port == fixture.baseURL.port else { throw ProtocolPGFailure.invalidResponse }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 45
    configuration.timeoutIntervalForResource = 45
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(fixture.serverId, forHTTPHeaderField: "X-Server-Id")
    let (body, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse, response.url?.host == "127.0.0.1", body.count <= 2 * 1024 * 1024 else {
        throw ProtocolPGFailure.invalidResponse
    }
    return .init(status: response.statusCode, body: body)
}

private func runtimeFormsStatus(_ response: ProtocolPGHTTPResponse, status: String, reason: String? = nil, retryable: Bool? = nil) throws {
    #expect(response.status == 200)
    let body = try response.object()
    #expect(body.string("status") == status)
    #expect(body.string("reason") == reason)
    #expect(body.bool("retryable") == retryable)
    if reason == nil { #expect(body.fields["reason"] == nil && body.fields["retryable"] == nil) }
}
private func runtimeFormsValues(_ response: ProtocolPGHTTPResponse) throws -> [String] {
    try (response.object().array("options") ?? []).compactMap {
        guard case .object(let row) = $0, case .string(let value) = row["value"] else { return nil }
        return value
    }
}
private func runtimeFormsModel(_ id: String, _ label: String, reasoning: String? = nil) -> JSONValue {
    var fields: [String: JSONValue] = ["id": .string(id), "label": .string(label)]
    if let reasoning { fields["supportedReasoningEfforts"] = .array([.string(reasoning)]); fields["defaultReasoningEffort"] = .string(reasoning) }
    return .object(fields)
}
private func runtimeFormsOption(_ value: String, _ label: String, reasoning: String? = nil) -> JSONValue {
    var fields: [String: JSONValue] = ["value": .string(value), "label": .string(label)]
    if let reasoning { fields["supportedReasoningEfforts"] = .array([.string(reasoning)]); fields["defaultReasoningEffort"] = .string(reasoning) }
    return .object(fields)
}
private func runtimeFormsLive(_ models: [JSONValue], defaultModel: String? = nil, catalog: Bool = false) -> JSONValue {
    var value: [String: JSONValue] = ["models": .array(models)]
    if let defaultModel { value["default"] = .string(defaultModel) }
    if catalog { value["catalog"] = .object(["protocolVersion": .integer(1), "runtime": .string("builtin"), "runtimeVersion": .string("0.84.3")]) }
    return .object(["kind": .string("live"), "value": .object(value)])
}
private func runtimeFormsError(_ code: String) -> JSONValue {
    .object(["kind": .string("error"), "code": .string(code), "retryable": .bool(true)])
}
