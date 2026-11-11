import Foundation
import RaftShared

extension AgentsRuntimeStore {
    /// The secret remains in the existing private credential ledger. Only its id
    /// is bound to the launch. A retry never rotates a live or missing binding.
    func materializationCredential(command: AgentExecutionCommand) throws -> (key: String, id: String) {
        do { try DeferredEffects.requireDurableTransaction(in: .shared) }
        catch { throw AgentExecutionError.durableTransactionRequired }
        return try withState { state -> Result<(key: String, id: String), any Error> in
            do {
                try Self.validateMaterialization(command: command, state: state)
                guard command.kind == .start,
                      let launch = state.execution.agents[command.agentId]?.launches[command.launchId] else {
                    throw AgentExecutionMaterializationError.commandUnavailable
                }
                if let id = launch.runnerCredentialId {
                    guard let entry = state.agentCredentials.first(where: { $0.value.id == id }),
                          entry.value.agentId == command.agentId, entry.value.revokedAt == nil,
                          entry.value.scopes == Self.materializationRunnerScopes else {
                        throw AgentExecutionMaterializationError.credentialUnavailable
                    }
                    return .success((entry.key, id))
                }
                // Same mint primitive and private row as the Computer runner API.
                let key = "sk_agent_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
                let credential = AgentCredential(agentId: command.agentId, scopes: Self.materializationRunnerScopes, name: "computer-runner")
                state.agentCredentials[key] = credential
                state.execution.agents[command.agentId]?.launches[command.launchId]?.runnerCredentialId = credential.id
                return .success((key, credential.id))
            } catch { return .failure(error) }
        }.get()
    }

    /// Reads only; the caller also checks current OAuth, machine and local
    /// message authority using the same ambient business transaction.
    func validateMaterialization(command: AgentExecutionCommand) throws {
        do { try DeferredEffects.requireDurableTransaction(in: .shared) }
        catch { throw AgentExecutionError.durableTransactionRequired }
        try withState { state -> Result<Void, any Error> in
            do { try Self.validateMaterialization(command: command, state: state); return .success(()) }
            catch { return .failure(error) }
        }.get()
    }

    private static func validateMaterialization(command: AgentExecutionCommand, state: State) throws {
        guard command.kind != .stop, command.status == .pending || command.status == .dispatched,
              state.execution.commands[command.commandId.uuidString] == command,
              state.agentMachineIds[command.agentId] == command.machineId,
              let agent = state.execution.agents[command.agentId], agent.serverId == command.serverId,
              agent.machineId == command.machineId, agent.currentLaunchId == command.launchId,
              agent.needsManual == nil, agent.takeoverEpoch == command.takeoverEpoch,
              agent.generation == command.breakerGeneration,
              let launch = agent.launches[command.launchId], !launch.stopRequested, !launch.notSpawned,
              // A runtime configuration lift raises the agent's generation and
              // clears the current launch without asserting process exit. A live
              // resident process still carries the launch it was bound to, so a
              // delivery/notice staged after the lift may name that older launch.
              // A start never may: it must be minted under the current generation.
              (launch.generation == command.breakerGeneration
                || (command.kind == .delivery || command.kind == .notice) && launch.generation < command.breakerGeneration),
              launch.takeoverEpoch == command.takeoverEpoch,
              let connection = state.execution.connections[command.machineId], connection.serverId == command.serverId,
              connection.online, connection.ready, connection.runtimes.contains("codex"),
              connection.daemonInstanceId == launch.daemonInstanceId,
              connection.connectionEpochId == command.connectionEpochId else {
            throw AgentExecutionMaterializationError.commandUnavailable
        }
        if command.kind == .start {
            guard !launch.completed, !launch.terminalFailure, !launch.startAccepted, launch.processInstanceId == nil,
                  launch.startDispatchId == command.startDispatchId, launch.connectionEpochId == command.connectionEpochId else {
                throw AgentExecutionMaterializationError.commandUnavailable
            }
        }
    }

    /// Called after releasing an execution-state borrow, within the ingress
    /// transaction. A completed turn can leave its process alive and retains its
    /// credential. Unknown launches or processes never authorize revocation.
    @discardableResult
    func revokeRetiredMaterializationCredential(agentId: String, launchId: String, at: Date) throws -> Bool {
        do { try DeferredEffects.requireDurableTransaction(in: .shared) }
        catch { throw AgentExecutionError.durableTransactionRequired }
        return withState { state in
            guard let agent = state.execution.agents[agentId], let launch = agent.launches[launchId],
                  let credentialId = launch.runnerCredentialId else { return false }
            let processes = agent.processes.values.filter {
                $0.spawnLaunchId == launchId || $0.launchIds.contains(launchId) || $0.processInstanceId == launch.processInstanceId
            }
            if let processId = launch.processInstanceId, agent.processes[processId] == nil { return false }
            let starts = state.execution.commands.values.filter { $0.agentId == agentId && $0.launchId == launchId && $0.kind == .start }
            let cancelledBeforeAttempt = launch.processInstanceId == nil && !launch.startAccepted && processes.isEmpty
                && !starts.isEmpty && starts.allSatisfy {
                    $0.status == .superseded && state.execution.dispatches?[$0.commandId.uuidString] == nil
                }
            let terminal = processes.isEmpty ? launch.notSpawned && launch.processInstanceId == nil : processes.allSatisfy(\.exited)
            guard terminal || cancelledBeforeAttempt, let entry = state.agentCredentials.first(where: { $0.value.id == credentialId }),
                  entry.value.agentId == agentId else { return false }
            state.agentCredentials[entry.key]?.revokedAt = entry.value.revokedAt ?? at
            return true
        }
    }

    private static var materializationRunnerScopes: Set<String> {
        ["send", "read", "mentions", "tasks", "reactions", "server", "channels", "knowledge", "mcp", "raftbench"]
    }
}
