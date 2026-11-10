import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RaftShared
import RaftPersistence
import TestSupport
import Testing
@testable import RaftHTTP

@Test(.enabled(if: machineQueryPGEnabled), .serialized)
func postgresSetupProjectionUsesRetainedComputerAuthority() async throws {
    guard let url = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_TEST_DATABASE_URL"], !url.isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    let f = try await AgentExecutionPostgresFixture.start(databaseURL: url)
    var machine: ControlledMachineProtocolPeer?
    var subscriber: ProtocolPGSocket?
    do {
        let token = try await f.login(f.ownerEmail)
        func projection() async throws -> ProtocolPGObject {
            let response = try await f.http("GET", "/api/servers/\(f.serverId)/setup-projection", token: token)
            #expect(response.status == 200)
            return try response.object()
        }
        let absent = try await projection()
        #expect(absent.string("surface") == "computer_runtime" && absent.bool("blocksChat") == true)
        #expect(absent.bool("hasConnectedComputer") == false)
        let attached = try await f.http("POST", "/api/computer/attach", token: token,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Remembered setup computer")]))
        #expect(attached.status == 201)
        let key = try attached.object().requireString("apiKey")
        let listedMachineId = try attached.object().requireString("machineId")
        func listedMachine() async throws -> ProtocolPGObject {
            let response = try await f.http("GET", "/api/servers/\(f.serverId)/machines", token: token)
            #expect(response.status == 200)
            let rows = try #require(try response.object().array("machines"))
            for case .object(let row) in rows where row["id"] == .string(listedMachineId) { return .init(row) }
            throw ProtocolPGFailure.missingField
        }
        let sleeping = try await projection()
        #expect(sleeping.bool("hasConnectedComputer") == true)
        #expect(sleeping.string("computerStatus") == "offline")
        #expect(sleeping.array("offlineComputers")?.count == 1)
        let peer = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key)
        machine = peer
        let inventory = ["claude", "codex", "grok", "builtin", "antigravity", "kimi-sdk", "kimi", "gemini", "pi"]
        try await peer.socket.send(.init([
            "type": .string("ready"), "daemonInstanceId": .string(peer.daemonId),
            "capabilities": .array(["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"].map(JSONValue.string)),
            "runningAgents": .array([]), "runtimes": .array(inventory.map(JSONValue.string)),
            "runtimeVersions": .object(["codex": .string("setup-wire-version")]),
            "runtimeDetection": .object(["status": .string("complete")]),
        ]))
        try await peer.socket.applicationFence()
        let onlineMachine = try await listedMachine()
        #expect(onlineMachine.string("status") == "online")
        #expect(onlineMachine.array("runtimes") == inventory.map(JSONValue.string))
        let onlineVersion = try #require(onlineMachine.integer("statusVersion"))
        let storedOnlineVersion = try f.runtime.withCommittedReadView {
            f.accounts.machinesAndComputersStore.machineStatusVersions[listedMachineId] ?? 0
        }
        #expect(onlineVersion == Int64(storedOnlineVersion))
        #expect(onlineVersion > 0)
        let ready = try await projection()
        #expect(ready.string("computerStatus") == "online")
        #expect(ready.string("runtimeStatus") == "ready_recommended")
        #expect(ready.string("surface") == "create_agent")
        #expect(ready.bool("blocksChat") == true) // no invented completion
        #expect(ready.string("phase") == absent.string("phase"))
        #expect(ready.string("gateReason") == "official_onboarding_agent_missing")
        let choices = try #require(ready.array("runtimeOptions"))
        let codex = try #require(choices.compactMap { value -> ProtocolPGObject? in
            guard case .object(let fields) = value, fields["runtimeId"] == .string("codex") else { return nil }; return .init(fields)
        }.first)
        #expect(codex.string("capabilityStatus") == "available" && codex.bool("canSelectInThisContext") == true)
        #expect(!(choices.contains { value in
            guard case .object(let fields) = value else { return false }
            return fields["runtimeId"] == .string("builtin") || fields["runtimeId"] == .string("grok")
        }))
        await peer.socket.close(); machine = nil
        try await protocolPGEventually {
            let response = try await f.http("GET", "/api/servers/\(f.serverId)/setup-projection", token: token)
            let disconnected = try response.object()
            return response.status == 200 && disconnected.string("computerStatus") == "offline" && disconnected.string("surface") == "computer_runtime"
        }
        let offline = try await projection()
        try await protocolPGEventually {
            let response = try await f.http("GET", "/api/servers/\(f.serverId)/machines", token: token)
            let rows = try response.object().array("machines") ?? []
            return rows.contains { value in
                guard case .object(let fields) = value else { return false }
                let row = ProtocolPGObject(fields)
                return row.string("id") == listedMachineId && row.string("status") == "offline" &&
                    (row.integer("statusVersion") ?? -1) > onlineVersion
            }
        }
        let offlineMachineRow = try await listedMachine()
        #expect(offlineMachineRow.string("status") == "offline")
        #expect(offlineMachineRow.array("runtimes") == inventory.map(JSONValue.string))
        let storedOfflineVersion = try f.runtime.withCommittedReadView {
            f.accounts.machinesAndComputersStore.machineStatusVersions[listedMachineId] ?? 0
        }
        #expect(offlineMachineRow.integer("statusVersion") == Int64(storedOfflineVersion))
        #expect(offline.bool("hasConnectedComputer") == true)
        #expect(offline.string("runtimeStatus") == "unknown")
        #expect(offline.array("runtimeOptions")?.isEmpty == true)
        guard case .object(let remembered)? = offline.array("offlineComputers")?.first else { throw ProtocolPGFailure.invalidResponse }
        #expect(remembered["name"] == .string("Remembered setup computer"))
        #expect(remembered["isComputer"] == .bool(true))
        // Continue in the SAME retained PG graph; reconnect the actual authenticated
        // peer. An unrelated online Computer cannot make Cindy's offline assignment usable.
        let active = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key)
        machine = active
        try await active.sendControlledReady()
        let second = try await f.http("POST", "/api/computer/attach", token: token,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Cindy offline assignment")]))
        #expect(second.status == 201)
        let offlineMachine = try second.object().requireString("machineId")
        let updates = try await f.subscriber(token: token)
        subscriber = updates
        let created = try await f.http("POST", "/api/agents", token: token, body: .init([
            "name": .string("Cindy"), "onboarding": .bool(true), "machineId": .string(offlineMachine),
            "runtime": .string("codex"), "model": .string("protocol-only-model"),
            "runtimeConfig": .object(["version": .integer(1), "runtime": .string("codex"),
                "model": .object(["kind": .string("custom"), "name": .string("protocol-only-model")])]),
        ]))
        #expect(created.status == 200)
        let cindy = try created.object()
        let cindyId = try cindy.requireString("id")
        let ownerId = try #require(cindy.object("creator")?.string("id"))
        #expect(cindy.string("name") == "Cindy" && cindy.string("displayName") == "Cindy")
        #expect(cindy.string("description") == "Onboarding Assistant" && cindy.string("avatarUrl") == "pixel:mug")
        #expect(cindy.string("serverRole") == "admin")
        #expect(cindy.string("machineId") == offlineMachine && cindy.string("serverId") == f.serverId)
        #expect(cindy.string("status") == "inactive")
        let createdFrame = try await updates.nextText { $0.hasPrefix("42[\"agent:created\",") && $0.contains(cindyId) }
        guard case .array(let event) = try JSONDecoder().decode(JSONValue.self, from: Data(createdFrame.dropFirst(2).utf8)),
              event.count == 2, case .object(let envelope) = event[1],
              case .object(let eventAgent)? = envelope["agent"] else { throw ProtocolPGFailure.invalidResponse }
        #expect(eventAgent["machineId"] == .string(offlineMachine))
        #expect(eventAgent["displayName"] == .string("Cindy") && eventAgent["avatarUrl"] == .string("pixel:mug"))
        #expect(eventAgent["status"] == .string("inactive"))
        #expect(eventAgent["envVars"] == nil && eventAgent["runtimeConfig"] == nil)
        func readCindyAssignment(_ expected: String) async throws {
            let detail = try await f.http("GET", "/api/agents/\(cindyId)", token: token)
            #expect(detail.status == 200)
            let detailBody = try detail.object()
            #expect(detailBody.string("machineId") == expected)
            let list = try await f.http("GET", "/api/agents", token: token)
            #expect(list.status == 200)
            guard case .array(let rows) = try JSONDecoder().decode(JSONValue.self, from: list.body),
                  let row = rows.compactMap({ value -> ProtocolPGObject? in
                      guard case .object(let fields) = value, fields["id"] == .string(cindyId) else { return nil }
                      return .init(fields)
                  }).first else { throw ProtocolPGFailure.invalidResponse }
            #expect(row.string("machineId") == expected && row.string("avatarUrl") == "pixel:mug")
            let options = try await f.http("GET", "/api/agents/\(cindyId)/runtime-options", token: token)
            #expect(try options.object().string("context") == "existing_agent")
            #expect(try options.object().string("machineId") == expected)
            #expect(try options.object().array("options")?.isEmpty == false)
        }
        try await readCindyAssignment(offlineMachine)
        func complete() async throws -> ProtocolPGHTTPResponse {
            try await f.http("POST", "/api/servers/\(f.serverId)/setup-transition", token: token,
                body: .init(["action": .string("complete")]))
        }
        #expect(try await projection().object("sideEffectState")?.string("completion") == "disabled")
        let wrongAssignment = try await complete()
        #expect(wrongAssignment.status == 409)
        #expect(try wrongAssignment.object().fields == ["error": .string("OFFICIAL_ONBOARDING_AGENT_NOT_USABLE")])
        #expect(try await projection().string("phase") == absent.string("phase"))
        #expect(try await f.http("POST", "/api/agents/\(cindyId)/stop", token: token).status == 200)
        let activeMachineId = try attached.object().requireString("machineId")
        #expect(try await f.http("POST", "/api/agents/\(cindyId)/assign-machine", token: token,
            body: .init(["machineId": .string(activeMachineId)])).status == 200)
        try await readCindyAssignment(activeMachineId)
        let startBoundary = active.socket.count
        #expect(try await f.http("POST", "/api/agents/\(cindyId)/start", token: token).status == 200)
        let start = try await active.socket.nextObject(since: startBoundary) {
            $0.string("type") == "agent:start" && $0.string("agentId") == cindyId
        }
        try await active.acknowledgeControlledStart(start)
        #expect(try await projection().object("sideEffectState")?.string("completion") == "enabled")
        let completed = try await complete()
        #expect(completed.status == 200)
        #expect(try completed.object().string("surface") == "complete")
        #expect(try completed.object().bool("blocksChat") == false)
        // Independent PG document read, not a new Store graph or fake phase write.
        let documents = try await f.observer.readSnapshot([try DurableKey(domain: .serversAndChannels, aggregateID: "root")])
        let document = try #require(documents.first)
        let stored = try ProtocolPGObject(data: document.decode(Data.self, codecVersion: 1))
        #expect(stored.string("format") == "raft.servers-and-channels")
        #expect(stored.object("business")?.object("setupPhases")?.string("\(f.serverId)\n\(ownerId)") == "complete")
        struct AssignmentSnapshot: Codable { let agentMachineIds: [String: String] }
        let agentDocuments = try await f.observer.readSnapshot([try DurableKey(domain: .agentsRuntime, aggregateID: "root")])
        let agentDocument = try #require(agentDocuments.first)
        let assignment = try RuntimePersistenceFormat.decode(AssignmentSnapshot.self,
            from: agentDocument.decode(Data.self, codecVersion: 1), domain: "raft.agents-runtime")
        #expect(assignment.agentMachineIds[cindyId] == activeMachineId)
        await active.socket.close(); machine = nil
        try await protocolPGEventually { try await f.audit().execution.connections[activeMachineId]?.online == false }
        #expect(try await projection().string("surface") == "complete")
        #expect(try await complete().status == 200)
        try await readCindyAssignment(activeMachineId)
        // Controlled start ACK proves published orchestration only. No real model,
        // installed CLI/login, official Computer or provider execution is claimed.
        await f.close(subscriber: subscriber)
    } catch {
        await f.close(machine: machine, subscriber: subscriber)
        throw error
    }
}

