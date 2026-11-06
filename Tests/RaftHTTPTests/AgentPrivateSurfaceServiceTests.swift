import Foundation
import RaftShared
import Testing
import TestSupport
@testable import RaftHTTP

/// The agent private surface keeps three decisions in single store critical
/// sections (credential use, the assistant link, the machine status counter, the
/// hosted retry and model change) and answers byte-exact ordered bodies. These
/// tests lock both.

// MARK: - Runtime config bytes

@Test func runtimeConfigDocumentMatchesJSONSerializationBytes() throws {
    let corpus = [
        #"{"runtime":"claude","model":{"kind":"preset","id":"opus"}}"#,
        #"{"runtime":"codex","version":2,"extra":[1,2.5,true,null,"a/b"],"envVars":{"B":"1","a":"2","A_1":"3"}}"#,
        #"{"runtime":"claude","provider":{"kind":"custom","apiUrl":"https://x.example/v1","apiKey":"k"},"model":{"kind":"custom","name":"m/é\n\"q\""}}"#,
        #"{"reasoningEffort":"high","mode":{"kind":"plan"},"nested":{"Z":1,"z":2,"10":3,"9":4,"_":5}}"#,
        #"{"big":9007199254740993,"neg":-3,"float":0.1,"exp":1e3}"#,
    ]
    for text in corpus {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let document = try #require(AgentRuntimeConfigDocument(request: value))
        let legacy = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        #expect(document.serialized() == EmailLoginDirectory.serializeJSON(legacy), "\(text)")
    }
}

@Test func runtimeConfigDocumentKeepsLegacyNormalizationAndRedaction() throws {
    let text = #"{"runtime":"claude","provider":{"kind":"custom","apiUrl":"https://x","apiKey":"secret"},"envVars":{"ANTHROPIC_X":"drop","KEEP":"1"}}"#
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    var document = try #require(AgentRuntimeConfigDocument(request: value)).normalized()
    #expect(document.userEnv == ["KEEP": "1"])
    #expect(document.derivedEnvVars(userEnv: document.userEnv) == [
        "KEEP": "1", "ANTHROPIC_BASE_URL": "https://x", "ANTHROPIC_API_KEY": "secret",
    ])
    let redacted = try #require(AgentRuntimeConfigDocument.redactedConfigJSON(document.serialized()))
    #expect(redacted.contains("\"apiKey\":\"\""))
    document.setEnv([:])
    #expect(AgentRuntimeConfigDocument.agentModel(from: document.serialized(), external: false) == "")
    #expect(AgentRuntimeConfigDocument.agentModel(from: nil, external: true) == "external")
    let invalid = AgentRuntimeConfigDocument.validatedEnvVars(.object(["1bad": .string("x")]))
    #expect(invalid.error == "Invalid env var key \"1bad\": must match [A-Za-z_][A-Za-z0-9_]*")
    #expect(AgentRuntimeConfigDocument.validatedEnvVars(.null).error == nil)
    #expect(AgentRuntimeConfigDocument.validatedEnvVars(.array([])).error == "envVars must be an object")
}

// MARK: - Atomic sections

@Test func credentialUseIsRecordedOnceInsideTheThrottle() async throws {
    let directory = EmailLoginDirectory()
    let token = directory.mintAgentCredential(agentId: "agent-throttle", scopes: ["read"], name: "t")
    let store = directory.agentsRuntimeStore
    let recorded = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<16 {
            group.addTask {
                store.recordCredentialUse(token: token, now: Date(), defaultThrottleMs: 60_000) != nil
            }
        }
        var count = 0
        for await value in group where value { count += 1 }
        return count
    }
    #expect(recorded == 1)
    #expect(store.recordCredentialUse(token: "unknown", now: Date(), defaultThrottleMs: 0) == nil)
}

