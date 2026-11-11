import Foundation

extension AgentExecutionState {
    private func validateControlFacts() throws {
        for (key, intent) in stopIntents ?? [:] {
            guard key == intent.commandId.uuidString, !intent.serverId.isEmpty, !intent.agentId.isEmpty,
                  intent.machineId.map({ !$0.isEmpty }) ?? true else { throw RuntimePersistenceError.invalidSnapshot }
            if let machine = intent.machineId {
                guard let command = commands[key], command.kind == .stop, command.machineId == machine,
                      command.serverId == intent.serverId, command.agentId == intent.agentId else { throw RuntimePersistenceError.invalidSnapshot }
            } else if commands[key] != nil { throw RuntimePersistenceError.invalidSnapshot }
            if let epoch = intent.retiredByAssignmentEpoch {
                guard let command = commands[key], command.kind == .stop, command.status == .superseded,
                      command.breakerGeneration == 0, dispatches?[key] == nil,
                      let owner = agents[intent.agentId], owner.serverId == intent.serverId,
                      epoch > command.takeoverEpoch, epoch <= owner.takeoverEpoch,
                      epoch <= 9_007_199_254_740_991 else { throw RuntimePersistenceError.invalidSnapshot }
            }
            if let cleared = intent.clearedByHumanStart {
                guard let command = commands[cleared.uuidString], command.kind == .start, command.humanStart,
                      command.serverId == intent.serverId, command.agentId == intent.agentId else { throw RuntimePersistenceError.invalidSnapshot }
            }
        }
        for (key, pending) in pendingHumanDeliveries ?? [:] {
            guard key == Self.key(pending.serverId, pending.agentId, pending.channelId, pending.messageId),
                  !pending.serverId.isEmpty, !pending.agentId.isEmpty,
                  !pending.channelId.isEmpty, !pending.messageId.isEmpty else {
                throw RuntimePersistenceError.invalidSnapshot
            }
            if let released = pending.releasedCommandId {
                guard let command = commands[released.uuidString], command.serverId == pending.serverId,
                      command.agentId == pending.agentId,
                      command.kind == .delivery || command.kind == .start else {
                    throw RuntimePersistenceError.invalidSnapshot
                }
                if command.kind == .delivery {
                    guard command.channelId == pending.channelId, command.messageId == pending.messageId else {
                        throw RuntimePersistenceError.invalidSnapshot
                    }
                } else {
                    // Upstream `attempt-wake`: the queued message rides the
                    // start itself instead of a separate agent:deliver.
                    guard command.wakeMessage?.channelId == pending.channelId,
                          command.wakeMessage?.messageId == pending.messageId else {
                        throw RuntimePersistenceError.invalidSnapshot
                    }
                }
            }
        }
        for (key, held) in heldDeliveries ?? [:] {
            guard key == held.commandId.uuidString, !held.serverId.isEmpty, !held.agentId.isEmpty,
                  !held.channelId.isEmpty, !held.messageId.isEmpty, stopIntents?[key] == nil,
                  !(held.cancelled && held.releasedCommandId != nil) else { throw RuntimePersistenceError.invalidSnapshot }
            if let original = commands[key] {
                guard original.kind == .delivery, original.serverId == held.serverId, original.agentId == held.agentId,
                      original.channelId == held.channelId, original.messageId == held.messageId else { throw RuntimePersistenceError.invalidSnapshot }
            }
            if let released = held.releasedCommandId {
                guard released != held.commandId, let command = commands[released.uuidString],
                      command.serverId == held.serverId, command.agentId == held.agentId,
                      command.kind == .delivery || command.kind == .start else { throw RuntimePersistenceError.invalidSnapshot }
                if command.kind == .delivery {
                    guard command.channelId == held.channelId, command.messageId == held.messageId else {
                        throw RuntimePersistenceError.invalidSnapshot
                    }
                } else {
                    guard command.wakeMessage?.channelId == held.channelId,
                          command.wakeMessage?.messageId == held.messageId else {
                        throw RuntimePersistenceError.invalidSnapshot
                    }
                }
            } else if !held.cancelled && dispatches?[key] != nil {
                // An ambiguous or accepted write can never become unsent work.
                throw RuntimePersistenceError.invalidSnapshot
            }
        }
    }

