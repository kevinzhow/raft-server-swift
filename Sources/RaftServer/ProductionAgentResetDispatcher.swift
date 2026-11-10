import Foundation
import RaftHTTP
import RaftMachineSocket
import RaftPersistence

/// Uses the existing serial agent.execution consumer and the same fenced BPR.
/// The workspace protocol has no ACK: written never means cleanup confirmed.
struct ProductionAgentResetDispatcher: Sendable {
    let runtime: BusinessPersistenceRuntime
    let execution: AgentExecutionService
    let registry: MachineCommandRegistry

    private func finish(_ claim: DurableOutboxClaim, admission: AgentExecutionResetDispatchAdmission) async throws {
        switch admission {
        case .alreadyWritten: try await runtime.markDelivered(claim)
        case .cancelled: try await runtime.recordFailure(claim, code: .cancelled)
        case .uncertain: try await runtime.recordFailure(claim, code: .unknownOutcome)
        case .granted: throw ProductionStartupError.agentExecutionNotConnected
        }
    }

    func consume(_ claim: DurableOutboxClaim, reference: AgentExecutionResetReference) async throws {
        let control: AgentExecutionResetControl
        switch try await execution.reconcileReset(reference: reference) {
        case .settled:
            try await runtime.markDelivered(claim)
            return
        case .cancelled:
            try await runtime.recordFailure(claim, code: .cancelled)
            return
        case .wait:
            try await runtime.deferOutbox(claim, retryAfterSeconds: 5)
            return
        case .hold(let reason):
            if reason == "reset_reference_missing" {
                try await runtime.recordFailure(claim, code: .rejected)
                return
            }
            let result = try await execution.noteResetAmbiguous(reference: reference)
            try await finish(claim, admission: result)
            return
        case .ready(let resolved): control = resolved
        }
        guard runtime.readinessSnapshot.isReady,
              await registry.connectionEpoch(machineId: control.context.machineId) == control.context.connectionEpochId else {
            try await runtime.deferOutbox(claim, retryAfterSeconds: 5)
            return
        }
        if reference.phase == .restart {
            if try await execution.stageResetRestart(reference: reference, context: control.context) {
                try await runtime.markDelivered(claim)
            } else if try await execution.reconcileReset(reference: reference) == .cancelled {
                try await runtime.recordFailure(claim, code: .cancelled)
            } else { try await runtime.deferOutbox(claim, retryAfterSeconds: 5) }
            return
        }
        let admission = try await execution.beginResetPhase(reference: reference, context: control.context)
        guard admission == .granted else {
            try await finish(claim, admission: admission)
            return
        }
        do {
            try Task.checkCancellation()
            try await execution.validateResetWrite(reference: reference, context: control.context)
            guard runtime.readinessSnapshot.isReady else { throw ProductionStartupError.unavailable }
            switch reference.phase {
            case .stop:
                try await registry.sendStop(machineId: control.context.machineId, agentId: control.agentId,
                                            connectionEpochId: control.context.connectionEpochId)
            case .workspace:
                try await registry.sendWorkspaceReset(machineId: control.context.machineId, agentId: control.agentId,
                                                      connectionEpochId: control.context.connectionEpochId)
            case .restart: throw ProductionStartupError.agentExecutionNotConnected
            }
            try await execution.noteResetControlWritten(reference: reference, context: control.context)
        } catch {
            // A durable attempt permission makes the send outcome uncertain.
            // Written history is settled, never downgraded or blindly replayed.
            let result = try await execution.noteResetAmbiguous(reference: reference)
            try await finish(claim, admission: result)
            return
        }
        // Keep outbox ACK outside the I/O catch, so a failed ACK cannot resend.
        try await runtime.markDelivered(claim)
    }
}