private let machineQueryPGEnabled = ProcessInfo.processInfo.environment["RAFT_MACHINE_QUERY_PG_ACCEPTANCE"] == "1"

/// Persistence codec evidence only: no PG/official-Computer claim and no new
/// Store graph after Shared activation. The old row has no new optional fields.
@Test func machineInventoryRowsReadOldSnapshotsAndRoundtripFactualMetadata() throws {
    let old = Data(#"{"id":"m","serverId":"s","userId":"u","name":"old","description":null,"apiKey":null,"apiKeyFingerprint":null,"legacyKeyMigratedAt":null,"hostname":null,"lastSeenAt":null,"runtimes":["codex","claude"]}"#.utf8)
    let row = try JSONDecoder().decode(RuntimePersistenceMachineRows.MachineRow.self, from: old)
    #expect(row.record.runtimeVersions.isEmpty && row.record.runtimeDetection == nil)
    #expect(row.record.runtimes == ["codex", "claude"])
    var record = row.record
    record.runtimeVersions = ["codex": "codec-codex-version", "claude": "codec-claude-version"]
    record.runtimeDetection = try JSONDecoder().decode(MachineRuntimeDetectionFact.self,
        from: Data(#"{"status":"incomplete","reason":"deadline","unfinishedRuntimes":["claude"],"durationMs":23,"updatedAtMs":42}"#.utf8))
    let bytes = try JSONEncoder().encode(RuntimePersistenceMachineRows.MachineRow(record))
    let restored = try JSONDecoder().decode(RuntimePersistenceMachineRows.MachineRow.self, from: bytes).record
    #expect(restored.runtimes == record.runtimes && restored.runtimeVersions == record.runtimeVersions)
    #expect(restored.runtimeDetection == record.runtimeDetection)
}

/// Real PG, HTTP and NIO transport with controlled wire inputs. This is not
/// official Computer inventory, CLI installation, login or model execution QA.
/// Run this filter alone: activating the real retained graph seals Shared.
@Test(.enabled(if: machineQueryPGEnabled), .serialized)
func postgresPublishedInventoryAndMachineQueries() async throws {
    guard let url = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_TEST_DATABASE_URL"], !url.isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    let f = try await AgentExecutionPostgresFixture.start(databaseURL: url)
    var machine: ControlledMachineProtocolPeer?
    var subscriber: ProtocolPGSocket?
    do {
        let token = try await f.login(f.ownerEmail)
        let attached = try await f.http("POST", "/api/computer/attach", token: token,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Inventory protocol peer")]))
        #expect(attached.status == 201)
        let machineId = try attached.object().requireString("machineId")
        let key = try attached.object().requireString("apiKey")
        let updates = try await f.subscriber(token: token)
        subscriber = updates
        // Create and assign while offline, so this query test never requests an
        // actual Agent start or uses a model turn as a query fixture.
        let created = try await f.http("POST", "/api/agents", token: token, body: .init([
            "name": .string("Workspace query owner"),
            "runtimeConfig": .object(["version": .integer(1), "runtime": .string("codex"),
                "model": .object(["kind": .string("custom"), "name": .string("protocol-only-model")])]),
        ]))
        #expect(created.status == 200)
        let agentId = try created.object().requireString("id")
        #expect(try await f.http("POST", "/api/agents/\(agentId)/stop", token: token).status == 200)
        #expect(try await f.http("POST", "/api/agents/\(agentId)/assign-machine", token: token,
            body: .init(["machineId": .string(machineId)])).status == 200)
        let peer = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key)
        machine = peer
        func sendReady(_ extra: [String: JSONValue]) async throws {
            var fields: [String: JSONValue] = [
                "type": .string("ready"), "daemonInstanceId": .string(peer.daemonId),
                "capabilities": .array(["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"].map(JSONValue.string)),
                "runningAgents": .array([]),
            ]
            fields.merge(extra) { _, new in new }
            try await peer.socket.send(.init(fields))
            try await peer.socket.applicationFence()
        }
        func fleet() async throws -> ProtocolPGObject {
            let reply = try await f.http("GET", "/api/servers/\(f.serverId)/machines", token: token)
            #expect(reply.status == 200)
            let rows = try #require(try reply.object().array("machines"))
            for case .object(let row) in rows where row["id"] == .string(machineId) { return .init(row) }
            throw ProtocolPGFailure.missingField
        }
        try await sendReady(["runtimeDetection": .object(["status": .string("pending")])])
        #expect(try await fleet().array("runtimes") == [])
        try await sendReady([
            "runtimes": .array(["codex", "claude", "grok"].map(JSONValue.string)),
            "runtimeVersions": .object(["codex": .string("wire-codex-1"), "claude": .string("wire-claude-1"), "grok": .string("wire-grok-1")]),
            "runtimeDetection": .object(["status": .string("complete")]),
        ])
        let capability = try await updates.nextText { $0.hasPrefix("42[\"machine:capabilities\",") && $0.contains("wire-codex-1") }
        guard case .array(let event) = try JSONDecoder().decode(JSONValue.self, from: Data(capability.dropFirst(2).utf8)),
              event.count == 2, case .object(let eventFields) = event[1] else { throw ProtocolPGFailure.invalidResponse }
        #expect(eventFields["machineId"] == .string(machineId))
        #expect(eventFields["runtimes"] == .array(["codex", "claude", "grok"].map(JSONValue.string)))
        let full = try await fleet()
        #expect(full.array("runtimes") == ["codex", "claude", "grok"].map(JSONValue.string))
        #expect(full.object("runtimeVersions")?.string("codex") == "wire-codex-1")
        let options = try await f.http("GET", "/api/servers/\(f.serverId)/machines/\(machineId)/runtime-options", token: token)
        let choices = try #require(try options.object().array("options"))
        let codex = try #require(choices.compactMap { value -> ProtocolPGObject? in
            guard case .object(let fields) = value, fields["runtimeId"] == .string("codex") else { return nil }; return .init(fields)
        }.first)
        #expect(codex.string("capabilityStatus") == "available" && codex.bool("canSelectInThisContext") == true)
        try await sendReady(["runtimeDetection": .object(["status": .string("pending")])])
        #expect(try await fleet().array("runtimes") == full.array("runtimes"))
        #expect(try await fleet().object("runtimeVersions")?.string("codex") == "wire-codex-1")
        try await sendReady([
            "runtimes": .array([.string("pi")]), "runtimeVersions": .object(["pi": .string("wire-pi-2")]),
            "runtimeDetection": .object(["status": .string("incomplete"), "reason": .string("deadline"), "unfinishedRuntimes": .array([.string("codex")])]),
        ])
        let partial = try await fleet()
        #expect(partial.array("runtimes") == [.string("pi"), .string("codex")])
        #expect(partial.object("runtimeVersions")?.string("codex") == "wire-codex-1")
        #expect(partial.object("runtimeVersions")?.string("claude") == nil)
        #expect(partial.object("runtimeDetection")?.string("reason") == "deadline")
        try await sendReady(["runtimes": .array([]), "runtimeVersions": .object([:]), "runtimeDetection": .object(["status": .string("complete")])])
        #expect(try await fleet().array("runtimes") == [])
        #expect(try await fleet().object("runtimeVersions")?.fields.isEmpty == true)
        try await sendReady(["runtimes": .array([.string("codex")]), "runtimeVersions": .object(["codex": .string("wire-codex-3")])])
        #expect(try await fleet().fields["runtimeDetection"] == .null)

        let boundary = peer.socket.count
        let models = Task { try await f.http("GET", "/api/servers/\(f.serverId)/machines/\(machineId)/runtime-models/codex", token: token) }
        let request = try await peer.socket.nextObject(since: boundary) { $0.string("type") == "machine:runtime_models:detect" }
        #expect(request.string("runtime") == "codex" && request.fields["force"] == nil)
        let requestId = try request.requireString("requestId")
        // These ordinary business frames precede the RPC result on the SAME
        // connection. A global write UoW held over await would deadlock here.
        try await sendReady(["runtimes": .array([.string("codex")]), "runtimeVersions": .object(["codex": .string("wire-codex-4")])])
        try await peer.socket.send(.init(["type": .string("machine:runtime_models:catalog"), "runtime": .string("codex"),
            "models": .array([.object(["id": .string("wire-model"), "label": .string("Wire model")])])]))
        try await peer.socket.send(.init(["type": .string("machine:runtime_models:result"), "requestId": .string(requestId),
            "outcome": .object(["kind": .string("live"), "value": .object([
                "models": .array([.object(["id": .string("wire-model"), "label": .string("Wire model"),
                    "serviceTiers": .array([.string("fast")]), "verified": .string("suggestion_only"),
                    "supportedReasoningEfforts": .array([.string("high")])])]), "default": .string("wire-model")])])]))
        let modelReply = try await models.value
        #expect(modelReply.status == 200)
        #expect(try modelReply.object().string("kind") == "live")
        #expect(try modelReply.object().string("default") == "wire-model")
        #expect(try modelReply.object().array("models")?.count == 1)
        let returnedModels = try #require(try modelReply.object().array("models"))
        guard case .object(let returnedModel) = returnedModels[0] else { throw ProtocolPGFailure.invalidResponse }
        #expect(returnedModel["serviceTiers"] == .array([.string("fast")]))
        #expect(returnedModel["verified"] == .string("suggestion_only"))
        #expect(returnedModel["supportedReasoningEfforts"] == .array([.string("high")]))

        // Vapor routes HEAD through GET while keeping the original method,
        // and percent-decodes each path component once before matching. These
        // actual HTTP requests must use the same short query boundaries.
        let modelPath = "/api/servers/\(f.serverId)/machines/\(machineId)/runtime-models/codex"
        let encodedModelPath = "/api/servers/\(f.serverId)/machines/\(machineId)/runtime%2Dmodels/codex"
        let routeBoundaryCases = [("GET", encodedModelPath), ("HEAD", modelPath), ("HEAD", encodedModelPath)]
        var referenceGET: MachineRPCBoundaryResponse?
        for (method, path) in routeBoundaryCases {
            let queryBoundary = peer.socket.count
            let pending = Task { try await machineRPCBoundaryRequest(f, method: method, path: path, token: token) }
            let detect = try await peer.socket.nextObject(since: queryBoundary) { $0.string("type") == "machine:runtime_models:detect" }
            #expect(detect.string("runtime") == "codex")
            // The ping fences BOTH ordinary frames, and must complete before
            // the correlated RPC reply is sent. An outer writer held by HEAD
            // or an encoded GET deadlocks here under the pre-fix middleware.
            try await peer.socket.send(.init(["type": .string("ready"), "daemonInstanceId": .string(peer.daemonId),
                "capabilities": .array(["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"].map(JSONValue.string)),
                "runningAgents": .array([]), "runtimes": .array([.string("codex")]),
                "runtimeVersions": .object(["codex": .string("wire-route-boundary")])]))
            try await peer.socket.send(.init(["type": .string("machine:runtime_models:catalog"), "runtime": .string("codex"),
                "models": .array([.object(["id": .string("wire-boundary-model"), "label": .string("Wire boundary model")])])]))
            try await peer.socket.applicationFence()
            try await peer.socket.send(.init(["type": .string("machine:runtime_models:result"),
                "requestId": .string(try detect.requireString("requestId")), "outcome": .object(["kind": .string("live"),
                    "value": .object(["models": .array([.object(["id": .string("wire-boundary-model"), "label": .string("Wire boundary model")])]),
                        "default": .string("wire-boundary-model")])])]))
            let reply = try await pending.value
            #expect(reply.status == 200)
            #expect(reply.headers["content-type"] == "application/json; charset=utf-8")
            #expect(reply.headers["x-robots-tag"] == "noindex, nofollow")
            if method == "GET" {
                #expect(!reply.body.isEmpty)
                #expect(reply.headers["content-length"] == String(reply.body.count))
                #expect(try ProtocolPGObject(data: reply.body).string("kind") == "live")
                referenceGET = reply
            } else {
                let reference = try #require(referenceGET)
                #expect(reply.body.isEmpty)
                #expect(reply.headers["content-length"] == reference.headers["content-length"])
                #expect(reply.headers["content-type"] == reference.headers["content-type"])
                #expect(reply.headers["cache-control"] == reference.headers["cache-control"])
                #expect(reply.headers["x-robots-tag"] == reference.headers["x-robots-tag"])
            }
        }
        let memberProbeToken = try await f.login(f.memberEmail)
        for path in [modelPath, encodedModelPath] {
            let forbidden = try await machineRPCBoundaryRequest(f, method: "HEAD", path: path, token: memberProbeToken)
            #expect(forbidden.status == 403 && forbidden.body.isEmpty)
            #expect(forbidden.headers["content-type"] == "application/json; charset=utf-8")
            #expect((Int(forbidden.headers["content-length"] ?? "0") ?? 0) > 0)
        }
        // One decode cannot turn an encoded slash into a new segment or turn
        // a doubly encoded literal into the registered runtime-models route.
        for literal in ["runtime%2Fmodels", "runtime%252Dmodels"] {
            let absent = try await machineRPCBoundaryRequest(f, method: "GET",
                path: "/api/servers/\(f.serverId)/machines/\(machineId)/\(literal)/codex", token: token)
            #expect(absent.status == 404)
        }

        let treeBoundary = peer.socket.count
        let tree = Task { try await f.http("GET", "/api/agents/\(agentId)/workspace-files?dirPath=docs&includeHidden=1", token: token) }
        let treeRequest = try await peer.socket.nextObject(since: treeBoundary) { $0.string("type") == "agent:workspace:list" }
        #expect(treeRequest.string("agentId") == agentId && treeRequest.string("dirPath") == "docs" && treeRequest.bool("includeHidden") == true)
        #expect(treeRequest.fields["requestId"] == nil && treeRequest.fields["connectionEpochId"] == nil)
        let file: JSONValue = .object(["name": .string("notes.txt"), "path": .string("docs/notes.txt"), "isDirectory": .bool(false),
            "size": .integer(3), "modifiedAt": .string("2026-01-01T00:00:00.000Z")])
        try await peer.socket.send(.init(["type": .string("agent:workspace:file_tree"), "agentId": .string(agentId),
            "dirPath": .string("docs"), "includeHidden": .bool(true), "files": .array([file])]))
        #expect(try await tree.value.object().array("files") == [file])
        let readBoundary = peer.socket.count
        let read = Task { try await f.http("GET", "/api/agents/\(agentId)/workspace-files/read?path=docs%2Fnotes.txt", token: token) }
        let readRequest = try await peer.socket.nextObject(since: readBoundary) { $0.string("type") == "agent:workspace:read" }
        #expect(readRequest.string("path") == "docs/notes.txt")
        try await peer.socket.send(.init(["type": .string("agent:workspace:file_content"), "agentId": .string(agentId),
            "requestId": .string(try readRequest.requireString("requestId")), "content": .string("abc"), "binary": .bool(false),
            "size": .integer(3), "encoding": .string("utf-8"), "mimeType": .string("text/plain")]))
        let readReply = try await read.value
        #expect(readReply.status == 200)
        #expect(try readReply.object().string("content") == "abc")

        let sourceBoundary = peer.socket.count
        let source = Task { try await f.http("GET", "/api/servers/\(f.serverId)/machines/\(machineId)/runtime-forms/v2/codex/option-sources/model?refresh=1", token: token) }
        let sourceRequest = try await peer.socket.nextObject(since: sourceBoundary) { $0.string("type") == "machine:runtime_models:detect" }
        #expect(sourceRequest.bool("force") == true)
        try await peer.socket.send(.init(["type": .string("machine:runtime_models:result"),
            "requestId": .string(try sourceRequest.requireString("requestId")), "outcome": .object(["kind": .string("missing_config")])]))
        let sourceReply = try await source.value
        #expect(sourceReply.status == 200)
        #expect(try sourceReply.object().string("status") == "fallback")
        #expect(try sourceReply.object().string("reason") == "missing_config")

        let failureBoundary = peer.socket.count
        let failedProbe = Task { try await f.http("GET", "/api/servers/\(f.serverId)/machines/\(machineId)/runtime-models/codex", token: token) }
        let failureRequest = try await peer.socket.nextObject(since: failureBoundary) { $0.string("type") == "machine:runtime_models:detect" }
        try await peer.socket.send(.init(["type": .string("machine:runtime_models:result"),
            "requestId": .string(try failureRequest.requireString("requestId")), "outcome": .object([
                "kind": .string("error"), "retryable": .bool(false), "code": .string("runtime_not_found"), "reason": .string("not_found")])]))
        let failedBody = try await failedProbe.value.object()
        #expect(failedBody.string("kind") == "error" && failedBody.bool("retryable") == false)
        #expect(failedBody.string("code") == "runtime_not_found" && failedBody.string("reason") == "not_found")
        #expect(failedBody.fields["models"] == nil && failedBody.fields["default"] == nil)

        // Migrated published fixtures: accepted inventory/model/workspace
        // replies come from this one real PG/NIO Root and authenticated peer.
        let fixtureMember = try await f.login(f.memberEmail)
        let fixtureViewer = try await f.login(f.outsiderEmail)
        let viewerMe = try await f.http("GET", "/api/auth/me", token: fixtureViewer)
        let fixtureViewerId = try viewerMe.object().requireString("id")
        try await f.runtime.execute {
            f.accounts.oauth.addMember(serverId: f.serverId, userId: fixtureViewerId, role: "member")
        }
        let modelBase = "/api/servers/\(f.serverId)/machines/\(machineId)"
        try await sendReady(["runtimes": .array([.string("codex")])])
        let inventoryReply = try await f.http("GET", modelBase + "/runtime-options", token: token)
        #expect(inventoryReply.status == 200)
        let inventoryBody = try inventoryReply.object()
        #expect(inventoryBody.string("context") == "new_agent")
        #expect(inventoryBody.string("machineId") == machineId)
        let inventoryChoices = try #require(inventoryBody.array("options"))
        func migratedChoice(_ runtime: String, in choices: [JSONValue]) throws -> ProtocolPGObject {
            for case .object(let choice) in choices where choice["runtimeId"] == .string(runtime) { return .init(choice) }
            throw ProtocolPGFailure.missingField
        }
        let codexOnly = try migratedChoice("codex", in: inventoryChoices)
        let absentClaude = try migratedChoice("claude", in: inventoryChoices)
        let oldBuiltin = try migratedChoice("builtin", in: inventoryChoices)
        #expect(codexOnly.string("capabilityStatus") == "available" && codexOnly.bool("canSelectInThisContext") == true)
        #expect(absentClaude.string("capabilityStatus") == "not_installed" && absentClaude.bool("canSelectInThisContext") == false)
        #expect(oldBuiltin.string("capabilityStatus") == "update_required")
        #expect(!inventoryChoices.contains { value in
            guard case .object(let choice) = value else { return false }; return choice["runtimeId"] == .string("grok")
        })
        for denied in [fixtureMember, fixtureViewer] {
            #expect(try await f.http("GET", modelBase + "/runtime-options", token: denied).status == 403)
            #expect(try await f.http("GET", modelBase + "/runtime-models/codex", token: denied).status == 403)
        }
        func migratedModelReply(_ runtime: String, outcome: JSONValue) async throws -> ProtocolPGHTTPResponse {
            let start = peer.socket.count
            let response = Task { try await f.http("GET", modelBase + "/runtime-models/\(runtime)", token: token) }
            let wire = try await peer.socket.nextObject(since: start) { $0.string("type") == "machine:runtime_models:detect" }
            #expect(wire.string("runtime") == runtime)
            try await peer.socket.send(.init(["type": .string("machine:runtime_models:result"),
                "requestId": .string(try wire.requireString("requestId")), "outcome": outcome]))
            return try await response.value
        }
        let gptModels: JSONValue = .array([.object(["id": .string("gpt-5.4"), "label": .string("GPT 5.4")])])
        let gptValue: JSONValue = .object(["models": gptModels, "default": .string("gpt-5.4")])
        let migratedModels = try await migratedModelReply("codex", outcome: .object(["kind": .string("live"), "value": gptValue]))
        #expect(migratedModels.status == 200)
        #expect(try migratedModels.object().fields == ["kind": .string("live"), "value": gptValue,
            "models": gptModels, "default": .string("gpt-5.4")])
        try await sendReady(["runtimes": .array([.string("codex"), .string("grok")])])
        let grokBefore = try await f.http("GET", modelBase + "/runtime-options", token: token)
        #expect(!(try grokBefore.object().array("options") ?? []).contains { value in
            guard case .object(let choice) = value else { return false }; return choice["runtimeId"] == .string("grok")
        })
        try await f.runtime.execute { f.accounts.createFeatureFlagForTesting(key: "grok_runtime_v0", defaultEnabled: true) }
        let grokAfter = try await f.http("GET", modelBase + "/runtime-options", token: token)
        let grokChoices = try #require(try grokAfter.object().array("options"))
        _ = try migratedChoice("grok", in: grokChoices)
        let grokModels: JSONValue = .array([.object(["id": .string("grok-4.5"), "label": .string("Grok 4.5")])])
        let grokReply = try await migratedModelReply("grok", outcome: .object(["kind": .string("live"),
            "value": .object(["models": grokModels, "default": .string("grok-4.5")])]))
        #expect(grokReply.status == 200)
        #expect(try grokReply.object().array("models") == [.object(["id": .string("grok-4.5"), "label": .string("Grok 4.5")])])
        #expect(try grokReply.object().string("default") == "grok-4.5")
        let modelOutcomes: [[String: JSONValue]] = [
            ["kind": .string("missing_config"), "recovery": .string("kimi_login")],
            ["kind": .string("no_models")], ["kind": .string("unsupported")],
            ["kind": .string("error"), "retryable": .bool(true)],
            ["kind": .string("error"), "retryable": .bool(true), "code": .string("detect_timeout")],
        ]
        for expected in modelOutcomes {
            let response = try await migratedModelReply("codex", outcome: .object(expected))
            #expect(response.status == 200)
            #expect(try response.object().fields == expected)
        }

        // A real member creates the second agent: creator access is independent
        // of owner/admin role. Unassigned failure precedes its public assignment.
        let creatorReply = try await f.http("POST", "/api/agents", token: fixtureMember, body: .init([
            "name": .string("Workspace creator authority"),
            "runtimeConfig": .object(["version": .integer(1), "runtime": .string("codex"),
                "model": .object(["kind": .string("custom"), "name": .string("protocol-only-model")])]),
        ]))
        #expect(creatorReply.status == 200)
        let creatorAgent = try creatorReply.object().requireString("id")
        let unassignedTree = try await f.http("GET", "/api/agents/\(creatorAgent)/workspace-files", token: fixtureMember)
        #expect(unassignedTree.status == 409)
        #expect(try unassignedTree.object().string("code") == "machine_unassigned")
        #expect(try await f.http("POST", "/api/agents/\(creatorAgent)/stop", token: token).status == 200)
        #expect(try await f.http("POST", "/api/agents/\(creatorAgent)/assign-machine", token: token,
            body: .init(["machineId": .string(machineId)])).status == 200)
        #expect(try await f.http("GET", "/api/agents/\(agentId)/workspace-files", token: fixtureMember).status == 403)
        #expect(try await f.http("PATCH", "/api/servers/\(f.serverId)/members/\(fixtureViewerId)", token: token,
            body: .init(["role": .string("admin")])).status == 200)
        for (principal, targetAgent) in [(token, agentId), (fixtureMember, creatorAgent), (fixtureViewer, agentId)] {
            let treeStart = peer.socket.count
            let response = Task { try await f.http("GET", "/api/agents/\(targetAgent)/workspace-files?dirPath=notes&includeHidden=true", token: principal) }
            let wire = try await peer.socket.nextObject(since: treeStart) { $0.string("type") == "agent:workspace:list" }
            #expect(wire.string("agentId") == targetAgent && wire.string("dirPath") == "notes" && wire.bool("includeHidden") == true)
            let hiddenFile: JSONValue = .object(["name": .string(".gitignore"), "path": .string(".gitignore"),
                "isDirectory": .bool(false), "size": .integer(12), "isHidden": .bool(true),
                "modifiedAt": .string("2026-01-01T00:00:00.000Z")])
            try await peer.socket.send(.init(["type": .string("agent:workspace:file_tree"), "agentId": .string(targetAgent),
                "dirPath": .string("notes"), "includeHidden": .bool(true), "files": .array([hiddenFile])]))
            let accepted = try await response.value
            #expect(accepted.status == 200)
            #expect(try accepted.object().array("files") == [hiddenFile])
        }
        let memoryStart = peer.socket.count
        let memoryRead = Task { try await f.http("GET", "/api/agents/\(creatorAgent)/workspace-files/read?path=MEMORY.md", token: fixtureMember) }
        let memoryWire = try await peer.socket.nextObject(since: memoryStart) { $0.string("type") == "agent:workspace:read" }
        #expect(memoryWire.string("agentId") == creatorAgent && memoryWire.string("path") == "MEMORY.md")
        try await peer.socket.send(.init(["type": .string("agent:workspace:file_content"), "agentId": .string(creatorAgent),
            "requestId": .string(try memoryWire.requireString("requestId")), "content": .string("secret"),
            "binary": .bool(false), "size": .integer(6), "mimeType": .string("text/plain"), "encoding": .string("utf8")]))
        let memoryReply = try await memoryRead.value
        #expect(memoryReply.status == 200)
        #expect(try memoryReply.object().string("content") == "secret")
        let timeoutStart = peer.socket.count
        let readTimeout = Task { try await migratedWorkspaceTimeoutHTTP(f, path: "/api/agents/\(creatorAgent)/workspace-files/read?path=MEMORY.md", token: fixtureMember) }
        _ = try await peer.socket.nextObject(since: timeoutStart) { $0.string("type") == "agent:workspace:read" }
        // No reply: the actual production registry deadline supplies the 504.
        let timedRead = try await readTimeout.value
        #expect(timedRead.status == 504)
        #expect(try timedRead.object().string("code") == "daemon_timeout")
        #expect(try timedRead.object().string("error") == "Workspace file read request timed out")

        let member = try await f.login(f.memberEmail)
        let me = try await f.http("GET", "/api/auth/me", token: member)
        let memberId = try me.object().requireString("id")
        #expect(try await f.http("PATCH", "/api/servers/\(f.serverId)/members/\(memberId)", token: token,
            body: .init(["role": .string("admin")])).status == 200)
        let revokedBoundary = peer.socket.count
        let revoked = Task { try await f.http("GET", "/api/servers/\(f.serverId)/machines/\(machineId)/runtime-models/codex", token: member) }
        let revokedRequest = try await peer.socket.nextObject(since: revokedBoundary) { $0.string("type") == "machine:runtime_models:detect" }
        // This ordinary public mutation must complete while the query waits.
        #expect(try await f.http("PATCH", "/api/servers/\(f.serverId)/members/\(memberId)", token: token,
            body: .init(["role": .string("member")])).status == 200)
        try await peer.socket.send(.init(["type": .string("machine:runtime_models:result"),
            "requestId": .string(try revokedRequest.requireString("requestId")), "outcome": .object(["kind": .string("unsupported")])]))
        #expect(try await revoked.value.status == 403)
        let disconnectBoundary = peer.socket.count
        let disconnected = Task { try await f.http("GET", "/api/servers/\(f.serverId)/machines/\(machineId)/runtime-models/codex", token: token) }
        _ = try await peer.socket.nextObject(since: disconnectBoundary) { $0.string("type") == "machine:runtime_models:detect" }
        await peer.socket.close()
        let offlineTree = try await f.http("GET", "/api/agents/\(creatorAgent)/workspace-files", token: fixtureMember)
        #expect(offlineTree.status == 409)
        #expect(try offlineTree.object().string("code") == "machine_offline")
        #expect(try offlineTree.object().string("error") == "Agent has no connected machine")
        let offline = try await disconnected.value
        #expect(offline.status == 200)
        #expect(try offline.object().string("code") == "computer_offline")
        await f.close(machine: peer, subscriber: updates)
    } catch {
        await f.close(machine: machine, subscriber: subscriber)
        throw error
    }
}