@Test func assistantLinkClaimIsOneCriticalSection() async throws {
    let directory = EmailLoginDirectory()
    let store = directory.agentsRuntimeStore
    let winners = await withTaskGroup(of: Bool.self) { group in
        for index in 0..<8 {
            group.addTask {
                store.claimAssistantOwner(agentId: "assistant-\(index)", userId: "owner", isLive: { _ in true })
            }
        }
        var count = 0
        for await value in group where value { count += 1 }
        return count
    }
    #expect(winners == 1)
    let linked = (0..<8).filter { store.assistantOwner(agentId: "assistant-\($0)") == "owner" }
    #expect(linked.count == 1)
    #expect(store.hasAssistantConflict(userId: "owner", agentId: "other", isLive: { _ in true }))
    #expect(!store.hasAssistantConflict(userId: "owner", agentId: "other", isLive: { _ in false }))
}

@Test func machineStatusVersionBumpsNeverRepeat() async throws {
    let directory = EmailLoginDirectory()
    let versions = await withTaskGroup(of: Int.self) { group in
        for _ in 0..<64 {
            group.addTask { directory.bumpMachineStatusVersion(machineId: "machine-bump") }
        }
        var seen: [Int] = []
        for await value in group { seen.append(value) }
        return seen
    }
    #expect(Set(versions).count == 64)
    #expect(versions.max() == 64)
}

@Test func hostedModelChangeKeepsOneConsistentRow() async throws {
    let directory = EmailLoginDirectory()
    directory.setHostedModelForTesting(agentId: "agent-model")
    directory.enableHostedModelPicker(serverId: "server-model")
    let store = directory.agentsRuntimeStore
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<16 {
            group.addTask {
                _ = store.changeHostedModel(
                    agentId: "agent-model",
                    serverId: "server-model",
                    requested: index.isMultiple(of: 2) ? "deepseek-flash" : "gpt-5.6-luna",
                    defaultModel: "none"
                )
            }
        }
    }
    let state = try #require(store.hostedSnapshot(agentId: "agent-model").models)
    let option = try #require(state.models.first { $0.id == state.model })
    #expect(state.label == option.label)
    #expect(state.source == "chosen")
}

@Test func hostedRetryDecidesAndWritesInOneSection() throws {
    let directory = EmailLoginDirectory()
    let store = directory.agentsRuntimeStore
    directory.setHostedRuntimeForTesting(agentId: "agent-retry", provider: "antiproton", state: "failed", retryNeedsModel: true)
    directory.setHostedModelForTesting(agentId: "agent-retry", model: "gpt-5.6-luna", label: "GPT-5.6 Luna", source: "chosen")
    func retry(provided: Bool, model: String?) -> HostedRetryOutcome {
        store.retryHostedProvisioning(
            agentId: "agent-retry", serverId: "server-retry",
            modelProvided: provided, providedModel: model, defaultModel: "deepseek-flash"
        )
    }
    guard case .modelRequired = retry(provided: false, model: nil) else {
        Issue.record("a failed row that needs a model refuses a bare retry")
        return
    }
    guard case .pickerDisabled = retry(provided: true, model: "gpt-5.6-luna") else {
        Issue.record("a picked model needs the server picker")
        return
    }
    directory.enableHostedModelPicker(serverId: "server-retry")
    guard case .modelNotOffered = retry(provided: true, model: "nope") else {
        Issue.record("an unoffered model is refused")
        return
    }
    guard case .retried(let row) = retry(provided: true, model: "deepseek-flash") else {
        Issue.record("an offered model retries")
        return
    }
    #expect(row.state == "provisioning")
    #expect(row.retryNeedsModel == false)
    #expect(store.hostedSnapshot(agentId: "agent-retry").models?.source == "chosen")
    guard case .missing = store.retryHostedProvisioning(
        agentId: "unknown", serverId: "server-retry", modelProvided: false, providedModel: nil, defaultModel: "x"
    ) else {
        Issue.record("an unknown agent is missing")
        return
    }
}

// MARK: - Ordered bodies and refusals

