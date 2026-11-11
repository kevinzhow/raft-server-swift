import Foundation
import RaftHTTP
import RaftMachineSocket
import RaftPersistence

/// Exactly one serial consumer per production graph. All SQL operations use the
/// existing fenced runtime. Network/model execution belongs to raft-computer.
struct ProductionAgentExecutionWorker: Sendable {
    private let task: Task<Void, Never>

    init(runtime: BusinessPersistenceRuntime, execution: AgentExecutionService,
         materializer: AgentExecutionMaterializationService, registry: MachineCommandRegistry) throws {
        let kind = try DurableEffectKind("agent.execution")
        let dispatcher = ProductionAgentExecutionDispatcher(runtime: runtime, execution: execution,
                                                            materializer: materializer, registry: registry)
        task = Task.detached {
            while !Task.isCancelled {
                do {
                    let claims = try await runtime.claimOutbox(kinds: [kind], limit: 1, visibilityTimeoutSeconds: 90)
                    guard let claim = claims.first else {
                        try await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    try await dispatcher.consume(claim)
                } catch {
                    if Task.isCancelled || !runtime.readinessSnapshot.isReady { return }
                    // Errors and rejected daemon JSON can contain credentials or
                    // user content. No executor error/payload is logged here.
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    func stop() async {
        task.cancel()
        await task.value
    }
}

struct ProductionAgentExecutionDispatcher: Sendable {
    let runtime: BusinessPersistenceRuntime
    let execution: AgentExecutionService
    let materializer: AgentExecutionMaterializationService
    let registry: MachineCommandRegistry

    func consume(_ claim: DurableOutboxClaim) async throws {
        let effect = claim.entry.effect
        guard effect.kind.rawValue == "agent.execution" else { throw ProductionStartupError.agentExecutionNotConnected }
        if let reset = try? JSONDecoder().decode(AgentExecutionResetReference.self, from: effect.payload) {
            guard reset.phaseId == effect.effectID else { try await runtime.recordFailure(claim, code: .rejected); return }
            try await ProductionAgentResetDispatcher(runtime: runtime, execution: execution, registry: registry).consume(claim, reference: reset)
            return
        }
        guard let reference = try? JSONDecoder().decode(AgentExecutionIntentReference.self, from: effect.payload),
              reference.commandId == effect.effectID else {
            try await runtime.recordFailure(claim, code: .rejected)
            return
        }
        let command: AgentExecutionCommand
        switch try execution.resolveDispatch(reference: reference) {
        case .wait:
            try await runtime.deferOutbox(claim, retryAfterSeconds: 5)
            return
        case .obsolete:
            try await settleOrReject(claim, reference: reference)
            return
        case .ready(let resolved): command = resolved
        }
        let context = AgentExecutionMachineContext(machineId: command.machineId, serverId: command.serverId,
                                                   connectionEpochId: command.connectionEpochId)
        let prepared: MachineCommand?
        let sequence: Int64?
        if command.kind == .stop {
            prepared = nil
            sequence = nil
        } else {
            guard await registry.isExecutionReady(machineId: command.machineId, runtime: "codex"),
                  await registry.connectionEpoch(machineId: command.machineId) == command.connectionEpochId else {
                try await runtime.deferOutbox(claim, retryAfterSeconds: 5)
                return
            }
            do {
                let body = try await materializer.materialize(command: command)
                let data: Data
                switch (command.kind, body) {
                case (.start, .start(let configuration, let resumeMessages, let unreadSummary)):
                    data = try ProductionAgentExecutionWire.start(
                        command, configuration: configuration, resumeMessages: resumeMessages,
                        unreadSummary: unreadSummary)
                    sequence = nil
                case (.delivery, .delivery(let message, let actualSequence, let mentionDelivery)):
                    data = try ProductionAgentExecutionWire.delivery(
                        command, message: message, sequence: actualSequence, mentionDelivery: mentionDelivery)
                    sequence = actualSequence
                case (.notice, .notice(let message)):
                    data = try ProductionAgentExecutionWire.notice(command, message: message)
                    sequence = 0
                default: throw ProductionStartupError.agentExecutionNotConnected
                }
                prepared = try MachineCommand(json: String(decoding: data, as: UTF8.self),
                                              expectedConnectionEpochId: command.connectionEpochId)
            } catch {
                try await runtime.recordFailure(claim, code: Task.isCancelled ? .cancelled : .rejected)
                return
            }
        }
        // Materialization can await another transaction. Neither its credentials
        // nor an old committed read authorize sending after a takeover/reconnect.
        switch try execution.resolveDispatch(reference: reference) {
        case .wait:
            try await runtime.deferOutbox(claim, retryAfterSeconds: 5)
            return
        case .obsolete:
            try await settleOrReject(claim, reference: reference)
            return
        case .ready(let current):
            guard current == command else {
                try await runtime.deferOutbox(claim, retryAfterSeconds: 5)
                return
            }
        }
        let admission: AgentExecutionDispatchAdmission
        do {
            admission = try await execution.beginDispatch(reference: reference, context: context, deliverySequence: sequence)
        } catch let refusal as AgentExecutionError {
            switch refusal {
            case .machineNotReady, .staleConnection, .dispatchUnavailable, .manuallyStopped:
                // These domain refusals occur before recording an attempt. A
                // persistence/unknown-COMMIT error does not enter this branch.
                try await runtime.deferOutbox(claim, retryAfterSeconds: 5)
            default: try await runtime.recordFailure(claim, code: .rejected)
            }
            return
        }
        switch admission {
        case .alreadyAccepted:
            try await runtime.markDelivered(claim)
            return
        case .uncertain:
            try await runtime.recordFailure(claim, code: .unknownOutcome)
            return
        case .granted: break
        }
        do {
            try Task.checkCancellation()
            if command.kind == .stop {
                try await registry.sendStop(machineId: command.machineId, agentId: command.agentId,
                                            connectionEpochId: command.connectionEpochId)
            } else if let prepared {
                // Receipt/admission only. Durable process/turn evidence arrives
                // independently through the inbox and is never fabricated here.
                _ = try await registry.sendAndAwaitAcknowledgement(machineId: command.machineId, command: prepared,
                                                                   timeout: .seconds(10), requiredRuntime: "codex")
            } else { throw ProductionStartupError.agentExecutionNotConnected }
            try await execution.noteDispatched(reference: reference, context: context)
        } catch {
            // A durable attempt already exists. Even an I/O cancellation can
            // race a completed write; only the inbox can settle that uncertainty.
            let result = try await execution.noteAmbiguousDispatch(reference: reference, context: context)
            if result == .alreadyAccepted { try await runtime.markDelivered(claim) }
            else { try await runtime.recordFailure(claim, code: .unknownOutcome) }
            return
        }
        // Failure of this SQL acknowledgement must never trigger another send
        // in this invocation. A later claim reconciles the persisted admission.
        try await runtime.markDelivered(claim)
    }

    private func settleOrReject(_ claim: DurableOutboxClaim, reference: AgentExecutionIntentReference) async throws {
        let command = try execution.command(reference: reference)
        if command?.status == .accepted || command?.kind == .stop && command?.status == .dispatched {
            try await runtime.markDelivered(claim)
        } else {
            // Cancellation, obsolete ownership or recovery HOLD is not delivery.
            // Preserve the bounded terminal history rather than claiming a send.
            try await runtime.recordFailure(claim, code: .rejected)
        }
    }
}
