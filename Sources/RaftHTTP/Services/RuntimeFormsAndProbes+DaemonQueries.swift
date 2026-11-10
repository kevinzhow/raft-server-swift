import Foundation

extension RuntimeFormsAndProbesService {
    /// This route deliberately holds no write UoW while waiting on the daemon.
    /// Recheck caller authority and the epoch before publishing any reply/cache.
    public func queryMachineRuntimeModels(authorization: String?, serverId: String, machineId: String,
                                         runtime: String, persistence: BusinessPersistenceRuntime?) async throws -> MachineRuntimeModelQueryResponse {
        let source = try await queryModelSource(authorization: authorization, serverId: serverId,
            machineId: machineId, runtime: runtime, force: false, purpose: "inspect runtime models", persistence: persistence)
        return .init(source: source.source)
    }

    public func queryRuntimeFormOptionSource(authorization: String?, serverId: String, machineId: String,
        runtimeId: String, sourceId: String, protocolVersion: Int, schemaVersion: String?, language: String?,
        refresh: Bool = false, persistence: BusinessPersistenceRuntime?) async throws -> RuntimeOptionSourceResponse {
        let probes = sourceId == "model" && (protocolVersion == 2 || runtimeId == "kimi-sdk" || runtimeId == "builtin")
            && ["claude", "cursor", "opencode", "codex", "grok", "pi", "kimi-sdk", "builtin"].contains(runtimeId)
            || protocolVersion == 2 && runtimeId == "builtin" && sourceId == "provider"
        try machineQueryRead(persistence: persistence) {
            _ = try authorizedMachine(authorization: authorization, serverId: serverId, machineId: machineId,
                                      purpose: "inspect runtime form option sources")
            _ = try expectedSchema(runtimeId: runtimeId, protocolVersion: protocolVersion, schemaVersion: schemaVersion,
                                   unknown: .runtimeFormOptionSourceNotFound)
        }
        let result: ModelQueryResolution?
        if probes {
            result = try await queryModelSource(authorization: authorization, serverId: serverId, machineId: machineId,
                runtime: runtimeId, force: refresh, purpose: "inspect runtime form option sources", persistence: persistence)
        } else { result = nil }
        return try machineQueryRead(persistence: persistence) {
            try projectRuntimeFormOptionSource(authorization: authorization, serverId: serverId, machineId: machineId,
                runtimeId: runtimeId, sourceId: sourceId, protocolVersion: protocolVersion, schemaVersion: schemaVersion,
                language: language, refresh: refresh, resolvedSource: result?.source, transportFailure: result?.transportFailure)
        }
    }