    private func validateResetFacts() throws {
        var active = Set<String>()
        for (key, reset) in resetIntents ?? [:] {
            let identifiers = [reset.operationId, reset.stopPhaseId, reset.workspacePhaseId, reset.restartPhaseId,
                               reset.startCommandId, reset.sessionPublicationId]
            guard key == reset.operationId.uuidString, Set(identifiers).count == identifiers.count,
                  !reset.serverId.isEmpty, !reset.agentId.isEmpty, reset.machineId.map({ !$0.isEmpty }) ?? true,
                  (0...9_007_199_254_740_991).contains(reset.expectedGeneration),
                  (0...9_007_199_254_740_991).contains(reset.expectedTakeoverEpoch),
                  stopIntents?[key] == nil, heldDeliveries?[key] == nil, commands[key] == nil else {
                throw RuntimePersistenceError.invalidSnapshot
            }
            if reset.phase.isActive {
                guard active.insert(Self.key(reset.serverId, reset.agentId)).inserted else { throw RuntimePersistenceError.invalidSnapshot }
            }
            for id in [reset.stopPhaseId, reset.workspacePhaseId, reset.restartPhaseId] {
                guard commands[id.uuidString] == nil, stopIntents?[id.uuidString] == nil,
                      heldDeliveries?[id.uuidString] == nil else { throw RuntimePersistenceError.invalidSnapshot }
            }
            if reset.stopAttempt != .notAttempted || reset.workspaceAttempt != .notAttempted {
                guard reset.machineId != nil, reset.connectionEpochId?.isEmpty == false else { throw RuntimePersistenceError.invalidSnapshot }
            }
            if reset.workspaceAttempt != .notAttempted || reset.phase == .workspace {
                guard reset.effectiveMode == .full, reset.stopAttempt == .written else { throw RuntimePersistenceError.invalidSnapshot }
            }
            if reset.phase == .restart || reset.phase == .restartStaged || reset.phase == .dispatched {
                guard reset.stopAttempt == .written, reset.effectiveMode != .full || reset.workspaceAttempt == .written else {
                    throw RuntimePersistenceError.invalidSnapshot
                }
            }
            if reset.phase == .restartStaged {
                guard reset.restart, let start = commands[reset.startCommandId.uuidString], start.kind == .start,
                      start.humanStart == reset.usesHumanStart, start.serverId == reset.serverId, start.agentId == reset.agentId,
                       start.machineId == reset.machineId, reset.effectiveMode == .restart || start.sessionId == nil else { throw RuntimePersistenceError.invalidSnapshot }
            }
            if reset.sessionCleared {
                guard reset.effectiveMode != .restart, reset.stopAttempt == .written || reset.machineId == nil else { throw RuntimePersistenceError.invalidSnapshot }
            }
            if reset.phase == .cancelled {
                guard !reset.hasUnconfirmedControl, let stopId = reset.cancelledByStopId,
                      let stop = stopIntents?[stopId.uuidString], stop.agentId == reset.agentId, stop.serverId == reset.serverId,
                      !reset.priorStopIntentIds.contains(stopId), reset.holdReason == nil,
                      commands[reset.startCommandId.uuidString] == nil else { throw RuntimePersistenceError.invalidSnapshot }
            } else if reset.cancelledByStopId != nil { throw RuntimePersistenceError.invalidSnapshot }
            if reset.phase == .stop, reset.stopAttempt == .written { throw RuntimePersistenceError.invalidSnapshot }
            if reset.phase == .workspace, reset.workspaceAttempt == .written { throw RuntimePersistenceError.invalidSnapshot }
            if reset.stopAttempt == .ambiguous || reset.workspaceAttempt == .ambiguous {
                guard reset.phase == .held else { throw RuntimePersistenceError.invalidSnapshot }
            }
            if reset.phase == .restart || reset.phase == .restartStaged {
                guard reset.restart else { throw RuntimePersistenceError.invalidSnapshot }
            }
            if reset.phase == .dispatched, reset.restart { throw RuntimePersistenceError.invalidSnapshot }
            if reset.phase == .localOnly {
                guard reset.machineId == nil, reset.stopAttempt == .notAttempted, reset.workspaceAttempt == .notAttempted,
                      reset.connectionEpochId == nil, commands[reset.startCommandId.uuidString] == nil else { throw RuntimePersistenceError.invalidSnapshot }
            }
            if reset.effectiveMode != .restart && (reset.phase == .workspace || reset.phase == .restart || reset.phase == .restartStaged
                || reset.phase == .dispatched || reset.phase == .localOnly) {
                guard reset.sessionCleared else { throw RuntimePersistenceError.invalidSnapshot }
            }
        }
    }