@Test func agentPrivateSurfaceBodiesKeepTheirPublishedOrder() {
    let projection = AgentRuntimeProjection(
        id: "a1", name: "n", runtime: "claude", model: "m", external: false,
        envVarsJSON: "{\"K\":\"https:\\/\\/x\"}", runtimeConfigJSON: "{\"v\":1}"
    )
    #expect(projection.broadcastJSON == "{\"id\":\"a1\",\"name\":\"n\",\"runtime\":\"claude\",\"model\":\"m\",\"external\":false,\"machineId\":null,\"reasoningEffort\":null,\"envVars\":null,\"runtimeConfig\":{\"v\":1}}")
    let created = CreatedAgentResponse(
        agent: projection, creatorId: "u1", displayName: "D", description: nil, avatarUrl: "pixel:mug",
        serverRole: "admin", hostedProvider: "antiproton"
    )
    #expect(created.jsonBody.render() == "{\"id\":\"a1\",\"name\":\"n\",\"runtime\":\"claude\",\"model\":\"m\",\"external\":false,\"machineId\":null,\"reasoningEffort\":null,\"envVars\":{\"K\":\"https:\\/\\/x\"},\"runtimeConfig\":{\"v\":1},\"creator\":{\"type\":\"human\",\"id\":\"u1\"},\"displayName\":\"D\",\"description\":null,\"avatarUrl\":\"pixel:mug\",\"serverRole\":\"admin\",\"hostedRuntime\":{\"kind\":\"antiproton\",\"state\":\"provisioning\"}}")

    let summary = AgentSummary(
        id: "a", name: "n", displayName: "N", runtime: "external", model: "external", external: true,
        serverRole: "member", creatorId: nil, description: "d", includesLastSeen: true, lastSeenAt: nil,
        config: .init(runtimeConfigJSON: "null", envVarsJSON: "null")
    )
    #expect(AgentListResponse(agents: [summary]).jsonBody.render() == "[{\"id\":\"a\",\"name\":\"n\",\"displayName\":\"N\",\"runtime\":\"external\",\"model\":\"external\",\"external\":true,\"serverRole\":\"member\",\"creator\":null,\"description\":\"d\",\"lastSeenAt\":null,\"runtimeConfig\":null,\"envVars\":null}]")
    #expect(AgentDetailResponse.guest(id: "a", name: "n", displayName: "N", description: nil).jsonBody.render() == "{\"id\":\"a\",\"name\":\"n\",\"displayName\":\"N\",\"avatarUrl\":null,\"description\":null,\"profileProjection\":\"channel_summary\"}")
    #expect(AgentAvatarResponse(avatarUrl: "/api/avatars/users/k.webp").jsonBody.render() == "{\"avatarUrl\":\"/api/avatars/users/k.webp\"}")
    #expect(AssistantOwnerInboxResponse(ownerUserId: "o", items: [
        .init(kind: "thread", channelId: "c", unreadCount: 2, parentChannelId: "p"),
        .init(kind: "channel", channelId: "d", unreadCount: 1, parentChannelId: nil),
    ]).jsonBody.render() == "{\"owner\":{\"userId\":\"o\"},\"items\":[{\"kind\":\"thread\",\"channelId\":\"c\",\"unreadCount\":2,\"parentChannelId\":\"p\"},{\"kind\":\"channel\",\"channelId\":\"d\",\"unreadCount\":1}]}")
    #expect(HostedModelViewResponse(
        models: [.init(id: "m", label: "M", provider: "p")], defaultModel: "m", defaultLabel: nil,
        model: nil, label: nil, source: "default", locked: false, picker: true
    ).jsonBody.render() == "{\"models\":[{\"id\":\"m\",\"label\":\"M\",\"provider\":\"p\"}],\"default\":\"m\",\"defaultLabel\":null,\"model\":null,\"label\":null,\"source\":\"default\",\"locked\":false,\"picker\":true}")
    #expect(HostedRuntimeStatusResponse(
        agentId: "a", provider: "p", model: nil, state: "active", retryNeedsModel: true,
        createdAt: "2026-01-01T00:00:00.000Z", includesOnboardingSetup: false
    ).jsonBody.render() == "{\"hostedRuntime\":{\"agentId\":\"a\",\"provider\":\"p\",\"model\":null,\"state\":\"active\",\"retryNeedsModel\":true,\"createdAt\":\"2026-01-01T00:00:00.000Z\"}}")
    #expect(OnboardingAdoptionResponse(
        canAdopt: false, changes: [], appliedChanges: [.init(field: "name", before: "x", after: "Cindy")],
        agent: .init(id: "a", name: "Cindy", displayName: "Cindy", description: nil, avatarUrl: "pixel:mug", serverRole: "admin")
    ).jsonBody.render() == "{\"canAdopt\":false,\"changes\":[],\"appliedChanges\":[{\"field\":\"name\",\"before\":\"x\",\"after\":\"Cindy\"}],\"agent\":{\"id\":\"a\",\"name\":\"Cindy\",\"displayName\":\"Cindy\",\"description\":null,\"avatarUrl\":\"pixel:mug\",\"serverRole\":\"admin\"}}")
    #expect(ProviderConnectionStatusReply.unsupported(provider: "github").jsonBody.render() == "{\"provider\":\"github\",\"supported\":false}")
}