/// Actual URLSession response evidence, including HEAD's retained output
/// headers. Uses the fixture's bounded real HTTP session; no route/probe spy.
private struct MachineRPCBoundaryResponse: Sendable {
    let status: Int
    let body: Data
    let headers: [String: String]
}

private func machineRPCBoundaryRequest(_ fixture: AgentExecutionPostgresFixture, method: String,
    path: String, token: String) async throws -> MachineRPCBoundaryResponse {
    guard path.hasPrefix("/"), !path.hasPrefix("//"), let url = URL(string: path, relativeTo: fixture.baseURL),
          url.host == "127.0.0.1", url.port == fixture.baseURL.port else { throw ProtocolPGFailure.invalidResponse }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(fixture.serverId, forHTTPHeaderField: "X-Server-Id")
    let (body, rawResponse) = try await fixture.session.data(for: request)
    guard let response = rawResponse as? HTTPURLResponse, response.url?.host == "127.0.0.1",
          body.count <= 2 * 1024 * 1024 else { throw ProtocolPGFailure.invalidResponse }
    var headers: [String: String] = [:]
    for name in ["Content-Type", "Content-Length", "Cache-Control", "X-Robots-Tag"] {
        if let value = response.value(forHTTPHeaderField: name) { headers[name.lowercased()] = value }
    }
    return .init(status: response.statusCode, body: body, headers: headers)
}

