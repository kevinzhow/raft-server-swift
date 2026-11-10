import Foundation
import RaftShared

extension AgentExecutionDomain {
    func beginResetPhase(_ reference: AgentExecutionResetReference, context: AgentExecutionMachineContext) throws -> AgentExecutionResetDispatchAdmission {
        try requireTransaction()
        switch try reconcileReset(reference) {
        case .settled: return .alreadyWritten
        case .cancelled: return .cancelled
        case .hold(let reason):
            return try holdReset(reference, reason: reason)
        case .wait: throw AgentExecutionError.machineNotReady
        case .ready(let control):
            guard control.context == context, reference.phase != .restart else { throw AgentExecutionError.staleConnection }
        }
        try mutate { state in
            guard var intent = state.resetIntents?[reference.resetOperationId.uuidString],
                  resetFence(intent, context: context, state: state), intent.attempt(reference.phase) == .notAttempted else {
                throw AgentExecutionError.staleConnection
            }
            intent.connectionEpochId = context.connectionEpochId
            intent.daemonInstanceId = state.connections[context.machineId]?.daemonInstanceId
            if reference.phase == .stop { intent.stopAttempt = .attempting } else { intent.workspaceAttempt = .attempting }
            state.resetIntents?[intent.operationId.uuidString] = intent
        }
        return .granted
    }

    /// Revalidate through the same BPR after recording the attempt and directly
    /// before the external write. The registry independently fences the epoch.
    func validateResetWrite(_ reference: AgentExecutionResetReference, context: AgentExecutionMachineContext) throws {
        try requireTransaction()
        let state = agents.state.execution
        guard let intent = state.resetIntents?[reference.resetOperationId.uuidString], intent.reference(reference.phase) == reference,
              !agents.hasActiveMigration(agentId: intent.agentId),
              (try? boundMachine(serverId: intent.serverId, agentId: intent.agentId)) == context.machineId,
              intent.phase.rawValue == reference.phase.rawValue, intent.attempt(reference.phase) == .attempting,
              resetFence(intent, context: context, state: state) else { throw AgentExecutionError.staleConnection }
    }

    /// Idempotence is checked before the current fence: an old already-written
    /// phase is settled after a failed outbox ACK, never written a second time.
    func noteResetControlWritten(_ reference: AgentExecutionResetReference, context: AgentExecutionMachineContext) throws {
        try requireTransaction()
        guard let previous = agents.state.execution.resetIntents?[reference.resetOperationId.uuidString],
              previous.reference(reference.phase) == reference else { throw AgentExecutionError.invalidRequest }
        if previous.attempt(reference.phase) == .written { return }
        try validateResetWrite(reference, context: context)
        try mutate { state in
            if reference.phase == .stop { state.resetIntents?[previous.operationId.uuidString]?.stopAttempt = .written }
            else { state.resetIntents?[previous.operationId.uuidString]?.workspaceAttempt = .written }
        }
        do {
            if reference.phase == .stop { try liftAndClearReset(previous.operationId) }
            let next = try mutate { state -> AgentExecutionResetReference? in
                guard var intent = state.resetIntents?[previous.operationId.uuidString] else { throw AgentExecutionError.invalidRequest }
                if reference.phase == .stop && intent.effectiveMode == .full { intent.phase = .workspace }
                else { intent.phase = intent.restart ? .restart : .dispatched }
                state.resetIntents?[intent.operationId.uuidString] = intent
                if intent.phase == .workspace { return intent.reference(.workspace) }
                if intent.phase == .restart { return intent.reference(.restart) }
                return nil
            }
            if let next { try stageReset(next) }
        } catch { DeferredEffects.markRollbackOnly(); throw error }
    }

    func holdReset(_ reference: AgentExecutionResetReference, reason: String) throws -> AgentExecutionResetDispatchAdmission {
        try requireTransaction()
        if try reconcileReset(reference) == .cancelled { return .cancelled }
        return try mutate { state in
            guard var intent = state.resetIntents?[reference.resetOperationId.uuidString], intent.reference(reference.phase) == reference else {
                throw AgentExecutionError.invalidRequest
            }
            if intent.attempt(reference.phase) == .written { return .alreadyWritten }
            // Never downgrade persisted written history because markDelivered
            // failed separately, and never replay an unconfirmed control.
            if intent.stopAttempt == .attempting { intent.stopAttempt = .ambiguous }
            if intent.workspaceAttempt == .attempting { intent.workspaceAttempt = .ambiguous }
            intent.phase = .held
            intent.holdReason = reason
            state.resetIntents?[intent.operationId.uuidString] = intent
            if state.agents[intent.agentId]?.generation == intent.expectedGeneration {
                state.agents[intent.agentId]?.needsManual = "reset_dispatch_unconfirmed"
            }
            return .uncertain
        }
    }

    func stageResetRestart(_ reference: AgentExecutionResetReference, context: AgentExecutionMachineContext) throws -> Bool {
        try requireTransaction()
        guard reference.phase == .restart else { throw AgentExecutionError.invalidRequest }
        switch try reconcileReset(reference) {
        case .settled: return true
        case .cancelled: return false
        case .wait: return false
        case .hold(let reason): _ = try holdReset(reference, reason: reason); return false
        case .ready(let control): guard control.context == context else { throw AgentExecutionError.staleConnection }
        }
        guard let intent = agents.state.execution.resetIntents?[reference.resetOperationId.uuidString],
              intent.stopAttempt == .written, intent.effectiveMode != .full || intent.workspaceAttempt == .written else {
            throw AgentExecutionError.invalidRequest
        }
        do {
            try mutate { $0.resetIntents?[intent.operationId.uuidString]?.phase = .restartStaged }
            // Reuse the canonical producer, including its normal new-launch
            // generation increment. Only an actual E3 control authorizes human
            // takeover; a settings no-op stays automatic.
            let admission = try requestStart(.init(commandId: intent.startCommandId, serverId: intent.serverId,
                                                   agentId: intent.agentId, control: intent.usesHumanStart ? .humanStart : .automatic))
            if !intent.usesHumanStart {
                guard let start = agents.state.execution.commands[admission.commandId.uuidString],
                      start.commandId == intent.startCommandId, start.kind == .start, !start.humanStart,
                      start.serverId == intent.serverId, start.agentId == intent.agentId else {
                    throw AgentExecutionError.invalidRequest
                }
                // The automatic admission already checked manual-stop/failure
                // fences. Reuse the owned producer to recheck delivery authority
                // and persist replacement references in this same transaction.
                try releaseHeldDeliveries(start: start)
                // Active is canonical running-allowed intent after admission,
                // never a claim that a process or provider became ready.
                setIntentStatus(agentId: intent.agentId, status: "active")
            }
            return true
        } catch { DeferredEffects.markRollbackOnly(); throw error }
    }
}
