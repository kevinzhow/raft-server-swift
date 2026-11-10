import Foundation
import RaftShared
import Testing
@testable import RaftHTTP

private let builtinFormPGEnabled = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_PG_ACCEPTANCE"] == "1"

/// Existing real owner/HTTP/NIO fixture. The initial controlled Codex launch
/// supplies actual execution evidence; no builtin process/provider is invented.
@Test(.enabled(if: builtinFormPGEnabled), .serialized)
func postgresBuiltinFormOnlyPatchUsesCanonicalLiftAndNoOpDoesNotLiftAgain() async throws {
    guard let url = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_TEST_DATABASE_URL"],
          !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProtocolPGFailure.missingDedicatedDatabase }
    let f = try await AgentExecutionPostgresFixture.start(databaseURL: url)
    var machine: ControlledMachineProtocolPeer?
    do {
        let owner = try await f.login(f.ownerEmail)
        let outsider = try await f.login(f.outsiderEmail)
        let attachment = try await f.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Builtin form controlled owner")]))
        guard attachment.status == 201 else { throw ProtocolPGFailure.invalidResponse }
        let machineID = try attachment.object().requireString("machineId")
        let machineKey = try attachment.object().requireString("apiKey")
        let initial = try await f.http("POST", "/api/agents", token: owner, body: .init([
            "name": .string("Existing controlled execution"), "machineId": .string(machineID),
            "runtimeConfig": .object(["version": .integer(1), "runtime": .string("codex"),
                "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")]),
                "mode": .object(["kind": .string("default")]), "reasoningEffort": .null, "envVars": .object([:])])]))
        guard initial.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let agent = try initial.object().requireString("id")
        let peer = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: machineKey); machine = peer
        try await peer.sendControlledReady()
        let startBoundary = peer.socket.count
        let start = try await f.http("POST", "/api/agents/\(agent)/start", token: owner)
        guard start.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let frame = try await peer.socket.nextObject(since: startBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == agent }
        let launch = try frame.requireString("launchId")
        try await peer.acknowledgeControlledStart(frame)
        let failureBoundary = peer.socket.count
        try await peer.socket.send(.init(["type": .string("agent:runtime:outcome"), "v": .integer(1),
            "agentId": .string(agent), "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(0),
            "launchId": .string(launch), "sessionId": .null,
            "outcome": .object(["kind": .string("terminal_failure"), "failureKind": .string("runtime_error"), "fingerprint": .string("controlled-old-runtime")])]))
        _ = try await peer.socket.nextObject(since: failureBoundary) { $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == agent && $0.integer("clientSeq") == 0 }
        func bytes<T: Encodable>(_ value: T) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        }
        let failed = try #require(try await f.audit().execution.agents[agent])
        #expect(failed.failureCount == 1 && failed.launches[launch]?.terminalFailure == true)
        let ref: JSONValue = .object(["protocolVersion": .integer(2), "runtimeId": .string("builtin")])
        let key = "test-only-pg-form-key"
        var values: [String: JSONValue] = ["providerId": .string("openai-compatible"), "apiKey": .string(key),
            "baseUrl": .string("https://gateway.example.test/v1"), "model": .string("org/model"),
            "supportsImageInput": .bool(true), "loadLocalPlugins": .bool(true), "envVars": .object(["KEEP": .string("1")])]
        let patchBody = ProtocolPGObject(["formDefinitionRef": ref, "formValues": .object(values)])
        let commandBoundary = peer.socket.count
        let changed = try await f.http("PATCH", "/api/agents/\(agent)", token: owner, body: patchBody)
        #expect(changed.status == 200)
        let liftedAudit = try await f.audit()
        let lifted = try #require(liftedAudit.execution.agents[agent])
        #expect(lifted.generation == failed.generation + 1 && lifted.failureCount == 0 && lifted.currentLaunchId == nil)
        #expect(try bytes(lifted.launches) == bytes(failed.launches))
        #expect(try bytes(lifted.processes) == bytes(failed.processes))
        #expect(lifted.takeoverEpoch == failed.takeoverEpoch)
        values["apiKey"] = .string("")
        let noOp = try await f.http("PATCH", "/api/agents/\(agent)", token: owner,
            body: .init(["formDefinitionRef": ref, "formValues": .object(values)]))
        #expect(noOp.status == 200)
        let noOpAudit = try await f.audit()
        #expect(try bytes(noOpAudit.execution.agents[agent]) == bytes(lifted))
        #expect(noOpAudit.execution.commands == liftedAudit.execution.commands)
        let edit = try await f.http("GET", "/api/agents/\(agent)/runtime-form", token: owner)
        #expect(edit.status == 200 && !String(decoding: edit.body, as: UTF8.self).contains(key))
        #expect(try edit.object().object("values")?.string("model") == "org/model")
        values["baseUrl"] = .string("https://different.example.test/v1")
        let rejected = try await f.http("PATCH", "/api/agents/\(agent)", token: owner,
            body: .init(["formDefinitionRef": ref, "formValues": .object(values)]))
        #expect(rejected.status == 400)
        #expect(try rejected.object().string("error") == "runtimeConfig.provider.apiKey is required")
        #expect(try rejected.object().fields["issues"] == nil)
        let denied = try await f.http("PATCH", "/api/agents/\(agent)", token: outsider,
            body: .init(["formDefinitionRef": ref, "formValues": .object(values)]))
        #expect(denied.status == 403)
        values["envVars"] = .object(["BAD-KEY": .string("x")])
        let invalidEnv = try await f.http("PATCH", "/api/agents/\(agent)", token: owner,
            body: .init(["formDefinitionRef": ref, "formValues": .object(values.merging(["apiKey": .string(key)]) { _, b in b })]))
        #expect(invalidEnv.status == 400)
        let final = try await f.audit()
        #expect(try bytes(final.execution.agents[agent]) == bytes(lifted))
        #expect(final.execution.commands == liftedAudit.execution.commands)
        let frames = try await peer.socket.wireFence(since: commandBoundary).compactMap { try? ProtocolPGObject(text: $0) }
        #expect(frames.filter {
            ["agent:start", "agent:deliver", "agent:stop"].contains($0.string("type") ?? "") && $0.string("agentId") == agent
        }.isEmpty)
        await f.close(machine: machine)
    } catch {
        await f.close(machine: machine)
        throw error
    }
}