// The shared fixture's normal HTTP deadline is 12 seconds. This one real
// production timeout case needs to outlive the registry's 15-second deadline.
private func migratedWorkspaceTimeoutHTTP(_ fixture: AgentExecutionPostgresFixture,
    path: String, token: String) async throws -> ProtocolPGHTTPResponse {
    guard path.hasPrefix("/"), !path.hasPrefix("//"),
          let url = URL(string: path, relativeTo: fixture.baseURL),
          url.host == "127.0.0.1", url.port == fixture.baseURL.port else { throw ProtocolPGFailure.invalidResponse }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 30
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(fixture.serverId, forHTTPHeaderField: "X-Server-Id")
    let (bytes, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse, response.url?.host == "127.0.0.1",
          bytes.count <= 2 * 1024 * 1024 else { throw ProtocolPGFailure.invalidResponse }
    return .init(status: response.statusCode, body: bytes)
}

// Actual PG/NIO observation for write refusal: snapshots come from the independent
// database client and frames come from a real subscriber, not a recorded sink.
@Test(.enabled(if: machineQueryPGEnabled), .serialized)
func postgresGrokWritePolicyRefusalHasNoAgentMutationOrCreatedFrame() async throws {
    func phase(_ value: String, line: UInt = #line) { print("GROK_POLICY_PG \(value) at \(#fileID):\(line)") }
    var currentPhase = "fixture-start"
    phase(currentPhase)
    guard let url = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_TEST_DATABASE_URL"], !url.isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    let f = try await AgentExecutionPostgresFixture.start(databaseURL: url)
    var machine: ControlledMachineProtocolPeer?
    var subscriber: ProtocolPGSocket?
    do {
        let token = try await f.login(f.ownerEmail)
        let attached = try await f.http("POST", "/api/computer/attach", token: token,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Grok policy protocol inventory")]))
        #expect(attached.status == 201)
        let machineId = try attached.object().requireString("machineId")
        let key = try attached.object().requireString("apiKey")
        let peer = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key)
        machine = peer
        try await peer.socket.send(.init([
            "type": .string("ready"), "daemonInstanceId": .string(peer.daemonId),
            "capabilities": .array(["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"].map(JSONValue.string)),
            "runningAgents": .array([]), "runtimes": .array(["codex", "grok"].map(JSONValue.string)),
        ]))
        try await peer.socket.applicationFence()
        // Retain factual inventory but disconnect before any agent is created.
        // Positive admission must not request a model launch in this scene.
        await peer.socket.close(); machine = nil
        try await protocolPGEventually { try await f.audit().execution.connections[machineId]?.online == false }
        let updates = try await f.subscriber(token: token)
        subscriber = updates
        let grokConfig: JSONValue = .object([
            "version": .integer(1), "runtime": .string("grok"),
            "model": .object(["kind": .string("custom"), "name": .string("protocol-only-model")]),
        ])
        func create(_ name: String, runtime: String) async throws -> ProtocolPGHTTPResponse {
            let config: JSONValue = runtime == "grok" ? grokConfig : .object([
                "version": .integer(1), "runtime": .string(runtime),
                "model": .object(["kind": .string("custom"), "name": .string("protocol-only-model")]),
            ])
            return try await f.http("POST", "/api/agents", token: token,
                body: .init(["name": .string(name), "machineId": .string(machineId), "runtimeConfig": config]))
        }
        let target = try await create("Grok policy Codex target", runtime: "codex")
        #expect(target.status == 200)
        let targetId = try target.object().requireString("id")
        let ownerId = try #require(try target.object().object("creator")?.string("id"))
        func policy(_ mode: String) async throws {
            try await f.runtime.execute {
                f.accounts.agentsRuntimeStore.withState { state in
                    state.featureFlagRecords.removeValue(forKey: "grok_runtime_v0")
                    state.featureFlagRuleRecords.removeAll { $0.key == "grok_runtime_v0" }
                }
                f.accounts.createFeatureFlagForTesting(key: "grok_runtime_v0",
                    defaultEnabled: mode != "off", killSwitch: mode == "kill")
                if mode == "user-deny" {
                    f.accounts.addFeatureFlagRuleForTesting(key: "grok_runtime_v0", stage: "user", decision: "deny", values: [ownerId])
                }
                // The obsolete set deliberately disagrees with every denial.
                f.accounts.enableGrokRuntimeForTesting(serverId: f.serverId)
            }
        }
        try await policy("allow")
        let current = try await create("Grok policy current runtime", runtime: "grok")
        #expect(current.status == 200)
        let currentId = try current.object().requireString("id")
        let deniedBody = "{\"error\":\"Grok Build is not enabled on this server\",\"code\":\"grok_runtime_disabled\"}"
        for mode in ["off", "kill", "user-deny"] {
            currentPhase = "\(mode): policy"; phase(currentPhase)
            try await policy(mode)
            currentPhase = "\(mode): before-audit"; phase(currentPhase)
            let before = try await f.audit()
            let targetBefore = try await f.http("GET", "/api/agents/\(targetId)", token: token)
            let boundary = updates.count
            let forbiddenName = "Grok refused \(mode)"
            currentPhase = "\(mode): refused-create"; phase(currentPhase)
            let refused = try await create(forbiddenName, runtime: "grok")
            #expect(refused.status == 403)
            #expect(String(decoding: refused.body, as: UTF8.self) == deniedBody)
            currentPhase = "\(mode): refused-patch"; phase(currentPhase)
            let patch = try await f.http("PATCH", "/api/agents/\(targetId)", token: token, body: .init([
                "runtimeConfig": grokConfig, "description": .string("Refused description"),
                "displayName": .string("Refused display"), "serverRole": .string("admin"),
            ]))
            #expect(patch.status == 403)
            #expect(String(decoding: patch.body, as: UTF8.self) == deniedBody)
            currentPhase = "\(mode): after-audit"; phase(currentPhase)
            let after = try await f.audit()
            // Compare the identical complete values, but do not ask Testing to
            // recursively render all PG payloads on a negative-baseline failure.
            let agentRowsUnchanged = after.canonicalAgents.fields == before.canonicalAgents.fields
            let messageRowsUnchanged = after.messages.map(\.fields) == before.messages.map(\.fields)
            #expect(agentRowsUnchanged, "Full canonical Agent rows changed after refusal")
            #expect(messageRowsUnchanged, "Full message rows changed after refusal")
            currentPhase = "\(mode): cold-target-get"; phase(currentPhase)
            let targetAfter = try await f.http("GET", "/api/agents/\(targetId)", token: token)
            #expect(targetAfter.body == targetBefore.body)
            // Unchanged-current Grok config remains editable under a disabled
            // caller policy; the permission is not a blanket Grok update ban.
            currentPhase = "\(mode): current-grok-patch"; phase(currentPhase)
            let grandfather = try await f.http("PATCH", "/api/agents/\(currentId)", token: token,
                body: .init(["runtimeConfig": grokConfig, "description": .string("Current \(mode)")]))
            #expect(grandfather.status == 200)
            #expect(try grandfather.object().string("runtime") == "grok")
            // A later committed create event fences the relevant publication
            // stream; the WS pong fences raw output. Observe actual wire frames.
            currentPhase = "\(mode): sentinel-create"; phase(currentPhase)
            let sentinel = try await create("Grok policy fence \(mode)", runtime: "codex")
            #expect(sentinel.status == 200)
            let sentinelId = try sentinel.object().requireString("id")
            currentPhase = "\(mode): sentinel-wire"; phase(currentPhase)
            _ = try await updates.nextText(since: boundary) {
                $0.hasPrefix("42[\"agent:created\",") && $0.contains(sentinelId)
            }
            currentPhase = "\(mode): raw-pong-fence"; phase(currentPhase)
            let frames = try await updates.wireFence(since: boundary)
            #expect(!frames.contains(where: { $0.hasPrefix("42[\"agent:created\",") && $0.contains(forbiddenName) }))
            // Configuration acceptance and controlled inventory are the only
            // positive claims: no real CLI/login/provider/model or restart proof.
        }
        currentPhase = "fixture-close"; phase(currentPhase)
        await f.close(subscriber: subscriber)
        phase("fixture-closed")
    } catch {
        print("GROK_POLICY_PG error during \(currentPhase) at \(#fileID):\(#line): \(error)")
        phase("error-fixture-close")
        await f.close(machine: machine, subscriber: subscriber)
        phase("error-fixture-closed")
        throw error
    }
}

@Test(.enabled(if: machineQueryPGEnabled), .serialized)
func postgresGrokMachineScopeAndCapabilityRefusalsPreserveRowsAndWire() async throws {
    guard let url = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_TEST_DATABASE_URL"], !url.isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    func phase(_ value: String, line: UInt = #line) { print("GROK_MACHINE_PG \(value) at \(#fileID):\(line)") }
    var currentPhase = "fixture-start"
    phase(currentPhase)
    let f = try await AgentExecutionPostgresFixture.start(databaseURL: url)
    var machine: ControlledMachineProtocolPeer?
    var subscriber: ProtocolPGSocket?
    do {
        let token = try await f.login(f.ownerEmail)
        let attached = try await f.http("POST", "/api/computer/attach", token: token,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Grok scope protocol inventory")]))
        #expect(attached.status == 201)
        let machineId = try attached.object().requireString("machineId")
        let key = try attached.object().requireString("apiKey")
        let peer = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key)
        machine = peer
        try await peer.socket.send(.init([
            "type": .string("ready"), "daemonInstanceId": .string(peer.daemonId),
            "capabilities": .array(["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"].map(JSONValue.string)),
            "runningAgents": .array([]), "runtimes": .array(["codex", "grok"].map(JSONValue.string)),
        ]))
        try await peer.socket.applicationFence()
        await peer.socket.close(); machine = nil
        try await protocolPGEventually { try await f.audit().execution.connections[machineId]?.online == false }
        let updates = try await f.subscriber(token: token); subscriber = updates
        let grok: JSONValue = .object([
            "version": .integer(1), "runtime": .string("grok"),
            "model": .object(["kind": .string("custom"), "name": .string("protocol-only-model")]),
        ])
        func post(_ name: String, machineId: String?, legacy: Bool, runtime: String = "grok") async throws -> ProtocolPGHTTPResponse {
            var fields: [String: JSONValue] = ["name": .string(name)]
            if let machineId { fields["machineId"] = .string(machineId) }
            if legacy { fields["runtime"] = .string(runtime) }
            else {
                fields["runtimeConfig"] = runtime == "grok" ? grok : .object([
                    "version": .integer(1), "runtime": .string(runtime),
                    "model": .object(["kind": .string("custom"), "name": .string("protocol-only-model")]),
                ])
            }
            return try await f.http("POST", "/api/agents", token: token, body: .init(fields))
        }
        try await f.runtime.execute { f.accounts.createFeatureFlagForTesting(key: "grok_runtime_v0", defaultEnabled: true) }
        let current = try await post("Grok scope current", machineId: machineId, legacy: false)
        #expect(current.status == 200)
        let currentId = try current.object().requireString("id")
        let ownerId = try #require(try current.object().object("creator")?.string("id"))
        let foreignServer = UUID().uuidString.lowercased()
        let foreign = try await f.runtime.execute {
            f.accounts.oauth.addOwnedServer(id: foreignServer, slug: "grok-foreign-\(foreignServer)", name: "Other tenant", ownerId: ownerId)
            let id = f.accounts.registerMachine(serverId: foreignServer, userId: ownerId, name: "Foreign retained inventory")
            f.accounts.setMachineRuntimesForTesting(machineId: id, runtimes: ["grok"])
            return id
        }
        let unknown = UUID().uuidString.lowercased()
        for enabled in [false, true] {
            try await f.runtime.execute { f.accounts.setFeatureFlagDefaultForTesting(key: "grok_runtime_v0", defaultEnabled: enabled) }
            for (index, id) in [unknown, foreign].enumerated() {
                for legacy in [false, true] {
                    currentPhase = "scope-\(enabled)-\(index)-\(legacy)"; phase(currentPhase)
                    let before = try await f.audit(); let boundary = updates.count
                    let name = "Grok scope refused \(enabled) \(index) \(legacy)"
                    let response = try await post(name, machineId: id, legacy: legacy)
                    #expect(response.status == 400)
                    #expect(String(decoding: response.body, as: UTF8.self) == "{\"error\":\"Machine not found in this server\"}")
                    let after = try await f.audit()
                    let unchanged = after.canonicalAgents.fields == before.canonicalAgents.fields
                    let messagesUnchanged = after.messages.map(\.fields) == before.messages.map(\.fields)
                    #expect(unchanged, "Full PG Agent rows changed after machine-scope refusal")
                    #expect(messagesUnchanged, "Full PG message rows changed after machine-scope refusal")
                    let sentinel = try await post("Scope fence \(enabled) \(index) \(legacy)", machineId: nil, legacy: false, runtime: "codex")
                    #expect(sentinel.status == 200)
                    let sentinelId = try sentinel.object().requireString("id")
                    _ = try await updates.nextText(since: boundary) { $0.hasPrefix("42[\"agent:created\",") && $0.contains(sentinelId) }
                    let frames = try await updates.wireFence(since: boundary)
                    #expect(!frames.contains(where: { $0.hasPrefix("42[\"agent:created\",") && $0.contains(name) }))
                }
            }
        }
        // Inventory loss comes from a new authenticated real protocol connection,
        // not a capability callback or a source-level fake installed/online bit.
        currentPhase = "inventory-loss"; phase(currentPhase)
        let loss = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key)
        machine = loss
        try await loss.socket.send(.init([
            "type": .string("ready"), "daemonInstanceId": .string(loss.daemonId),
            "capabilities": .array(["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"].map(JSONValue.string)),
            "runningAgents": .array([]), "runtimes": .array([.string("codex")]),
        ]))
        try await loss.socket.applicationFence()
        await loss.socket.close(); machine = nil
        try await protocolPGEventually { try await f.audit().execution.connections[machineId]?.online == false }
        let capWire = "{\"error\":\"Grok Build is not available on this computer\",\"code\":\"runtime_capability_unavailable\"}"
        for enabled in [true, false] {
            try await f.runtime.execute { f.accounts.setFeatureFlagDefaultForTesting(key: "grok_runtime_v0", defaultEnabled: enabled) }
            currentPhase = "capability-\(enabled)"; phase(currentPhase)
            let before = try await f.audit(); let boundary = updates.count
            let detail = try await f.http("GET", "/api/agents/\(currentId)", token: token)
            let patch = try await f.http("PATCH", "/api/agents/\(currentId)", token: token, body: .init([
                "runtimeConfig": grok, "description": .string("Must not write"),
                "displayName": .string("Must not write"), "serverRole": .string("admin"),
            ]))
            #expect(patch.status == 409)
            #expect(String(decoding: patch.body, as: UTF8.self) == capWire)
            let name = "Grok capability refused \(enabled)"
            let create = try await post(name, machineId: machineId, legacy: true)
            #expect(create.status == (enabled ? 409 : 403))
            if enabled { #expect(String(decoding: create.body, as: UTF8.self) == capWire) }
            let after = try await f.audit()
            let unchanged = after.canonicalAgents.fields == before.canonicalAgents.fields
            let messagesUnchanged = after.messages.map(\.fields) == before.messages.map(\.fields)
            #expect(unchanged, "Full PG Agent rows changed after capability refusal")
            #expect(messagesUnchanged, "Full PG message rows changed after capability refusal")
            let detailAfter = try await f.http("GET", "/api/agents/\(currentId)", token: token)
            #expect(detailAfter.body == detail.body)
            let sentinel = try await post("Capability fence \(enabled)", machineId: nil, legacy: false, runtime: "codex")
            #expect(sentinel.status == 200)
            let sentinelId = try sentinel.object().requireString("id")
            _ = try await updates.nextText(since: boundary) { $0.hasPrefix("42[\"agent:created\",") && $0.contains(sentinelId) }
            let frames = try await updates.wireFence(since: boundary)
            #expect(!frames.contains(where: { $0.hasPrefix("42[\"agent:created\",") && $0.contains(name) }))
        }
        currentPhase = "fixture-close"; phase(currentPhase)
        await f.close(subscriber: subscriber)
        phase("fixture-closed")
    } catch {
        print("GROK_MACHINE_PG error during \(currentPhase) at \(#fileID):\(#line): \(error)")
        phase("error-fixture-close")
        await f.close(machine: machine, subscriber: subscriber)
        phase("error-fixture-closed")
        throw error
    }
}