    /// Fail startup/commit closed rather than accepting a decoded but internally
    /// inconsistent receipt, launch or connection graph. Errors carry no data.
    func validate() throws {
        try validateControlFacts()
        try validateResetFacts()
        let maximum: Int64 = 9_007_199_254_740_991
        func validCount(_ value: Int64) -> Bool { value >= 0 && value <= maximum }
        func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard watermarks.values.allSatisfy(validCount), receipts.values.allSatisfy(digest) else {
            throw RuntimePersistenceError.invalidSnapshot
        }
        for (machineId, connection) in connections {
            guard !machineId.isEmpty, !connection.serverId.isEmpty, !connection.connectionEpochId.isEmpty,
                  connection.runtimes.allSatisfy({ !$0.isEmpty }), connection.capabilities?.allSatisfy({ !$0.isEmpty }) ?? true,
                  !connection.ready || (connection.online && connection.daemonInstanceId?.isEmpty == false && connection.runtimes.contains("codex")) else {
                throw RuntimePersistenceError.invalidSnapshot
            }
        }
        for (agentId, agent) in agents {
            guard !agentId.isEmpty, !agent.serverId.isEmpty, !agent.machineId.isEmpty,
                  validCount(agent.takeoverEpoch), validCount(agent.generation),
                  validCount(Int64(agent.failureCount)), validCount(Int64(agent.sameFingerprintCount)), (0...6).contains(agent.backoffStep),
                  agent.sameFingerprint.map(digest) ?? true,
                  agent.currentLaunchId.map({ agent.launches[$0] != nil }) ?? true else {
                throw RuntimePersistenceError.invalidSnapshot
            }
            for (launchId, launch) in agent.launches {
                guard launchId == launch.launchId, !launchId.isEmpty, !launch.startDispatchId.isEmpty,
                      !launch.daemonInstanceId.isEmpty, !launch.connectionEpochId.isEmpty,
                      validCount(launch.generation), launch.generation <= agent.generation,
                      validCount(launch.takeoverEpoch), launch.takeoverEpoch <= agent.takeoverEpoch,
                      launch.runnerCredentialId.map({ !$0.isEmpty }) ?? true,
                      !(launch.completed && launch.notSpawned) else { throw RuntimePersistenceError.invalidSnapshot }
                for commandId in launch.inFlightDeliveryCommandIds ?? [] {
                    guard let command = commands[commandId.uuidString], command.kind == .delivery,
                          command.agentId == agentId, command.launchId == launchId else {
                        throw RuntimePersistenceError.invalidSnapshot
                    }
                }
            }
            for (processId, process) in agent.processes {
                guard processId == process.processInstanceId, !processId.isEmpty, !process.daemonInstanceId.isEmpty,
                      !process.launchIds.isEmpty,
                      process.launchIds.allSatisfy({ agent.launches[$0] != nil }),
                      process.spawnLaunchId.map({ agent.launches[$0] != nil }) ?? true else {
                    throw RuntimePersistenceError.invalidSnapshot
                }
            }
        }
        for (key, dispatch) in dispatches ?? [:] {
            guard let command = commands[key], !dispatch.connectionEpochId.isEmpty,
                  command.kind == .stop || command.connectionEpochId == dispatch.connectionEpochId else { throw RuntimePersistenceError.invalidSnapshot }
            if command.kind == .delivery {
                guard let sequence = dispatch.deliverySequence, validCount(sequence) else { throw RuntimePersistenceError.invalidSnapshot }
            } else if command.kind == .notice {
                // The synthetic notice envelope always acknowledges at seq 0.
                guard dispatch.deliverySequence == 0 else { throw RuntimePersistenceError.invalidSnapshot }
            } else if dispatch.deliverySequence != nil {
                throw RuntimePersistenceError.invalidSnapshot
            }
        }
        for (key, command) in commands {
            guard key == command.commandId.uuidString, !command.serverId.isEmpty, !command.agentId.isEmpty,
                  !command.machineId.isEmpty, !command.launchId.isEmpty,
                  validCount(command.takeoverEpoch), validCount(command.breakerGeneration),
                  let owner = agents[command.agentId], owner.serverId == command.serverId else {
                throw RuntimePersistenceError.invalidSnapshot
            }
            // Only the validated receipt-backed retirement of an unattempted
            // Stop can retain a machine different from today's execution owner.
            let retiredUnsentStop = command.kind == .stop && command.status == .superseded
                && dispatches?[key] == nil && stopIntents?[key]?.retiredByAssignmentEpoch != nil
            guard owner.machineId == command.machineId || retiredUnsentStop else { throw RuntimePersistenceError.invalidSnapshot }
            if command.kind != .stop {
                guard owner.launches[command.launchId] != nil, !command.connectionEpochId.isEmpty else { throw RuntimePersistenceError.invalidSnapshot }
            }
            if command.kind == .start, command.startDispatchId?.isEmpty != false { throw RuntimePersistenceError.invalidSnapshot }
            if let wake = command.wakeMessage {
                // Upstream attempt-wake input: only a start may carry it, and it
                // names exactly one canonical message.
                guard command.kind == .start, !wake.channelId.isEmpty, !wake.messageId.isEmpty,
                      command.channelId == nil, command.messageId == nil else {
                    throw RuntimePersistenceError.invalidSnapshot
                }
            }
            if command.kind == .delivery {
                guard command.deliveryId?.isEmpty == false, command.channelId?.isEmpty == false,
                      command.messageId?.isEmpty == false else { throw RuntimePersistenceError.invalidSnapshot }
                // A tracked mention delivery is fenced to exactly one frozen
                // occurrence, and that occurrence id IS the delivery id upstream.
                if let occurrenceId = command.mentionDeliveryOccurrenceId {
                    guard !occurrenceId.isEmpty, command.deliveryId == occurrenceId else {
                        throw RuntimePersistenceError.invalidSnapshot
                    }
                }
            } else if command.mentionDeliveryOccurrenceId != nil {
                throw RuntimePersistenceError.invalidSnapshot
            }
            if command.kind == .notice {
                guard command.deliveryId?.isEmpty == false, command.channelId?.isEmpty == false,
                      command.messageId?.isEmpty == false, command.notice != nil else {
                    throw RuntimePersistenceError.invalidSnapshot
                }
            }
        }
    }
}