@Test func agentPrivateSurfaceRefusalsKeepTheirPublishedBodies() {
    func body(_ error: AgentPrivateSurfaceError) -> String { error.publishedErrorBody.render() }
    #expect(body(.agentMissing) == "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
    #expect(body(.onboardingAgentExists(agentId: "x")) == "{\"error\":\"Onboarding agent already exists\",\"onboardingAgentId\":\"x\"}")
    #expect(body(.avatarTooLarge(maxBytes: 5_242_880)) == "{\"error\":\"Avatar image must be 5 MB or smaller\",\"errorCode\":\"PROFILE_AVATAR_TOO_LARGE\",\"maxBytes\":5242880}")
    #expect(body(.modelNotAvailable) == "{\"error\":\"The selected model is not available on this Computer\",\"issues\":[{\"pointer\":\"/formValues/model\",\"code\":\"model_not_available\"}]}")
    #expect(body(.invalidRestartMode("a\"b")) == "{\"error\":\"Invalid restart mode: a\"b\"}")
    #expect(body(.assistantAlreadySet) == "{\"code\":\"assistant_already_set\",\"error\":\"This user already has an assistant\"}")
    #expect(body(.authRequired) == "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
    #expect(body(.tokenInvalid) == "{\"error\":\"token_invalid\",\"code\":\"token_invalid\"}")
    func machines(_ error: MachinesAndHostedRuntimeError) -> String { error.publishedErrorBody.render() }
    #expect(machines(.connectionAgentNotActive(state: "failed")) == "{\"error\":\"The agent is not provisioned on its provider yet\",\"code\":\"agent_connection_agent_not_active\",\"state\":\"failed\"}")
    #expect(machines(.connectionProviderError(providerCode: nil, providerMessage: nil, providerStatus: nil)) == "{\"error\":\"The provider could not complete the request\",\"code\":\"agent_connection_provider_error\",\"providerCode\":null,\"providerMessage\":null,\"providerStatus\":null}")
    #expect(machines(.connectionProviderRefused(message: "m", providerCode: "c", providerMessage: "m", providerStatus: 409)) == "{\"error\":\"m\",\"code\":\"agent_connection_provider_refused\",\"providerCode\":\"c\",\"providerMessage\":\"m\",\"providerStatus\":409}")
    #expect(machines(.connectionConnectorDisconnectPartial(failedCount: 2)) == "{\"error\":\"Disconnect partially completed; retry to finish\",\"code\":\"agent_connection_connector_disconnect_partial\",\"failedCount\":2}")
    #expect(machines(.modelRequired) == "{\"error\":\"The provider refused the picked model; retry with `model` set to an offered id, or null for the default\",\"code\":\"hosted_runtime_model_required\"}")
}
