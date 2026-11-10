import Foundation

/// Projection only. Production's outer BusinessPersistenceMiddleware owns the
/// committed Store read scope for these routes; this service does not await RPCs,
/// write setup phases, grant execution authority, or inspect credential fields.
struct ServerSetupProjectionService {
    let store: ServersAndChannelsStore
    let agents: AgentsRuntimeStore
    let computers: MachinesAndComputersStore
    let oauth: OAuthLedger
    let accountFacts: any SetupAccountFacts

    func project(serverId: String, userId: String, role: String,
                 revokedComputers: Int? = nil) -> SetupProjectionResponseDTO {
        var result = SetupProjectionResponseDTO()
        result.revokedComputers = revokedComputers
        // Pinned Node resolveServerSetup is owner-only, including terminal reads.
        guard role == "owner" else { return result }
        let sidebar = store.state
        let phase = sidebar.setupPhases["\(serverId)\n\(userId)"] ?? "not_started"
        let serverCompleted = sidebar.setupPhases.contains { key, phase in
            guard phase == "complete", key.hasPrefix(serverId + "\n") else { return false }
            return oauth.memberRole(serverId: serverId, userId: String(key.dropFirst(serverId.count + 1))) == "owner"
        }
        if phase == "complete" || serverCompleted {
            result.surface = "complete"
            result.phase = "complete"
            result.gateReason = "setup_complete"
            applyPostSetup(serverId: serverId, userId: userId, phase: phase,
                           sidebar: sidebar, to: &result)
            return result
        }
        result.phase = phase
        result.blocksChat = phase != "deferred"
        result.surface = "computer_runtime"
        result.currentStep = "computer_runtime"
        result.transitionsEnabled = true
        let onboardingId = sidebar.serverOnboardingSettings[serverId]?.agentId
        result.allowedExits = onboardingId == nil ? ["reset", "return_to_server"] : ["return_to_server"]
        let machineFacts = computers.state
        let agentFacts = agents.state
        let connected = machineFacts.computers.filter { $0.serverId == serverId && $0.revokedAt == nil }
        let rows = machineFacts.machines.filter { $0.serverId == serverId }
        let online = rows.filter { machine in
            connected.contains { $0.machineId == machine.id } &&
                agentFacts.execution.connections[machine.id].map { $0.serverId == serverId && $0.online } == true
        }
        result.hasConnectedComputer = !connected.isEmpty
        let onlineIds = Set(online.map(\.id))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        result.offlineComputers = connected.filter { computer in
            computer.machineId.map { !onlineIds.contains($0) } ?? true
        }.map { computer in
            let machine = rows.first { $0.id == computer.machineId }
            return .init(id: computer.id, name: computer.name,
                lastHeartbeat: machine?.lastSeenAt.map { formatter.string(from: $0) })
        }
        result.computerStatus = online.isEmpty ? "offline" : "online"
        result.gateReason = "computer_offline"
        guard !online.isEmpty else { return result }
        // A retained real connection with a current ready report is required;
        // machineOnline fixture Bools and stale process-local callbacks are ignored.
        // Installed inventory remains the persisted MachineRecord facts used by
        // fleet/runtime-options, including partial-inventory retention semantics.
        let reported = online.filter { agentFacts.execution.connections[$0.id]?.daemonInstanceId != nil }
        let installed = Set(reported.flatMap(\.runtimes))
        let catalog: [(id: String, binary: String)] = [
            ("claude", "claude"), ("codex", "codex"), ("grok", "grok"),
            ("kimi-sdk", ""), ("cursor", "cursor-agent"), ("opencode", "opencode"), ("pi", "pi"),
        ]
        result.runtimeOptions = catalog.filter { $0.id != "grok" || agentFacts.grokRuntimeServers.contains(serverId) }.map { runtime in
            .init(runtimeId: runtime.id,
                capabilityStatus: installed.contains(runtime.id) ? "available" : (runtime.binary.isEmpty ? "update_required" : "not_installed"),
                formDefinitionSchemaVersion: RuntimeFormsAndProbesService.runtimeFormV1Runtimes.contains(runtime.id)
                    ? RuntimeFormsAndProbesService.runtimeFormSchemas[runtime.id] : nil)
        }
        let available = result.runtimeOptions.filter { $0.capabilityStatus == "available" }.map(\.runtimeId)
        if available.contains("claude") || available.contains("codex") {
            result.runtimeStatus = "ready_recommended"
        } else if !available.isEmpty {
            result.runtimeStatus = "ready_other"
        } else {
            // [] without any report is unknown, not a proven empty inventory.
            let knownEmpty = reported.count == online.count && reported.allSatisfy {
                $0.runtimeDetection?.status != .pending && $0.runtimeDetection?.status != .incomplete
            }
            result.runtimeStatus = knownEmpty ? "not_ready" : "unknown"
        }
        guard result.runtimeStatus == "ready_recommended" || result.runtimeStatus == "ready_other" else {
            result.gateReason = result.runtimeStatus == "not_ready" ? "runtime_not_ready" : "runtime_status_unknown"
            return result
        }
        result.surface = "create_agent"
        result.currentStep = "create_agent"
        guard let onboardingId else {
            result.gateReason = "official_onboarding_agent_missing"
            return result
        }
        let usable = officialAgentUsable(id: onboardingId, serverId: serverId,
            agentFacts: agentFacts, machineFacts: machineFacts)
        result.completionEnabled = usable
        result.gateReason = usable ? "completion_pending" : "official_onboarding_agent_unusable"
        return result
    }