    private func authorizedQueryMachine(authorization: String?, serverId: String, machineId: String,
                                        purpose: String) throws {
        if purpose != "inspect runtime models" {
            _ = try authorizedMachine(authorization: authorization, serverId: serverId, machineId: machineId, purpose: purpose)
            return
        }
        guard let user = dependencies.sessionUserId(authorization) else { throw RuntimeFormsAndProbesError.unauthorized }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: user) else { throw RuntimeFormsAndProbesError.serverNotFound }
        guard let machine = dependencies.machines.machine(id: machineId, serverId: serverId) else { throw RuntimeFormsAndProbesError.machineNotFound }
        guard role == "owner" || role == "admin" || machine.userId == user else {
            throw RuntimeFormsAndProbesError.editMachinesRequired(purpose: purpose)
        }
    }

    private typealias ModelQueryResolution = (source: MachineRuntimeModelSource, transportFailure: MachineQueryError?)

    private func queryModelSource(authorization: String?, serverId: String, machineId: String, runtime: String,
                                 force: Bool, purpose: String, persistence: BusinessPersistenceRuntime?) async throws -> ModelQueryResolution {
        let binding: (MachineQueryAuthority, (any MachineQuerying)?)?
        do {
            binding = try machineQueryRead(persistence: persistence) {
                try authorizedQueryMachine(authorization: authorization, serverId: serverId, machineId: machineId, purpose: purpose)
                guard dependencies.machines.machineRoutedLocally?(machineId) ?? true else { return nil }
                return (try machineQueryAuthority(agents: dependencies.agents, machineId: machineId, serverId: serverId),
                        dependencies.machines.machineQueries)
            }
        } catch MachineQueryError.offline { return (.init(kind: .error, retryable: true, code: "computer_offline"), .offline) }
        guard let (authority, port) = binding, let port else { return (.init(kind: .error, retryable: true, code: "computer_offline"), .offline) }
        let source: MachineRuntimeModelSource
        let transportFailure: MachineQueryError?
        do {
            source = try await port.runtimeModels(authority: authority, runtime: runtime, force: force)
            transportFailure = nil
        }
        catch is CancellationError { throw CancellationError() }
        catch MachineQueryError.offline { source = .init(kind: .error, retryable: true, code: "computer_offline"); transportFailure = .offline }
        catch MachineQueryError.timedOut { source = .init(kind: .error, retryable: true, code: "detect_timeout"); transportFailure = .timedOut }
        catch { source = .init(kind: .error, retryable: true); transportFailure = nil }
        let finish: @Sendable () throws -> ModelQueryResolution = {
            try self.authorizedQueryMachine(authorization: authorization, serverId: serverId, machineId: machineId, purpose: purpose)
            guard (try? machineQueryAuthority(agents: self.dependencies.agents, machineId: machineId, serverId: serverId)) == authority else {
                // An authority change alone cannot grant a presentation fallback;
                // preserve only a transport failure already observed by this call.
                return (.init(kind: .error, retryable: true, code: "computer_offline"), transportFailure)
            }
            if source.kind == .live, let value = source.value {
                self.dependencies.machines.recordRuntimeModelCatalog(machineId: machineId, runtime: runtime,
                    models: value.models, observedAt: self.dependencies.now())
            }
            return (source, transportFailure)
        }
        if let persistence { return try await persistence.execute { try finish() } }
        return try finish()
    }

    private func projectedBuiltinSource(_ source: MachineRuntimeModelSource, protocolVersion: Int,
                                        expected: String) throws -> RuntimeOptionSourceResponse {
        let bundled = protocolVersion == 2 ? RuntimeFormCatalog.builtinV2ModelGroups : BuiltinModelSourceBody.bundledGroups()
        if source.kind == .live {
            guard let value = source.value, let catalog = value.catalog,
                  catalog.protocolVersion == 1, catalog.runtime == "builtin", !catalog.runtimeVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RuntimeFormsAndProbesError.builtinCatalogCapabilityRequired
            }
            let ids = Set(value.models.map(\.id))
            let groups = bundled.compactMap { group -> BuiltinModelSourceBody.Group? in
                let models = group.models.filter { ids.contains($0.value) }
                return models.isEmpty ? nil : .init(provider: group.provider, models: models)
            }
            return .builtinModel(.init(schemaVersion: expected, groups: groups, status: protocolVersion == 2 ? "live" : nil, includeGatewayOptions: protocolVersion == 2))
        }
        if protocolVersion == 1 { throw RuntimeFormsAndProbesError.builtinCatalogUnavailable }
        let reason: String
        switch source.kind {
        case .missing_config: reason = "missing_config"
        case .no_models: reason = "no_models"
        case .unsupported: reason = "unsupported"
        case .error: reason = source.code == "computer_offline" ? "machine_offline"
            : source.code == "detect_timeout" ? "probe_timeout" : "probe_failed"
        case .live: reason = "probe_failed"
        }
        return .builtinModel(.init(schemaVersion: expected, groups: [], status: "unavailable",
                                  reason: reason, retryable: Self.runtimeReasonRetryable(reason), metadataGroups: bundled, includeGatewayOptions: true))
    }
    // MARK: - Runtime form option sources

    /// `GET .../runtime-form-definitions/:runtimeId/option-sources/:sourceId`
    /// (v1) and `GET .../runtime-forms/v2/:runtimeId/option-sources/:sourceId`
    /// (v2). Static sources never probe the Computer; the model sources of
    /// probed runtimes do.
    public func runtimeFormOptionSource(authorization: String?, serverId: String, machineId: String,
        runtimeId: String, sourceId: String, protocolVersion: Int, schemaVersion: String?, language: String?,
        refresh: Bool = false) throws -> RuntimeOptionSourceResponse {
        try projectRuntimeFormOptionSource(authorization: authorization, serverId: serverId, machineId: machineId,
            runtimeId: runtimeId, sourceId: sourceId, protocolVersion: protocolVersion, schemaVersion: schemaVersion,
            language: language, refresh: refresh, resolvedSource: nil)
    }

    private func projectRuntimeFormOptionSource(
        authorization: String?,
        serverId: String,
        machineId: String,
        runtimeId: String,
        sourceId: String,
        protocolVersion: Int,
        schemaVersion: String?,
        language: String?,
        refresh: Bool = false,
        resolvedSource: MachineRuntimeModelSource? = nil, transportFailure: MachineQueryError? = nil
    ) throws -> RuntimeOptionSourceResponse {
        _ = try authorizedMachine(
            authorization: authorization,
            serverId: serverId,
            machineId: machineId,
            purpose: "inspect runtime form option sources"
        )
        let expected = try expectedSchema(
            runtimeId: runtimeId,
            protocolVersion: protocolVersion,
            schemaVersion: schemaVersion,
            unknown: .runtimeFormOptionSourceNotFound
        )
        // Only a server transport failure offers the declared Built-in bundle.
        // A daemon-returned error with the same code is still a non-live reply.
        if runtimeId == "builtin", let transportFailure, sourceId == "model" || protocolVersion == 2 && sourceId == "provider" {
            let reason: String
            switch transportFailure {
            case .offline: reason = "machine_offline"
            case .timedOut: reason = "probe_timeout"
            case .invalidReply: throw RuntimeFormsAndProbesError.builtinCatalogUnavailable
            }
            if sourceId == "provider" { return .builtinProviderV2(schemaVersion: expected, supportedModelIDs: nil) }
            let bundled = protocolVersion == 2 ? RuntimeFormCatalog.builtinV2ModelGroups : BuiltinModelSourceBody.bundledGroups()
            return .builtinModel(.init(schemaVersion: expected, groups: bundled,
                status: protocolVersion == 2 ? "fallback" : nil, reason: protocolVersion == 2 ? reason : nil,
                retryable: protocolVersion == 2 ? true : nil, includeGatewayOptions: protocolVersion == 2))
        }
        let chinese = Self.prefersChinese(language)

        if protocolVersion == 2 {
            if let source = try v2OptionSource(
                machineId: machineId,
                runtimeId: runtimeId,
                sourceId: sourceId,
                expected: expected,
                refresh: refresh, resolvedSource: resolvedSource
            ) {
                return source
            }
        }

        if sourceId == "model", runtimeId == "kimi-sdk" {
            return try kimiSDKSource(
                resolution: probeResolution(machineId: machineId, runtimeId: runtimeId, refresh: refresh, source: resolvedSource),
                protocolVersion: 1,
                expected: expected
            )
        }
        if sourceId == "model", runtimeId == "builtin" {
            return try builtinModelSource(protocolVersion: 1, expected: expected, source: resolvedSource)
        }
        switch sourceId {
        case "provider" where runtimeId == "builtin":
            return .builtinProvider(schemaVersion: expected, chinese: chinese)
        case "model":
            let cached = dependencies.machines.runtimeModels(machineId: machineId, runtime: runtimeId)
            return .cachedModels(
                schemaVersion: expected,
                models: cached.map { RuntimeModelChoice(value: $0.id, label: $0.label) }
            )
        default:
            throw RuntimeFormsAndProbesError.unknownOptionSource
        }
    }

    /// The v2 sources that answer without falling through to the shared
    /// legacy tail; `nil` leaves the request to that tail.
    private func v2OptionSource(
        machineId: String,
        runtimeId: String,
        sourceId: String,
        expected: String,
        refresh: Bool, resolvedSource: MachineRuntimeModelSource?
    ) throws -> RuntimeOptionSourceResponse? {
        if runtimeId == "antigravity" {
            throw RuntimeFormsAndProbesError.unknownOptionSource
        }
        if sourceId == "provider", runtimeId == "builtin" {
            guard let source = resolvedSource else { return .builtinProviderV2(schemaVersion: expected, supportedModelIDs: nil) }
            guard source.kind == .live else { throw RuntimeFormsAndProbesError.builtinCatalogUnavailable }
            guard let value = source.value, let catalog = value.catalog,
                  catalog.protocolVersion == 1, catalog.runtime == "builtin", !catalog.runtimeVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RuntimeFormsAndProbesError.builtinCatalogCapabilityRequired
            }
            return .builtinProviderV2(schemaVersion: expected, supportedModelIDs: Set(value.models.map(\.id)))
        }
        if sourceId == "provider", runtimeId == "pi" {
            return .catalog(RuntimeFormCatalog.optionSources["pi/provider"] ?? "")
        }
        if sourceId == "providerModel", runtimeId == "pi" {
            return .catalog(RuntimeFormCatalog.optionSources["pi/providerModel"] ?? "")
        }
        if sourceId == "model", runtimeId == "kimi" || runtimeId == "gemini" {
            return .catalog(RuntimeFormCatalog.optionSources["\(runtimeId)/model"] ?? "")
        }
        if sourceId == "model", runtimeId == "kimi-sdk" {
            return try kimiSDKSource(
                resolution: probeResolution(machineId: machineId, runtimeId: runtimeId, refresh: refresh, source: resolvedSource),
                protocolVersion: 2,
                expected: expected
            )
        }
        if sourceId == "model", runtimeId == "builtin" {
            return try builtinModelSource(protocolVersion: 2, expected: expected, source: resolvedSource)
        }
        if sourceId == "provider", runtimeId == "claude" {
            return .catalog(RuntimeFormCatalog.optionSources["claude/provider"] ?? "")
        }
        if sourceId == "model", runtimeId == "claude" || runtimeId == "cursor" {
            switch probeResolution(machineId: machineId, runtimeId: runtimeId, refresh: refresh, source: resolvedSource) {
            case .live(let models, let defaultModel):
                return .model(RuntimeModelSourceBody(
                    runtimeId: runtimeId,
                    schemaVersion: expected,
                    options: models.map { RuntimeProbeOption($0, reasoning: runtimeId == "claude") },
                    defaultValue: defaultModel ?? models.first?.id ?? "",
                    customValueAllowed: true,
                    status: "live"
                ))
            case .notLive(let reason):
                return .catalog(Self.catalogWithReason(
                    RuntimeFormCatalog.optionSources["\(runtimeId)/model"] ?? "",
                    reason: reason
                ))
            }
        }
        if sourceId == "model", ["opencode", "codex", "grok", "pi"].contains(runtimeId) {
            switch probeResolution(machineId: machineId, runtimeId: runtimeId, refresh: refresh, source: resolvedSource) {
            case .live(let models, let defaultModel):
                let reasoning = runtimeId == "codex" || runtimeId == "grok" || runtimeId == "pi"
                return .model(RuntimeModelSourceBody(
                    runtimeId: runtimeId,
                    schemaVersion: expected,
                    options: models.map { RuntimeProbeOption($0, reasoning: reasoning) },
                    defaultValue: defaultModel ?? models.first?.id ?? "",
                    customValueAllowed: runtimeId == "codex" || runtimeId == "pi" ? true : nil,
                    status: runtimeId == "opencode" ? nil : "live"
                ))
            case .notLive(let reason):
                switch runtimeId {
                case "opencode":
                    return .catalog(RuntimeFormCatalog.optionSources["opencode/model"] ?? "")
                case "grok":
                    return .model(RuntimeModelSourceBody(
                        runtimeId: "grok",
                        schemaVersion: expected,
                        options: Self.grokBundledModels.map { RuntimeProbeOption($0, reasoning: true) },
                        defaultValue: "grok-4.5",
                        status: "fallback",
                        reason: reason,
                        retryable: Self.runtimeReasonRetryable(reason)
                    ))
                default:
                    let raw = RuntimeFormCatalog.optionSources["\(runtimeId)/model"] ?? ""
                    if reason == "missing_config" { return .catalog(raw) }
                    return .catalog(Self.catalogWithReason(raw, reason: reason))
                }
            }
        }
        return nil
    }

    /// The shipped `missing_config` source with the probe's reason and
    /// retryability substituted into the rendered catalog text.
    private static func catalogWithReason(_ raw: String, reason: String) -> String {
        raw
            .replacingOccurrences(of: "\"reason\": \"missing_config\"", with: "\"reason\": \"\(reason)\"")
            .replacingOccurrences(of: "\"retryable\": false", with: "\"retryable\": \(runtimeReasonRetryable(reason))")
    }

    // MARK: - Probe resolution

    /// How a machine's model probe resolved for one runtime.
    enum ProbeResolution {
        case live(models: [RuntimeModelProbeModel], default: String?)
        case notLive(reason: String)
    }

    private func probeResolution(machineId: String, runtimeId: String, refresh: Bool, source: MachineRuntimeModelSource?) -> ProbeResolution {
        guard dependencies.machines.machineRoutedLocally?(machineId) ?? true else {
            return .notLive(reason: "machine_offline")
        }
        let outcome: RuntimeModelProbeOutcome
        if let source {
            outcome = source.probeOutcome
        } else if let probe = dependencies.machines.machineRuntimeModelProbe {
            outcome = probe(machineId, runtimeId, refresh)
        } else {
            let models = dependencies.machines.runtimeModels(machineId: machineId, runtime: runtimeId)
            outcome = models.isEmpty
                ? .missingConfig
                : .live(
                    models: models.map { RuntimeModelProbeModel(id: $0.id, label: $0.label) },
                    default: models.first?.id
                )
        }
        switch outcome {
        case .live(let models, let defaultModel), .models(let models, let defaultModel):
            return models.isEmpty ? .notLive(reason: "no_models") : .live(models: models, default: defaultModel)
        case .missingConfig:
            return .notLive(reason: "missing_config")
        case .noModels:
            return .notLive(reason: "no_models")
        case .unsupported:
            return .notLive(reason: "unsupported")
        case .error(let code, _):
            if code == "detect_timeout" { return .notLive(reason: "probe_timeout") }
            if code == "computer_offline" { return .notLive(reason: "machine_offline") }
            return .notLive(reason: "probe_failed")
        case .failed:
            return .notLive(reason: "probe_failed")
        }
    }

    static func runtimeReasonRetryable(_ reason: String) -> Bool {
        ["probe_timeout", "probe_failed", "machine_offline", "no_models"].contains(reason)
    }

    private func kimiSDKSource(
        resolution: ProbeResolution,
        protocolVersion: Int,
        expected: String
    ) throws -> RuntimeOptionSourceResponse {
        let managed = RuntimeModelProbeModel(id: "kimi-code/kimi-for-coding", label: "Kimi for Coding (default)")
        func body(
            options: [RuntimeProbeOption],
            defaultValue: String,
            status: String? = nil,
            reason: String? = nil,
            retryable: Bool? = nil
        ) -> RuntimeOptionSourceResponse {
            .model(RuntimeModelSourceBody(
                runtimeId: "kimi-sdk",
                schemaVersion: expected,
                options: options,
                defaultValue: defaultValue,
                status: status,
                reason: reason,
                retryable: retryable
            ))
        }
        switch resolution {
        case .live(let models, let defaultModel):
            return body(
                options: models.map { RuntimeProbeOption($0, reasoning: true) },
                defaultValue: defaultModel ?? models.first?.id ?? "",
                status: protocolVersion == 2 ? "live" : nil
            )
        case .notLive(let reason):
            let retryable = Self.runtimeReasonRetryable(reason)
            let fallbackReason = reason == "missing_config" || reason == "machine_offline"
            if protocolVersion == 2 {
                if fallbackReason {
                    return body(
                        options: [RuntimeProbeOption(managed, reasoning: true)],
                        defaultValue: "kimi-code/kimi-for-coding",
                        status: "fallback",
                        reason: reason,
                        retryable: retryable
                    )
                }
                return body(
                    options: [],
                    defaultValue: "",
                    status: "unavailable",
                    reason: reason,
                    retryable: retryable
                )
            }
            if fallbackReason {
                return body(
                    options: [RuntimeProbeOption(managed, reasoning: true)],
                    defaultValue: "kimi-code/kimi-for-coding"
                )
            }
            switch reason {
            case "no_models":
                throw RuntimeFormsAndProbesError.kimiSDKSource(code: "runtime_model_source_no_models")
            case "unsupported":
                throw RuntimeFormsAndProbesError.kimiSDKSource(code: "runtime_model_source_unsupported")
            default:
                throw RuntimeFormsAndProbesError.kimiSDKSource(code: "runtime_model_source_error")
            }
        }
    }

    private func builtinModelSource(
        protocolVersion: Int,
        expected: String, source: MachineRuntimeModelSource?
    ) throws -> RuntimeOptionSourceResponse {
        if let source { return try projectedBuiltinSource(source, protocolVersion: protocolVersion, expected: expected) }
        if protocolVersion == 2 {
            // No actual query result cannot establish a live catalog.
            return .builtinModel(.init(schemaVersion: expected, groups: RuntimeFormCatalog.builtinV2ModelGroups,
                status: "fallback", reason: "machine_offline", retryable: true, includeGatewayOptions: true))
        }
        let mode = dependencies.machines.builtinCatalogMode
        if mode == "legacy" { throw RuntimeFormsAndProbesError.builtinCatalogCapabilityRequired }
        if mode == "timeout" { throw RuntimeFormsAndProbesError.builtinCatalogUnavailable }
        let bundled = BuiltinModelSourceBody.bundledGroups()
        let groups = mode == "offline" ? bundled : liveBuiltinGroups(bundled: bundled)
        return .builtinModel(BuiltinModelSourceBody(schemaVersion: expected, groups: groups))
    }

    private func liveBuiltinGroups(
        bundled: [BuiltinModelSourceBody.Group]
    ) -> [BuiltinModelSourceBody.Group] {
        let models = dependencies.machines.builtinRuntimeModels()
        guard !models.isEmpty else { return bundled }
        return [BuiltinModelSourceBody.Group(
            provider: "deepseek",
            models: models.map { RuntimeModelChoice(value: $0.id, label: $0.label) }
        )]
    }

}
