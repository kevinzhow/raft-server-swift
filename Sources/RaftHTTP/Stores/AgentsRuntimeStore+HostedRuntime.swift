import Foundation

/// One hosted-runtime provision row, as the status and retry replies publish it.
struct HostedRuntimeRow: Sendable, Equatable {
    var provider: String
    var model: String?
    var state: String
    var retryNeedsModel: Bool
    var createdAt: Date
}

/// What one provisioning retry decided. The refusals keep the legacy order:
/// the model checks run before the state check.
enum HostedRetryOutcome: Sendable {
    case missing
    case pickerDisabled
    case modelLocked
    case modelNotOffered
    case modelRequired
    case nothingToRetry
    case retried(HostedRuntimeRow)
}

/// What one hosted model change decided.
enum HostedModelChangeOutcome: Sendable {
    case notReady
    case pickerDisabled
    case modelLocked
    case modelNotOffered
    case changed(HostedModelState, picker: Bool)
}

extension AgentsRuntimeStore {
    /// The hosted provision and model rows of one agent as one snapshot.
    func hostedSnapshot(agentId: String) -> (runtime: HostedRuntimeRow?, models: HostedModelState?, usage: String?) {
        withState { state in
            let runtime = state.hostedRuntimes[agentId].map {
                HostedRuntimeRow(
                    provider: $0.provider,
                    model: $0.model,
                    state: $0.state,
                    retryNeedsModel: $0.retryNeedsModel,
                    createdAt: $0.createdAt
                )
            }
            return (runtime, state.hostedModels[agentId], state.hostedUsage[agentId])
        }
    }

    func hostedRuntimeRow(agentId: String) -> HostedRuntimeRow? {
        hostedSnapshot(agentId: agentId).runtime
    }

    func hostedModelPickerEnabled(serverId: String) -> Bool {
        withState { $0.hostedModelPickerServers.contains(serverId) }
    }

    func enableHostedModelPicker(serverId: String) {
        withState { _ = $0.hostedModelPickerServers.insert(serverId) }
    }

    /// The provisioning retry: every model check, the state check and both
    /// writes are one critical section, so two concurrent retries cannot both
    /// pass the check against the same row.
    func retryHostedProvisioning(
        agentId: String,
        serverId: String,
        modelProvided: Bool,
        providedModel: String?,
        defaultModel: String
    ) -> HostedRetryOutcome {
        withState { state in
            guard let hosted = state.hostedRuntimes[agentId] else { return .missing }
            let picker = state.hostedModelPickerServers.contains(serverId)
            if modelProvided, hosted.retryNeedsModel {
                let current = state.hostedModels[agentId]
                if let providedModel, providedModel != defaultModel, !picker {
                    return .pickerDisabled
                }
                let picked = providedModel == defaultModel && !picker ? nil : providedModel
                if let picked {
                    if current?.locked == true { return .modelLocked }
                    guard current?.models.contains(where: { $0.id == picked }) == true else {
                        return .modelNotOffered
                    }
                }
            }
            switch hosted.state {
            case "failed":
                if hosted.retryNeedsModel, !modelProvided { return .modelRequired }
            case "provisioning", "deleting":
                break
            default:
                return .nothingToRetry
            }
            state.hostedRuntimes[agentId] = (hosted.provider, hosted.model, "provisioning", false, hosted.createdAt)
            if modelProvided, var models = state.hostedModels[agentId] {
                let picked = providedModel == defaultModel && !picker ? nil : providedModel
                if let picked, let option = models.models.first(where: { $0.id == picked }) {
                    models.model = option.id
                    models.label = option.label
                    models.source = "chosen"
                } else if picked == nil {
                    models.model = models.defaultModel
                    models.label = models.defaultLabel
                    models.source = "default"
                }
                state.hostedModels[agentId] = models
            }
            let updated = state.hostedRuntimes[agentId]!
            return .retried(HostedRuntimeRow(
                provider: updated.provider,
                model: updated.model,
                state: updated.state,
                retryNeedsModel: updated.retryNeedsModel,
                createdAt: updated.createdAt
            ))
        }
    }

    /// The hosted model change: picker, lock, offer check and write in one
    /// critical section.
    func changeHostedModel(
        agentId: String,
        serverId: String,
        requested: String?,
        defaultModel: String
    ) -> HostedModelChangeOutcome {
        withState { state in
            let picker = state.hostedModelPickerServers.contains(serverId)
            if let requested, requested != defaultModel, !picker { return .pickerDisabled }
            let picked: String? = (requested != nil && requested == defaultModel && !picker) ? nil : requested
            guard var models = state.hostedModels[agentId] else { return .notReady }
            if let picked {
                if models.locked { return .modelLocked }
                guard let option = models.models.first(where: { $0.id == picked }) else {
                    return .modelNotOffered
                }
                models.model = option.id
                models.label = option.label
                models.source = "chosen"
            } else {
                models.model = models.defaultModel
                models.label = models.defaultLabel
                models.source = "default"
            }
            state.hostedModels[agentId] = models
            return .changed(models, picker: picker)
        }
    }
}