    /// The two post-setup facts, read from retained state exactly like upstream
    /// `projectServerSetup` (services/serverSetupStateService.ts:355-374):
    ///
    /// * the actor's OWN row must be `complete` with a retained `normal` or
    ///   compatible `complete_after_defer` reason, and
    /// * the actor must be the server's `ownerId` (a co-owner/admin who can help
    ///   set the server up cannot answer the owner's personal survey or accept
    ///   the owner's handoff).
    ///
    /// An inherited completion (the actor's row is not the completed one), an
    /// unknown legacy reason, `grandfathered`/`admin_override`, and any unknown
    /// actor owe nothing. Neither comparison uses a build/registration time.
    private func applyPostSetup(serverId: String, userId: String, phase: String,
                                sidebar: ServersAndChannelsStore.State,
                                to result: inout SetupProjectionResponseDTO) {
        let key = "\(serverId)\n\(userId)"
        let reason = sidebar.setupCompletionReasons[key]
            .flatMap(ServerSetupCompletionReason.init(rawValue:))
        let flowCompleted = phase == "complete" && reason?.isFreshFlowCompletion == true
        let actorIsOwner = oauth.serverProfile(id: serverId)?.ownerId == userId
        guard flowCompleted, actorIsOwner else { return }
        result.postSetupSurveyPending = !accountFacts.surveyCompleted(userId: userId)
        // The handoff is owed until the real owner receipt exists. The legacy
        // subjectless marker and any briefing/delivery timestamp are not it.
        result.postSetupHandoffPending = sidebar.setupHandoffReceipts[key] == nil
    }

    /// Shared by the read projection and the complete write admission. Production
    /// calls both inside the same outer BPR scope, with no await between facts/write.
    func canComplete(serverId: String) -> Bool {
        guard let id = store.state.serverOnboardingSettings[serverId]?.agentId else { return false }
        return officialAgentUsable(id: id, serverId: serverId,
            agentFacts: agents.state, machineFacts: computers.state)
    }

    private func officialAgentUsable(id: String, serverId: String,
                                    agentFacts: AgentsRuntimeStore.State,
                                    machineFacts: MachinesAndComputersStore.State) -> Bool {
        guard let agent = oauth.agentRuntimeInfo(id: id), agent.serverId == serverId, !agent.deleted,
              agent.name == "Cindy", agent.displayName == "Cindy",
              agent.description == "Onboarding Assistant", agent.avatarUrl == "pixel:mug",
              oauth.agentRole(serverId: serverId, agentId: id) == "admin",
              let machineId = agentFacts.agentMachineIds[id],
              let machine = machineFacts.machines.first(where: { $0.id == machineId && $0.serverId == serverId }),
              machineFacts.computers.contains(where: {
                  $0.serverId == serverId && $0.machineId == machineId && $0.revokedAt == nil
              }),
              let connection = agentFacts.execution.connections[machineId],
              connection.serverId == serverId, connection.online,
              connection.daemonInstanceId?.isEmpty == false,
              !agent.runtime.isEmpty, machine.runtimes.contains(agent.runtime),
              connection.runtimes.contains(agent.runtime) else { return false }
        if let execution = agentFacts.execution.agents[id],
           execution.serverId != serverId || execution.machineId != machineId { return false }
        // A hosted runtime has no such local inventory/assignment proof. Never
        // upgrade it from an arbitrary online Computer or unrelated agent.
        return true
    }
}
