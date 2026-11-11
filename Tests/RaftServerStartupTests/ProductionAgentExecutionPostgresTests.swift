import Foundation
import RaftPersistence
import RaftShared
import Testing
@testable import RaftHTTP

private let protocolPGEnabled = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_PG_ACCEPTANCE"] == "1"

/// Real HTTP, PostgreSQL and machine/socket.io transports, with explicitly
/// controlled peer inputs. This does not prove official Computer inventory,
/// logged-in Codex, an OS process, model completion, or real mailbox delivery.
/// Run this one filter in its own process: activate permanently seals Shared.
@Test(.enabled(if: protocolPGEnabled), .serialized)
func postgresPublicAgentControlsWithProtocolPeer() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    let fixture = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    var machine: ControlledMachineProtocolPeer?
    var subscriber: ProtocolPGSocket?
    do {
        let owner = try await fixture.login(fixture.ownerEmail)
        let member = try await fixture.login(fixture.memberEmail)
        let outsider = try await fixture.login(fixture.outsiderEmail)
        let attach = try await fixture.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(fixture.slug), "name": .string("Controlled protocol peer")]))
        #expect(attach.status == 201)
        let attached = try attach.object()
        let machineId = try attached.requireString("machineId")
        let computerKey = try attached.requireString("apiKey")
        let runtimeConfig: JSONValue = .object([
            "version": .integer(1), "runtime": .string("codex"),
            "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")]),
        ])
        // Create before ready so automatic create-start cannot pollute the
        // explicit human-start assertion. No presence/ready setters are called.
        let assignedReply = try await fixture.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Protocol assigned"), "machineId": .string(machineId), "runtimeConfig": runtimeConfig]))
        #expect(assignedReply.status == 200)
        let agentId = try assignedReply.object().requireString("id")
        let unassignedReply = try await fixture.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Protocol unassigned"), "runtimeConfig": runtimeConfig]))
        #expect(unassignedReply.status == 200)
        let unassignedId = try unassignedReply.object().requireString("id")
        let channelReply = try await fixture.http("POST", "/api/channels", token: owner,
            body: .init(["name": .string("protocol-pg-work")]))
        #expect(channelReply.status == 200)
        let channelId = try channelReply.object().requireString("id")
        let membershipReply = try await fixture.http("POST", "/api/channels/\(channelId)/members", token: owner,
            body: .init(["agentId": .string(agentId)]))
        #expect(membershipReply.status == 200)
        let updates = try await fixture.subscriber(token: owner)
        subscriber = updates
        let peer = try await ControlledMachineProtocolPeer.connect(port: fixture.machineServer.port, key: computerKey)
        machine = peer
        let epoch = try peer.context.requireString("connectionEpochId")
        #expect(peer.context.string("machineId") == machineId)
        #expect(peer.context.string("serverId") == fixture.serverId)
        try await peer.sendControlledReady()
        let ready = try await fixture.audit()
        #expect(ready.execution.connections[machineId]?.ready == true)
        #expect(ready.execution.connections[machineId]?.connectionEpochId == epoch)
        #expect(ready.execution.commands.isEmpty)

        let startBoundary = peer.socket.count
        let started = try await fixture.http("POST", "/api/agents/\(agentId)/start", token: member)
        #expect(started.status == 200)
        #expect(String(decoding: started.body, as: UTF8.self) == "{\"ok\":true}")
        let firstFrame = try await peer.socket.nextObject(since: startBoundary) {
            $0.string("type") == "agent:start" && $0.string("agentId") == agentId
        }
        let firstLaunch = try firstFrame.requireString("launchId")
        let firstDispatch = try firstFrame.requireString("startDispatchId")
        let firstAudit = try await fixture.audit()
        let firstCommand = try #require(firstAudit.execution.commands.values.first {
            $0.kind == .start && $0.agentId == agentId && $0.startDispatchId == firstDispatch
        })
        #expect(firstFrame.bool("humanStart") == true)
        #expect(firstFrame.string("connectionEpochId") == epoch)
        #expect(firstFrame.integer("takeoverEpoch") == firstCommand.takeoverEpoch)
        #expect(firstFrame.integer("breakerGeneration") == firstCommand.breakerGeneration)
        #expect(firstCommand.launchId == firstLaunch)
        #expect(firstAudit.execution.dispatches?[firstCommand.commandId.uuidString]?.connectionEpochId == epoch)
        #expect(firstAudit.execution.dispatches?[firstCommand.commandId.uuidString]?.phase == .attempting)
        #expect(firstAudit.execution.agents[agentId]?.processes.isEmpty == true)
        let firstEffect = try #require(try await fixture.outbox(firstCommand.commandId))
        let firstReference = try JSONDecoder().decode(AgentExecutionIntentReference.self, from: firstEffect.effect.payload)
        #expect(firstEffect.effect.kind.rawValue == "agent.execution")
        #expect(firstEffect.writerEpoch > 0)
        #expect(firstEffect.deliveredAt == nil)
        #expect(firstReference.commandId == firstCommand.commandId)
        #expect(firstAudit.execution.agents[agentId]?.launches[firstLaunch]?.startAccepted == false)
        #expect(firstFrame.object("config")?.string("agentCredentialId") == firstAudit.execution.agents[agentId]?.launches[firstLaunch]?.runnerCredentialId)
        try await peer.acknowledgeControlledStart(firstFrame)
        try await protocolPGEventually { try await fixture.outbox(firstCommand.commandId)?.deliveredAt != nil }
        let admitted = try await fixture.audit()
        #expect(admitted.execution.agents[agentId]?.launches[firstLaunch]?.startAccepted == true)
        #expect(admitted.execution.commands[firstCommand.commandId.uuidString]?.status == .accepted)
        #expect(admitted.execution.dispatches?[firstCommand.commandId.uuidString]?.phase == .accepted)

        // The peer supplies this terminal-failure evidence. The server's reply
        // below must come from real PG-backed production ingress, never a stub.
        let outcomeBoundary = peer.socket.count
        try await peer.socket.send(.init([
            "type": .string("agent:runtime:outcome"), "v": .integer(1), "agentId": .string(agentId),
            "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(0), "launchId": .string(firstLaunch),
            "sessionId": .null,
            "outcome": .object(["kind": .string("terminal_failure"), "failureKind": .string("runtime_error"),
                                "fingerprint": .string("controlled-protocol-outcome-not-a-Codex-result")]),
        ]))
        let outcomeAck = try await peer.socket.nextObject(since: outcomeBoundary) { $0.string("type") == "agent:outcome:ack" }
        #expect(outcomeAck.string("agentId") == agentId)
        #expect(outcomeAck.string("daemonInstanceId") == peer.daemonId)
        #expect(outcomeAck.integer("clientSeq") == 0)
        let outcomeAudit = try await fixture.audit()
        let scope = AgentExecutionState.key(machineId, agentId, peer.daemonId)
        let receipt = AgentExecutionState.key(scope, "sequence:0")
        #expect(outcomeAudit.execution.receipts[receipt]?.utf8.count == 64)
        #expect(outcomeAudit.execution.watermarks[scope] == 0)
        #expect(outcomeAudit.execution.agents[agentId]?.failureCount == 1)
        #expect(outcomeAudit.execution.agents[agentId]?.launches[firstLaunch]?.terminalFailure == true)

        let stopBoundary = peer.socket.count
        let stopped = try await fixture.http("POST", "/api/agents/\(agentId)/stop", token: member)
        #expect(stopped.status == 200)
        #expect(String(decoding: stopped.body, as: UTF8.self) == "{\"ok\":true,\"appliesOnReconnect\":true}")
        _ = try await peer.socket.nextObject(since: stopBoundary) { $0.string("type") == "agent:stop" && $0.string("agentId") == agentId }
        let stoppedAudit = try await fixture.audit()
        let stopIntent = try #require(stoppedAudit.execution.stopIntents?.values.first { $0.agentId == agentId && $0.clearedByHumanStart == nil })
        #expect(stoppedAudit.status(agent: agentId) == "stopped")
        try await protocolPGEventually { try await fixture.outbox(stopIntent.commandId)?.deliveredAt != nil }
        // agent:stop has no upstream acknowledgement. None is fabricated.
        let suppressionBoundary = peer.socket.count
        await fixture.pausePublications()
        let publicationBoundary = updates.count
        let taskReply = try await fixture.http("POST", "/api/tasks/channel/\(channelId)", token: owner,
            body: .init(["tasks": .array([.object(["title": .string("Preserve work while manually stopped")])])]))
        #expect(taskReply.status == 200)
        let taskBody = try taskReply.object()
        guard case .object(let projected)? = taskBody.array("tasks")?.first else { throw ProtocolPGFailure.invalidResponse }
        let taskId = try ProtocolPGObject(projected).requireString("id")
        let pendingPublication = try #require(try await fixture.pendingTaskPublication(taskId: taskId, channelId: channelId))
        #expect(pendingPublication.deliveredAt == nil)
        let beforeDrain = try await updates.wireFence(since: publicationBoundary)
        #expect(!beforeDrain.contains { $0.hasPrefix("42[\"task:created\"") && $0.contains(taskId) })
        try fixture.resumePublications()
        _ = try await updates.nextText(since: publicationBoundary) {
            $0.hasPrefix("42[\"task:created\"") && $0.contains(taskId)
        }
        try await protocolPGEventually { try await fixture.outbox(pendingPublication.effect.effectID)?.deliveredAt != nil }
        let taskList = try await fixture.http("GET", "/api/tasks/channel/\(channelId)", token: owner)
        #expect(taskList.status == 200)
        #expect(String(decoding: taskList.body, as: UTF8.self).contains(taskId))
        let heldAudit = try await fixture.audit()
        let task = try #require(heldAudit.tasks.first { $0.string("id") == taskId })
        let hostId = try task.requireString("messageId")
        #expect(task.string("status") == "todo")
        #expect(heldAudit.messages.contains { $0.string("id") == hostId && $0.string("content") == "Preserve work while manually stopped" })
        let held = Array((heldAudit.execution.heldDeliveries ?? [:]).values.filter { $0.agentId == agentId })
        #expect(held.count == 2)
        #expect(held.allSatisfy { $0.releasedCommandId == nil && !$0.cancelled })
        #expect(held.allSatisfy { entry in heldAudit.messages.contains { $0.string("id") == entry.messageId } })
        #expect(heldAudit.execution.commands.values.filter { $0.kind == .start }.count == 1)
        #expect(heldAudit.execution.commands.values.filter { $0.kind == .delivery }.isEmpty)
        let suppressedWire = try await peer.socket.wireFence(since: suppressionBoundary)
        let suppressedCommands = suppressedWire.compactMap { try? ProtocolPGObject(text: $0) }.filter {
            $0.string("agentId") == agentId && ["agent:start", "agent:deliver"].contains($0.string("type") ?? "")
        }
        #expect(suppressedCommands.isEmpty)

        let restartBoundary = peer.socket.count
        let restarted = try await fixture.http("POST", "/api/agents/\(agentId)/start", token: member)
        #expect(restarted.status == 200)
        let secondFrame = try await peer.socket.nextObject(since: restartBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == agentId }
        let secondLaunch = try secondFrame.requireString("launchId")
        let secondDispatch = try secondFrame.requireString("startDispatchId")
        let resumed = try await fixture.audit()
        let secondCommand = try #require(resumed.execution.commands.values.first { $0.kind == .start && $0.startDispatchId == secondDispatch })
        #expect(secondLaunch != firstLaunch)
        #expect(secondDispatch != firstDispatch)
        #expect(secondFrame.bool("humanStart") == true)
        #expect(secondFrame.string("connectionEpochId") == epoch)
        #expect(secondFrame.integer("takeoverEpoch") == secondCommand.takeoverEpoch)
        #expect(secondFrame.integer("breakerGeneration") == secondCommand.breakerGeneration)
        #expect(secondCommand.takeoverEpoch > firstCommand.takeoverEpoch)
        #expect(resumed.status(agent: agentId) == "active")
        #expect(resumed.execution.agents[agentId]?.failureCount == 0)
        #expect(resumed.execution.stopIntents?[stopIntent.commandId.uuidString]?.clearedByHumanStart == secondCommand.commandId)
        #expect(resumed.execution.receipts[receipt] == outcomeAudit.execution.receipts[receipt])
        #expect(resumed.execution.watermarks[scope] == 0)
        // The human start carries the oldest held message as its wake input;
        // only the remaining obligations become separate deliveries.
        let restartWakeMessageId = try #require(secondFrame.object("wakeMessage")?.string("message_id"))
        #expect(held.contains { $0.messageId == restartWakeMessageId })
        let restartDeliveries = held.filter { $0.messageId != restartWakeMessageId }
        try await peer.acknowledgeControlledStart(secondFrame)
        // The release gate is the daemon's process identity, not the start ACK:
        // the official daemon buffers deliveries during the start window.
        try await peer.sendProcessSpawned(agentId: agentId, launchId: secondLaunch,
                                          processInstanceId: "protocol-restart-process")
        var received = Set<String>()
        while received.count < restartDeliveries.count {
            let previous = received
            let delivery = try await peer.socket.nextObject(since: restartBoundary) {
                $0.string("type") == "agent:deliver" && $0.string("agentId") == agentId && !previous.contains($0.string("deliveryId") ?? "")
            }
            let deliveryId = try delivery.requireString("deliveryId")
            let released = try await fixture.audit()
            let command = try #require(released.execution.commands.values.first { $0.kind == .delivery && $0.deliveryId == deliveryId })
            let origin = try #require(restartDeliveries.first { released.execution.heldDeliveries?[$0.commandId.uuidString]?.releasedCommandId == command.commandId })
            #expect(command.commandId != origin.commandId)
            #expect(command.launchId == secondLaunch)
            #expect(command.connectionEpochId == epoch)
            #expect(delivery.object("message")?.string("message_id") == origin.messageId)
            let message = try #require(released.messages.first { $0.string("id") == origin.messageId })
            #expect(delivery.integer("seq") == message.integer("seq"))
            #expect(released.execution.dispatches?[command.commandId.uuidString]?.deliverySequence == message.integer("seq"))
            try await peer.acknowledgeControlledDelivery(delivery)
            try await protocolPGEventually { try await fixture.outbox(command.commandId)?.deliveredAt != nil }
            let deliveryAdmission = try await fixture.audit()
            #expect(deliveryAdmission.execution.commands[command.commandId.uuidString]?.status == .accepted)
            #expect(deliveryAdmission.execution.dispatches?[command.commandId.uuidString]?.phase == .accepted)
            received.insert(deliveryId)
        }
        let afterDelivery = try await fixture.audit()
        #expect(afterDelivery.tasks.first { $0.string("id") == taskId }?.string("status") == "todo")
        #expect(afterDelivery.execution.agents[agentId]?.processes["protocol-restart-process"]?.exited == false)

        let noMachineBoundary = peer.socket.count
        let unassignedStop = try await fixture.http("POST", "/api/agents/\(unassignedId)/stop", token: member)
        #expect(unassignedStop.status == 200)
        #expect(String(decoding: unassignedStop.body, as: UTF8.self) == "{\"ok\":true}")
        let noMachine = try await fixture.audit()
        let unassignedIntent = try #require(noMachine.execution.stopIntents?.values.first { $0.agentId == unassignedId })
        #expect(unassignedIntent.machineId == nil)
        #expect(noMachine.status(agent: unassignedId) == "stopped")
        #expect(noMachine.execution.agents[unassignedId] == nil)
        #expect(noMachine.execution.commands.values.filter { $0.agentId == unassignedId }.isEmpty)
        #expect(noMachine.execution.commands.count == afterDelivery.execution.commands.count)
        let absentEffect = try await fixture.outbox(unassignedIntent.commandId)
        #expect(absentEffect == nil)
        let noMachineWire = try await peer.socket.wireFence(since: noMachineBoundary)
        let unassignedFrames = noMachineWire.compactMap { try? ProtocolPGObject(text: $0) }.filter { $0.string("agentId") == unassignedId }
        #expect(unassignedFrames.isEmpty)
        let forbidden = try await fixture.http("POST", "/api/agents/\(unassignedId)/stop", token: outsider)
        #expect(forbidden.status == 403)
        let refusedAudit = try await fixture.audit()
        #expect(refusedAudit.execution.stopIntents?.count == noMachine.execution.stopIntents?.count)
        #expect(refusedAudit.execution.commands.count == noMachine.execution.commands.count)
        #expect(refusedAudit.status(agent: unassignedId) == "stopped")
        // Migrated public authority/mode scenes from the old in-memory HTTP
        // fixtures. This uses the same activated root and actual PG/NIO stack;
        // it does not install an executor, recorder, ready flag or callback.
        let workspaceDenial = #"{"error":"The `resetAgentWorkspace` capability or human creator authority is required to reset agent workspaces"}"#
        let controlDenial = #"{"error":"The `controlAgentRuntime` capability or human creator authority is required to control agents"}"#
        let acceptedReset = #"{"ok":true,"status":"accepted"}"#
        let beforeWorkspaceRefusals = try await fixture.audit()
        for body in [ProtocolPGObject(["mode": .string("full")]), ProtocolPGObject(["clearWorkspace": .bool(true)])] {
            let denied = try await fixture.http("POST", "/api/agents/\(unassignedId)/reset", token: member, body: body)
            #expect(denied.status == 403)
            #expect(String(decoding: denied.body, as: UTF8.self) == workspaceDenial)
        }
        let afterWorkspaceRefusals = try await fixture.audit()
        #expect(afterWorkspaceRefusals.execution.resetIntents?.count == beforeWorkspaceRefusals.execution.resetIntents?.count)
        #expect(afterWorkspaceRefusals.execution.commands.count == beforeWorkspaceRefusals.execution.commands.count)
        #expect(afterWorkspaceRefusals.execution.stopIntents?.count == beforeWorkspaceRefusals.execution.stopIntents?.count)

        // Use a fresh real unassigned agent for each mode. The accepted command
        // can complete locally; this never claims a daemon launch or workspace
        // cleanup for a target that has no Computer.
        let modeCases: [(String, ProtocolPGObject, AgentExecutionResetMode, Bool, String)] = [
            ("restart", .init(["mode": .string("restart")]), .restart, false, member),
            ("session", .init(["mode": .string("session")]), .session, true, member),
            ("unknown-fallback", .init(["mode": .string("bogus")]), .session, true, member),
            ("legacy-session", .init(["clearWorkspace": .bool(false)]), .session, true, member),
            ("empty-fallback", .init([:]), .session, true, member),
            ("legacy-full", .init(["clearWorkspace": .bool(true)]), .full, true, owner),
            ("explicit-full", .init(["mode": .string("full")]), .full, true, owner),
        ]
        let localWireBoundary = peer.socket.count
        var localTargets = Set<String>()
        for (name, body, mode, clearsSession, actor) in modeCases {
            let created = try await fixture.http("POST", "/api/agents", token: owner,
                body: .init(["name": .string("Local reset \(name)"), "runtimeConfig": runtimeConfig]))
            #expect(created.status == 200)
            let target = try created.object().requireString("id")
            localTargets.insert(target)
            let beforeReset = try await fixture.audit()
            let beforeIds = Set((beforeReset.execution.resetIntents ?? [:]).keys)
            let publicationBoundary = updates.count
            let response = try await fixture.http("POST", "/api/agents/\(target)/reset", token: actor, body: body)
            #expect(response.status == 202)
            #expect(String(decoding: response.body, as: UTF8.self) == acceptedReset)
            let resetAudit = try await fixture.audit()
            let intents = (resetAudit.execution.resetIntents ?? [:]).filter { !beforeIds.contains($0.key) }
            #expect(intents.count == 1)
            let intent = try #require(intents.values.first)
            #expect(intent.agentId == target)
            #expect(intent.serverId == fixture.serverId)
            #expect(intent.machineId == nil)
            #expect(intent.mode == mode)
            #expect(intent.restart)
            #expect(intent.phase == .localOnly)
            #expect(intent.sessionCleared == clearsSession)
            #expect(intent.stopAttempt == .notAttempted)
            #expect(intent.workspaceAttempt == .notAttempted)
            #expect(intent.cancelledByStopId == nil)
            #expect(resetAudit.execution.agents[target] == nil)
            #expect(resetAudit.execution.commands.count == beforeReset.execution.commands.count)
            #expect(resetAudit.execution.stopIntents?.count == beforeReset.execution.stopIntents?.count)
            let stopEffect = try await fixture.outbox(intent.stopPhaseId)
            let workspaceEffect = try await fixture.outbox(intent.workspacePhaseId)
            let restartEffect = try await fixture.outbox(intent.restartPhaseId)
            #expect(stopEffect == nil)
            #expect(workspaceEffect == nil)
            #expect(restartEffect == nil)
            if clearsSession {
                _ = try await updates.nextText(since: publicationBoundary) {
                    $0.hasPrefix("42[\"agent:session\"") && $0.contains(target) && $0.contains("\"sessionId\":null")
                }
                try await protocolPGEventually { try await fixture.outbox(intent.sessionPublicationId)?.deliveredAt != nil }
            } else {
                let publication = try await fixture.outbox(intent.sessionPublicationId)
                #expect(publication == nil)
            }
        }
        let localWire = try await peer.socket.wireFence(since: localWireBoundary)
        let localFrames = localWire.compactMap { try? ProtocolPGObject(text: $0) }.filter {
            localTargets.contains($0.string("agentId") ?? "")
        }
        #expect(localFrames.isEmpty)

        // A real connected target proves human_reset through the production
        // worker: stop is actually written, restart uses canonical humanStart,
        // and the peer's ACK settles the new command rather than a fake callback.
        for mode in [AgentExecutionResetMode.session, .restart] {
            let previous = try await fixture.audit()
            let previousIds = Set((previous.execution.resetIntents ?? [:]).keys)
            let previousLaunch = previous.execution.agents[agentId]?.currentLaunchId
            let resetBoundary = peer.socket.count
            let response = try await fixture.http("POST", "/api/agents/\(agentId)/reset", token: member,
                body: .init(["mode": .string(mode.rawValue)]))
            #expect(response.status == 202)
            #expect(String(decoding: response.body, as: UTF8.self) == acceptedReset)
            let admission = try await fixture.audit()
            let added = (admission.execution.resetIntents ?? [:]).filter { !previousIds.contains($0.key) }
            #expect(added.count == 1)
            let intent = try #require(added.values.first)
            #expect(intent.agentId == agentId && intent.serverId == fixture.serverId)
            #expect(intent.machineId == machineId && intent.mode == mode)
            _ = try await peer.socket.nextObject(since: resetBoundary) {
                $0.string("type") == "agent:stop" && $0.string("agentId") == agentId
            }
            let frame = try await peer.socket.nextObject(since: resetBoundary) {
                $0.string("type") == "agent:start" && $0.string("agentId") == agentId
            }
            #expect(frame.bool("humanStart") == true)
            #expect(frame.string("connectionEpochId") == epoch)
            #expect(frame.string("launchId") != previousLaunch)
            let staged = try await fixture.audit()
            let persisted = try #require(staged.execution.resetIntents?[intent.operationId.uuidString])
            #expect(persisted.phase == .restartStaged)
            #expect(persisted.stopAttempt == .written)
            #expect(persisted.workspaceAttempt == .notAttempted)
            #expect(persisted.sessionCleared == (mode != .restart))
            #expect(persisted.cancelledByStopId == nil)
            let command = try #require(staged.execution.commands[intent.startCommandId.uuidString])
            #expect(command.kind == .start && command.humanStart)
            #expect(command.launchId == frame.string("launchId"))
            #expect(command.startDispatchId == frame.string("startDispatchId"))
            #expect(staged.execution.stopIntents?.count == previous.execution.stopIntents?.count)
            try await peer.acknowledgeControlledStart(frame)
            try await protocolPGEventually { try await fixture.outbox(intent.startCommandId)?.deliveredAt != nil }
            try await protocolPGEventually { try await fixture.outbox(intent.stopPhaseId)?.deliveredAt != nil }
            try await protocolPGEventually { try await fixture.outbox(intent.restartPhaseId)?.deliveredAt != nil }
            let settled = try await fixture.audit()
            #expect(settled.execution.commands[intent.startCommandId.uuidString]?.status == .accepted)
            #expect(settled.execution.dispatches?[intent.startCommandId.uuidString]?.phase == .accepted)
            #expect(settled.status(agent: agentId) == "active")
            let workspace = try await fixture.outbox(intent.workspacePhaseId)
            #expect(workspace == nil)
        }

        // Change a real retained membership inside the actual runtime UoW.
        // The same authenticated person must then be denied before any command.
        let memberId = try #require(try await fixture.runtime.execute {
            fixture.accounts.oauth.memberIdsWithRoles(serverId: fixture.serverId).first { $0.role == "member" }?.id
        })
        try await fixture.runtime.execute {
            fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: memberId, role: "guest")
        }
        let guestBoundary = peer.socket.count
        let beforeGuest = try await fixture.audit()
        for verb in ["start", "stop", "reset"] {
            let response = try await fixture.http("POST", "/api/agents/\(agentId)/\(verb)", token: member,
                body: verb == "reset" ? .init(["mode": .string("session")]) : nil)
            #expect(response.status == 403)
            #expect(String(decoding: response.body, as: UTF8.self) == controlDenial)
        }
        let afterGuest = try await fixture.audit()
        #expect(afterGuest.execution.commands.count == beforeGuest.execution.commands.count)
        #expect(afterGuest.execution.resetIntents?.count == beforeGuest.execution.resetIntents?.count)
        #expect(afterGuest.execution.stopIntents?.count == beforeGuest.execution.stopIntents?.count)
        let guestWire = try await peer.socket.wireFence(since: guestBoundary)
        #expect(!guestWire.contains { $0.contains("\"type\":\"agent:start\"") || $0.contains("\"type\":\"agent:stop\"") })
        try await fixture.runtime.execute {
            fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: memberId, role: "member")
        }

        // Real disconnection makes an unsent full reset deterministic. A later
        // public Stop revokes the remaining reset; the real worker must persist
        // cancellation, without inventing workspace cleanup or a restart.
        await peer.socket.close()
        try await protocolPGEventually { try await fixture.audit().execution.connections[machineId]?.online == false }
        let cancelTargetReply = try await fixture.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Offline reset cancellation"), "machineId": .string(machineId), "runtimeConfig": runtimeConfig]))
        #expect(cancelTargetReply.status == 200)
        let cancelTarget = try cancelTargetReply.object().requireString("id")
        let beforeCancel = try await fixture.audit()
        let cancelIds = Set((beforeCancel.execution.resetIntents ?? [:]).keys)
        let reset = try await fixture.http("POST", "/api/agents/\(cancelTarget)/reset", token: owner,
            body: .init(["mode": .string("full")]))
        #expect(reset.status == 202)
        #expect(String(decoding: reset.body, as: UTF8.self) == acceptedReset)
        let pending = try await fixture.audit()
        let cancellation = try #require((pending.execution.resetIntents ?? [:]).first { !cancelIds.contains($0.key) }?.value)
        #expect(cancellation.agentId == cancelTarget && cancellation.phase == .stop)
        #expect(cancellation.stopAttempt == .notAttempted && cancellation.workspaceAttempt == .notAttempted)
        let cancelStop = try await fixture.http("POST", "/api/agents/\(cancelTarget)/stop", token: member)
        #expect(cancelStop.status == 200)
        #expect(String(decoding: cancelStop.body, as: UTF8.self) == "{\"ok\":true,\"appliesOnReconnect\":true}")
        try await protocolPGEventually {
            try await fixture.audit().execution.resetIntents?[cancellation.operationId.uuidString]?.phase == .cancelled
        }
        let cancelled = try await fixture.audit()
        let finalReset = try #require(cancelled.execution.resetIntents?[cancellation.operationId.uuidString])
        #expect(finalReset.mode == .full && finalReset.phase == .cancelled)
        #expect(finalReset.stopAttempt == .notAttempted && finalReset.workspaceAttempt == .notAttempted)
        #expect(finalReset.sessionCleared == false)
        #expect(finalReset.holdReason == nil)
        let cancellingStop = try #require(finalReset.cancelledByStopId)
        #expect(cancelled.execution.stopIntents?[cancellingStop.uuidString]?.agentId == cancelTarget)
        #expect(cancelled.execution.commands[finalReset.startCommandId.uuidString] == nil)
        #expect(cancelled.status(agent: cancelTarget) == "stopped")
        let noWorkspace = try await fixture.outbox(finalReset.workspacePhaseId)
        let noRestart = try await fixture.outbox(finalReset.restartPhaseId)
        #expect(noWorkspace == nil)
        #expect(noRestart == nil)
        // Exact creator authority survives Admin -> Member -> Guest demotion.
        // The target is created through HTTP by that actual actor, in this same
        // retained PG root. Its unassigned local-only control semantics match
        // the old RBAC fixture; no Computer execution or cleanup is claimed.
        try await fixture.runtime.execute {
            fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: memberId, role: "admin")
        }
        let creatorReply = try await fixture.http("POST", "/api/agents", token: member,
            body: .init(["name": .string("Exact creator demotion target"), "runtimeConfig": runtimeConfig]))
        #expect(creatorReply.status == 200)
        let creatorTarget = try creatorReply.object().requireString("id")
        let creatorAudit = try await fixture.audit()
        #expect(creatorAudit.canonicalAgents.object(creatorTarget)?.string("creatorUserId") == memberId)

        func assertCreatorLocalControls(token: String) async throws {
            let before = try await fixture.audit()
            let stopIds = Set((before.execution.stopIntents ?? [:]).keys)
            let stopped = try await fixture.http("POST", "/api/agents/\(creatorTarget)/stop", token: token)
            #expect(stopped.status == 200)
            #expect(String(decoding: stopped.body, as: UTF8.self) == "{\"ok\":true}")
            let stoppedAudit = try await fixture.audit()
            let stops = (stoppedAudit.execution.stopIntents ?? [:]).filter { !stopIds.contains($0.key) }
            #expect(stops.count == 1)
            let stop = try #require(stops.values.first)
            #expect(stop.agentId == creatorTarget && stop.serverId == fixture.serverId)
            #expect(stop.machineId == nil)
            #expect(stoppedAudit.status(agent: creatorTarget) == "stopped")
            #expect(stoppedAudit.execution.commands.count == before.execution.commands.count)
            let noStopEffect = try await fixture.outbox(stop.commandId)
            #expect(noStopEffect == nil)

            let resetIds = Set((stoppedAudit.execution.resetIntents ?? [:]).keys)
            let publicationBoundary = updates.count
            let reset = try await fixture.http("POST", "/api/agents/\(creatorTarget)/reset", token: token,
                body: .init(["mode": .string("full")]))
            #expect(reset.status == 202)
            #expect(String(decoding: reset.body, as: UTF8.self) == acceptedReset)
            let resetAudit = try await fixture.audit()
            let resets = (resetAudit.execution.resetIntents ?? [:]).filter { !resetIds.contains($0.key) }
            #expect(resets.count == 1)
            let intent = try #require(resets.values.first)
            #expect(intent.agentId == creatorTarget && intent.serverId == fixture.serverId)
            #expect(intent.machineId == nil && intent.mode == .full)
            #expect(intent.phase == .localOnly && intent.sessionCleared)
            #expect(intent.stopAttempt == .notAttempted && intent.workspaceAttempt == .notAttempted)
            #expect(intent.cancelledByStopId == nil && intent.holdReason == nil)
            #expect(resetAudit.execution.commands.count == stoppedAudit.execution.commands.count)
            #expect(resetAudit.execution.stopIntents?.count == stoppedAudit.execution.stopIntents?.count)
            #expect(resetAudit.execution.agents[creatorTarget] == nil)
            #expect(resetAudit.canonicalAgents.object(creatorTarget)?.string("creatorUserId") == memberId)
            let noStop = try await fixture.outbox(intent.stopPhaseId)
            let noWorkspace = try await fixture.outbox(intent.workspacePhaseId)
            let noRestart = try await fixture.outbox(intent.restartPhaseId)
            #expect(noStop == nil && noWorkspace == nil && noRestart == nil)
            _ = try await updates.nextText(since: publicationBoundary) {
                $0.hasPrefix("42[\"agent:session\"") && $0.contains(creatorTarget) && $0.contains("\"sessionId\":null")
            }
            try await protocolPGEventually { try await fixture.outbox(intent.sessionPublicationId)?.deliveredAt != nil }
        }

        for role in ["member", "guest"] {
            try await fixture.runtime.execute {
                fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: memberId, role: role)
            }
            try await assertCreatorLocalControls(token: member)
            // Creator authority is exact: the same actor still cannot reset the
            // owner-created agent's workspace, even though its own command202
            // committed immediately before this request.
            let beforeOther = try await fixture.audit()
            let other = try await fixture.http("POST", "/api/agents/\(agentId)/reset", token: member,
                body: .init(["mode": .string("full")]))
            #expect(other.status == 403)
            let afterOther = try await fixture.audit()
            #expect(afterOther.execution.commands.count == beforeOther.execution.commands.count)
            #expect(afterOther.execution.resetIntents?.count == beforeOther.execution.resetIntents?.count)
            #expect(afterOther.execution.stopIntents?.count == beforeOther.execution.stopIntents?.count)
        }

        // Depart through the public membership route. The creator relation
        // remains stored, but the stale authenticated actor loses all control.
        let removed = try await fixture.http("DELETE", "/api/servers/\(fixture.serverId)/members/\(memberId)", token: owner)
        #expect(removed.status == 200)
        let currentMembership = try await fixture.runtime.execute {
            fixture.accounts.oauth.memberRole(serverId: fixture.serverId, userId: memberId)
        }
        #expect(currentMembership == nil)
        let beforeDepartureRefusals = try await fixture.audit()
        #expect(beforeDepartureRefusals.canonicalAgents.object(creatorTarget)?.string("creatorUserId") == memberId)
        for verb in ["stop", "reset"] {
            let denied = try await fixture.http("POST", "/api/agents/\(creatorTarget)/\(verb)", token: member,
                body: verb == "reset" ? .init(["mode": .string("full")]) : .init([:]))
            #expect(denied.status == 403)
            #expect(String(decoding: denied.body, as: UTF8.self) == #"{"error":"Not a member of this server"}"#)
        }
        let afterDepartureRefusals = try await fixture.audit()
        #expect(afterDepartureRefusals.execution.commands.count == beforeDepartureRefusals.execution.commands.count)
        #expect(afterDepartureRefusals.execution.resetIntents?.count == beforeDepartureRefusals.execution.resetIntents?.count)
        #expect(afterDepartureRefusals.execution.stopIntents?.count == beforeDepartureRefusals.execution.stopIntents?.count)
        #expect(afterDepartureRefusals.canonicalAgents.object(creatorTarget)?.string("creatorUserId") == memberId)
        // A still-authorized actor controls the very same live target, so the
        // departed creator's403 cannot be a missing/deleted-agent artifact.
        try await assertCreatorLocalControls(token: owner)
    } catch {
        await fixture.close(machine: machine, subscriber: subscriber); throw error
    }
    await fixture.close(machine: machine, subscriber: subscriber)
}
