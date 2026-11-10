import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// Byte-exact bodies the runtime-form surface publishes (the strings below are
/// the literals the retired handlers concatenated) and the single critical
/// section behind each atomic decision.

// MARK: - Byte-exact bodies

/// Complete released Node fixture; Chinese changes only the display copy at
/// uiSchema.localization (runtimeFormV2Copy.ts119-134). Key order is not schema.
@Test func builtinV2FormUsesTheReleasedNodeSchemaAndLocalizedCopy() throws {
    func canonicalJSON(_ text: String) throws -> Data {
        let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    let englishGolden = #"""
{
  "protocolVersion": 2,
  "runtimeId": "builtin",
  "schemaVersion": "builtin-pi.create.v3",
  "dataSchema": {
    "type": "object",
    "additionalProperties": false,
    "required": [
      "providerId",
      "apiKey",
      "model"
    ],
    "properties": {
      "providerId": {
        "type": "string",
        "title": "Provider",
        "minLength": 1,
        "x-optionSource": "provider"
      },
      "apiKey": {
        "type": "string",
        "title": "API Key",
        "minLength": 1,
        "writeOnly": true
      },
      "baseUrl": {
        "type": "string",
        "title": "Base URL",
        "minLength": 1,
        "format": "uri"
      },
      "supportsImageInput": {
        "type": "boolean",
        "title": "Image input"
      },
      "loadLocalPlugins": {
        "type": "boolean",
        "title": "Load local Pi plugins"
      },
      "model": {
        "type": "string",
        "title": "Model",
        "minLength": 1,
        "x-optionSource": "model"
      },
      "envVars": {
        "type": "object",
        "title": "Environment Variables",
        "additionalProperties": {
          "type": "string"
        }
      }
    }
  },
  "uiSchema": {
    "order": [
      "providerId",
      "apiKey",
      "baseUrl",
      "supportsImageInput",
      "model",
      "loadLocalPlugins",
      "envVars"
    ],
    "layout": {
      "advanced": [
        "/loadLocalPlugins",
        "/envVars"
      ]
    },
    "visibility": [
      {
        "pointer": "/baseUrl",
        "when": {
          "pointer": "/providerId",
          "in": [
            "openai-compatible",
            "anthropic-compatible"
          ]
        }
      },
      {
        "pointer": "/supportsImageInput",
        "when": {
          "pointer": "/providerId",
          "in": [
            "openai-compatible",
            "anthropic-compatible"
          ]
        }
      }
    ],
    "localization": {
      "providerId": {
        "label": "Provider",
        "hint": "Built-in Pi is ready to use without local runtime setup. It uses the provider key entered here."
      },
      "apiKey": {
        "label": "API Key",
        "placeholder": "sk-..."
      },
      "baseUrl": {
        "label": "Base URL",
        "placeholder": "https://gateway.example.com/v1"
      },
      "supportsImageInput": {
        "label": "Supports image input",
        "hint": "Enable only when this gateway endpoint and model accept images."
      },
      "model": {
        "label": "Model",
        "placeholder": "Model ID",
        "hint": "Use a model ID the selected provider supports."
      },
      "loadLocalPlugins": {
        "label": "Load local Pi extensions",
        "hint": "Load enabled Pi extensions installed on the computer running this agent. Applying changes restarts a running agent."
      },
      "envVars": {
        "label": "Environment Variables",
        "hint": "These will be injected into the runtime command environment."
      }
    }
  },
  "capabilities": {
    "providerKinds": [
      "preset",
      "gateway"
    ],
    "writeOnlyPointers": [
      "/apiKey"
    ],
    "forbiddenPointers": [
      "/hostUserState"
    ]
  },
  "optionSources": {
    "provider": {
      "protocolVersion": 1,
      "runtimeId": "builtin",
      "schemaVersion": "builtin-pi.create.v3",
      "sourceId": "provider",
      "kind": "select",
      "pointer": "/providerId"
    },
    "model": {
      "protocolVersion": 1,
      "runtimeId": "builtin",
      "schemaVersion": "builtin-pi.create.v3",
      "sourceId": "model",
      "kind": "dependent_select",
      "pointer": "/model",
      "dependsOn": "/providerId"
    }
  },
  "requiredClientCapabilities": [
    "option_source.status"
  ]
}
"""#
    let chineseGolden = #"""
{
  "protocolVersion": 2,
  "runtimeId": "builtin",
  "schemaVersion": "builtin-pi.create.v3",
  "dataSchema": {
    "type": "object",
    "additionalProperties": false,
    "required": [
      "providerId",
      "apiKey",
      "model"
    ],
    "properties": {
      "providerId": {
        "type": "string",
        "title": "Provider",
        "minLength": 1,
        "x-optionSource": "provider"
      },
      "apiKey": {
        "type": "string",
        "title": "API Key",
        "minLength": 1,
        "writeOnly": true
      },
      "baseUrl": {
        "type": "string",
        "title": "Base URL",
        "minLength": 1,
        "format": "uri"
      },
      "supportsImageInput": {
        "type": "boolean",
        "title": "Image input"
      },
      "loadLocalPlugins": {
        "type": "boolean",
        "title": "Load local Pi plugins"
      },
      "model": {
        "type": "string",
        "title": "Model",
        "minLength": 1,
        "x-optionSource": "model"
      },
      "envVars": {
        "type": "object",
        "title": "Environment Variables",
        "additionalProperties": {
          "type": "string"
        }
      }
    }
  },
  "uiSchema": {
    "order": [
      "providerId",
      "apiKey",
      "baseUrl",
      "supportsImageInput",
      "model",
      "loadLocalPlugins",
      "envVars"
    ],
    "layout": {
      "advanced": [
        "/loadLocalPlugins",
        "/envVars"
      ]
    },
    "visibility": [
      {
        "pointer": "/baseUrl",
        "when": {
          "pointer": "/providerId",
          "in": [
            "openai-compatible",
            "anthropic-compatible"
          ]
        }
      },
      {
        "pointer": "/supportsImageInput",
        "when": {
          "pointer": "/providerId",
          "in": [
            "openai-compatible",
            "anthropic-compatible"
          ]
        }
      }
    ],
    "localization": {
      "providerId": {
        "label": "提供方",
        "hint": "内置 Pi 无需本地运行时设置即可使用。它会使用这里填写的提供方密钥。"
      },
      "apiKey": {
        "label": "API 密钥",
        "placeholder": "sk-..."
      },
      "baseUrl": {
        "label": "Base URL",
        "placeholder": "https://gateway.example.com/v1"
      },
      "supportsImageInput": {
        "label": "支持图片输入",
        "hint": "仅当此 gateway endpoint 和模型接受图片时开启。"
      },
      "model": {
        "label": "模型",
        "placeholder": "模型 ID",
        "hint": "请填写所选提供方支持的模型 ID。"
      },
      "loadLocalPlugins": {
        "label": "加载本机 Pi 扩展",
        "hint": "加载运行此 Agent 的电脑上已安装并启用的 Pi 扩展。应用更改会重启正在运行的 Agent。"
      },
      "envVars": {
        "label": "环境变量",
        "hint": "这些变量会注入到运行时命令的环境中。"
      }
    }
  },
  "capabilities": {
    "providerKinds": [
      "preset",
      "gateway"
    ],
    "writeOnlyPointers": [
      "/apiKey"
    ],
    "forbiddenPointers": [
      "/hostUserState"
    ]
  },
  "optionSources": {
    "provider": {
      "protocolVersion": 1,
      "runtimeId": "builtin",
      "schemaVersion": "builtin-pi.create.v3",
      "sourceId": "provider",
      "kind": "select",
      "pointer": "/providerId"
    },
    "model": {
      "protocolVersion": 1,
      "runtimeId": "builtin",
      "schemaVersion": "builtin-pi.create.v3",
      "sourceId": "model",
      "kind": "dependent_select",
      "pointer": "/model",
      "dependsOn": "/providerId"
    }
  },
  "requiredClientCapabilities": [
    "option_source.status"
  ]
}
"""#
    let schema = "builtin-pi.create.v3"
    let english = RuntimeFormDefinitionResponse.builtinV2(schemaVersion: schema, chinese: false).jsonBody.render()
    let chinese = RuntimeFormDefinitionResponse.builtinV2(schemaVersion: schema, chinese: true).jsonBody.render()
    #expect(try canonicalJSON(english) == canonicalJSON(englishGolden))
    #expect(try canonicalJSON(chinese) == canonicalJSON(chineseGolden))
}

@Test func genericFormDefinitionsKeepTheLegacyBytes() {
    #expect(
        RuntimeFormDefinitionResponse.selectV2(runtimeId: "cursor", schemaVersion: "cursor.create.v1", chinese: false)
            .jsonBody.render()
            == "{\"protocolVersion\":2,\"runtimeId\":\"cursor\",\"schemaVersion\":\"cursor.create.v1\",\"requiredClientCapabilities\":[\"option_source.status\"],\"fields\":[{\"key\":\"model\",\"kind\":\"select\",\"label\":\"Model\",\"required\":true}],\"capabilities\":{\"providerKinds\":[\"preset\"],\"writeOnlyPointers\":[\"/apiKey\"],\"forbiddenPointers\":[\"/hostUserState\"]}}"
    )
    #expect(
        RuntimeFormDefinitionResponse.selectV1(runtimeId: "claude", schemaVersion: "claude.create.v1")
            .jsonBody.render()
            == "{\"protocolVersion\":1,\"runtimeId\":\"claude\",\"schemaVersion\":\"claude.create.v1\",\"dataSchema\":{\"type\":\"object\",\"properties\":{\"model\":{\"type\":\"string\"}},\"required\":[\"model\"]},\"uiSchema\":{},\"capabilities\":{\"providerKinds\":[\"preset\"],\"writeOnlyPointers\":[\"/apiKey\"],\"forbiddenPointers\":[\"/hostUserState\"]},\"optionSources\":{\"model\":{\"protocolVersion\":1,\"runtimeId\":\"claude\",\"schemaVersion\":\"claude.create.v1\",\"sourceId\":\"model\"}}}"
    )
    #expect(RuntimeFormDefinitionResponse.catalog("{ \"raw\": 1 }").jsonBody.render() == "{ \"raw\": 1 }")
}

@Test func modelOptionSourcesKeepTheLegacyBytes() {
    let efforts = RuntimeModelProbeModel(
        id: "grok-4.5",
        label: "Grok 4.5",
        supportedReasoningEfforts: ["high", "low"],
        defaultReasoningEffort: "high"
    )
    let live = RuntimeOptionSourceResponse.model(RuntimeModelSourceBody(
        runtimeId: "codex",
        schemaVersion: "codex.create.v1",
        options: [RuntimeProbeOption(efforts, reasoning: true), RuntimeProbeOption(
            RuntimeModelProbeModel(id: "b", label: "B"),
            reasoning: true
        )],
        defaultValue: "grok-4.5",
        customValueAllowed: true,
        status: "live"
    ))
    #expect(live.jsonBody.render() == "{\"protocolVersion\":1,\"runtimeId\":\"codex\",\"schemaVersion\":\"codex.create.v1\",\"sourceId\":\"model\",\"kind\":\"select\",\"pointer\":\"/model\",\"options\":[{\"value\":\"grok-4.5\",\"label\":\"Grok 4.5\",\"supportedReasoningEfforts\":[\"high\",\"low\"],\"defaultReasoningEffort\":\"high\"},{\"value\":\"b\",\"label\":\"B\"}],\"defaultValue\":\"grok-4.5\",\"customValueAllowed\":true,\"status\":\"live\"}")

    let fallback = RuntimeOptionSourceResponse.model(RuntimeModelSourceBody(
        runtimeId: "grok",
        schemaVersion: "grok.create.v1",
        options: [RuntimeProbeOption(RuntimeModelProbeModel(id: "grok-4.6", label: "Grok 4.6"), reasoning: true)],
        defaultValue: "grok-4.5",
        status: "fallback",
        reason: "probe_failed",
        retryable: true
    ))
    #expect(fallback.jsonBody.render() == "{\"protocolVersion\":1,\"runtimeId\":\"grok\",\"schemaVersion\":\"grok.create.v1\",\"sourceId\":\"model\",\"kind\":\"select\",\"pointer\":\"/model\",\"options\":[{\"value\":\"grok-4.6\",\"label\":\"Grok 4.6\"}],\"defaultValue\":\"grok-4.5\",\"status\":\"fallback\",\"reason\":\"probe_failed\",\"retryable\":true}")

    // A reasoning=false option never publishes effort metadata.
    #expect(RuntimeProbeOption(efforts, reasoning: false).jsonBody.render() == "{\"value\":\"grok-4.5\",\"label\":\"Grok 4.5\"}")
}

@Test func builtinSourcesAndStaticSourcesKeepTheLegacyBytes() {
    let bundled = BuiltinModelSourceBody.bundledGroups()
    #expect(
        RuntimeOptionSourceResponse.builtinModel(BuiltinModelSourceBody(
            schemaVersion: "builtin-pi.create.v3",
            groups: bundled,
            status: "fallback",
            reason: "machine_offline",
            retryable: true
        )).jsonBody.render()
            == "{\"protocolVersion\":1,\"runtimeId\":\"builtin\",\"schemaVersion\":\"builtin-pi.create.v3\",\"sourceId\":\"model\",\"kind\":\"dependent_select\",\"pointer\":\"/model\",\"dependsOn\":\"/providerId\",\"optionsByValue\":{\"deepseek\":[{\"value\":\"deepseek/deepseek-v4-pro\",\"label\":\"DeepSeek V4 Pro\"},{\"value\":\"deepseek/deepseek-flash\",\"label\":\"DeepSeek V4.1 Flash\"}],\"moonshotai\":[{\"value\":\"moonshotai/kimi-k2.7-code\",\"label\":\"Kimi K2.7 Code\"},{\"value\":\"moonshotai/kimi-k2.7-code-highspeed\",\"label\":\"Kimi K2.7 Code HighSpeed\"},{\"value\":\"moonshotai/kimi-k3\",\"label\":\"Kimi K3\"},{\"value\":\"moonshotai/kimi-k2.6\",\"label\":\"Kimi K2.6\"}]},\"defaultValueByValue\":{\"deepseek\":\"deepseek/deepseek-v4-pro\",\"moonshotai\":\"moonshotai/kimi-k2.6\"},\"customValueAllowedByValue\":{\"deepseek\":false,\"moonshotai\":false},\"status\":\"fallback\",\"reason\":\"machine_offline\",\"retryable\":true}"
    )
    #expect(
        RuntimeOptionSourceResponse.builtinModel(BuiltinModelSourceBody(
            schemaVersion: "s",
            groups: [],
            status: "unavailable",
            reason: "probe_timeout",
            retryable: true
        )).jsonBody.render()
            == "{\"protocolVersion\":1,\"runtimeId\":\"builtin\",\"schemaVersion\":\"s\",\"sourceId\":\"model\",\"kind\":\"dependent_select\",\"pointer\":\"/model\",\"dependsOn\":\"/providerId\",\"optionsByValue\":{},\"defaultValueByValue\":{},\"customValueAllowedByValue\":{},\"status\":\"unavailable\",\"reason\":\"probe_timeout\",\"retryable\":true}"
    )
    #expect(
        RuntimeOptionSourceResponse.builtinProvider(schemaVersion: "s", chinese: true).jsonBody.render()
            == "{\"sourceId\":\"provider\",\"schemaVersion\":\"s\",\"kind\":\"select\",\"options\":[{\"value\":\"deepseek\",\"label\":\"DeepSeek\",\"providerKind\":\"preset\"},{\"value\":\"moonshotai\",\"label\":\"月之暗面\",\"providerKind\":\"preset\"}]}"
    )
    #expect(
        RuntimeOptionSourceResponse.cachedModels(
            schemaVersion: "s",
            models: [RuntimeModelChoice(value: "m1", label: "M \"1\"")]
        ).jsonBody.render()
            == "{\"sourceId\":\"model\",\"schemaVersion\":\"s\",\"kind\":\"select\",\"options\":[{\"value\":\"m1\",\"label\":\"M \\\"1\\\"\"}]}"
    )
}

@Test func agentRuntimeFormValuesPrintSortedWithTheEscapedSlashOfTheLegacyEncoder() {
    let response = AgentRuntimeFormResponse(
        runtimeId: "claude",
        schemaVersion: "claude.create.v1",
        modelLabel: "Model",
        values: AgentRuntimeFormValues(
            apiUrl: "https://gateway.example.test",
            command: "/opt/claude",
            envVars: ["KEEP": "1", "A": "b/c"],
            fastMode: false,
            model: "sonnet",
            provider: "custom",
            reasoningEffort: "high"
        ),
        writeOnlyPointers: ["/apiKey"]
    )
    #expect(response.jsonBody.render() == "{\"protocolVersion\":2,\"runtimeId\":\"claude\",\"schemaVersion\":\"claude.create.v1\",\"fields\":[{\"key\":\"model\",\"kind\":\"select\",\"label\":\"Model\",\"required\":true}],\"values\":{\"apiUrl\":\"https:\\/\\/gateway.example.test\",\"command\":\"\\/opt\\/claude\",\"envVars\":{\"A\":\"b\\/c\",\"KEEP\":\"1\"},\"fastMode\":false,\"model\":\"sonnet\",\"provider\":\"custom\",\"reasoningEffort\":\"high\"},\"capabilities\":{\"providerKinds\":[\"preset\"],\"writeOnlyPointers\":[\"/apiKey\"],\"forbiddenPointers\":[\"/hostUserState\"]}}")
    let bare = AgentRuntimeFormResponse(
        runtimeId: "gemini",
        schemaVersion: "gemini.create.v1",
        modelLabel: "模型",
        values: AgentRuntimeFormValues(),
        writeOnlyPointers: []
    )
    #expect(bare.jsonBody.render() == "{\"protocolVersion\":2,\"runtimeId\":\"gemini\",\"schemaVersion\":\"gemini.create.v1\",\"fields\":[{\"key\":\"model\",\"kind\":\"select\",\"label\":\"模型\",\"required\":true}],\"values\":{\"envVars\":{}},\"capabilities\":{\"providerKinds\":[\"preset\"],\"writeOnlyPointers\":[],\"forbiddenPointers\":[\"/hostUserState\"]}}")
}

@Test func runtimeConfigProjectionKeepsTheLegacyPerFieldLeniency() {
    let config = AgentRuntimeConfigProjection.parse(
        "{\"model\":{\"id\":5,\"name\":\"n\"},\"provider\":{\"kind\":\"k\",\"apiUrl\":3},\"reasoningEffort\":1,\"fastMode\":1,\"command\":null,\"envVars\":{\"A\":\"1\",\"B\":2}}"
    )
    #expect(config.model?.id == nil && config.model?.name == "n")
    #expect(config.provider?.kind == "k" && config.provider?.apiUrl == nil)
    #expect(config.reasoningEffort == nil)
    #expect(config.fastMode == true)
    #expect(config.command == nil)
    #expect(config.envVars == nil)
    #expect(AgentRuntimeConfigProjection.parse("[1]").model == nil)
    #expect(AgentRuntimeConfigProjection.parse(nil).envVars == nil)
}

@Test func runtimeOptionsModelsWorkspacesAndUsageKeepTheLegacyBytes() {
    let options = MachineRuntimeOptionsResponse(machineId: "m", options: [
        .init(runtimeId: "claude", capabilityStatus: "available", canSelectInThisContext: true, runtimeFormV2: false, formDefinitionSchemaVersion: "claude.create.v1"),
        .init(runtimeId: "codex", capabilityStatus: "not_installed", canSelectInThisContext: false, runtimeFormV2: true, formDefinitionSchemaVersion: nil),
    ])
    #expect(options.jsonBody.render() == "{\"context\":\"new_agent\",\"machineId\":\"m\",\"options\":[{\"runtimeId\":\"claude\",\"capabilityStatus\":\"available\",\"admissionStatus\":\"available_for_new\",\"admissionReason\":null,\"current\":false,\"availableForNew\":true,\"manageableForCurrentAgent\":false,\"canSelectInThisContext\":true,\"formDefinitionRef\":{\"protocolVersion\":1,\"runtimeId\":\"claude\",\"schemaVersion\":\"claude.create.v1\"}},{\"runtimeId\":\"codex\",\"capabilityStatus\":\"not_installed\",\"admissionStatus\":\"available_for_new\",\"admissionReason\":null,\"current\":false,\"availableForNew\":true,\"manageableForCurrentAgent\":false,\"canSelectInThisContext\":false,\"runtimeFormV2\":{\"protocolVersion\":2}}]}")

    let models = [RuntimeModelChoice(value: "a", label: "A")]
    #expect(MachineRuntimeModelsResponse.live(models: models, defaultModel: "a").jsonBody.render()
        == "{\"kind\":\"live\",\"value\":{\"models\":[{\"id\":\"a\",\"label\":\"A\"}],\"default\":\"a\"},\"models\":[{\"id\":\"a\",\"label\":\"A\"}],\"default\":\"a\"}")
    #expect(MachineRuntimeModelsResponse.live(models: [], defaultModel: nil).jsonBody.render()
        == "{\"kind\":\"live\",\"value\":{\"models\":[],\"default\":null},\"models\":[],\"default\":null}")
    #expect(MachineRuntimeModelsResponse.plainModels(models: models, defaultModel: nil).jsonBody.render()
        == "{\"models\":[{\"id\":\"a\",\"label\":\"A\"}],\"default\":null}")
    #expect(MachineRuntimeModelsResponse.computerOffline.jsonBody.render() == "{\"kind\":\"error\",\"retryable\":true,\"code\":\"computer_offline\"}")
    #expect(MachineRuntimeModelsResponse.missingConfig.jsonBody.render() == "{\"kind\":\"missing_config\",\"recovery\":\"kimi_login\"}")
    #expect(MachineRuntimeModelsResponse.noModels.jsonBody.render() == "{\"kind\":\"no_models\"}")
    #expect(MachineRuntimeModelsResponse.unsupported.jsonBody.render() == "{\"kind\":\"unsupported\"}")
    #expect(MachineRuntimeModelsResponse.error(code: "").jsonBody.render() == "{\"kind\":\"error\",\"retryable\":true}")
    #expect(MachineRuntimeModelsResponse.error(code: "boom").jsonBody.render() == "{\"kind\":\"error\",\"retryable\":true,\"code\":\"boom\"}")

    #expect(MachineWorkspacesResponse(rows: []).jsonBody.render() == "[]")
    #expect(MachineWorkspacesResponse(rows: [.init(directoryName: "d", totalSizeBytes: 1234, lastModified: "2026-11-09T06:22:33.456Z", fileCount: 3, displayPath: "~/.raft/agents/d/", status: "stopped", agentName: "N", agentStatus: "inactive")]).jsonBody.render()
        == "[{\"directoryName\":\"d\",\"totalSizeBytes\":1234,\"lastModified\":\"2026-11-09T06:22:33.456Z\",\"fileCount\":3,\"displayPath\":\"~/.raft/agents/d/\",\"status\":\"stopped\",\"agentName\":\"N\",\"agentStatus\":\"inactive\"}]")

    #expect(RuntimeAccountUsageResponse(state: "missing", snapshotJSON: nil).jsonBody.render() == "{\"state\":\"missing\",\"snapshot\":null}")
    #expect(RuntimeAccountUsageResponse(state: "fresh", snapshotJSON: "{\"a\":1}").jsonBody.render() == "{\"state\":\"fresh\",\"snapshot\":{\"a\":1}}")
    #expect(RuntimeAccountUsageRefreshResponse(state: "fresh", snapshotJSON: "{}").jsonBody.render() == "{\"accepted\":true,\"state\":\"fresh\",\"snapshot\":{}}")
    #expect(RuntimeAccountUsageRefreshResponse(state: "timeout").jsonBody.render() == "{\"accepted\":true,\"state\":\"timeout\"}")
}

@Test func settingsAndRegistrationBodiesKeepTheLegacyBytes() {
    let onboarding = OnboardingSettingsResponse(
        onboardingAgentId: "a",
        agentAllChannelGreetingEnabled: true,
        onboardingWizardEnabled: false,
        setupModalReminderOptOut: true,
        dismissedAddComputerStepAt: "2026-01-01T00:00:00.000Z",
        dismissedCreateAgentStepAt: nil,
        dismissedInviteStepAt: nil,
        dismissedCommunityStepAt: nil,
        dismissedNotificationStepAt: nil,
        onboardingWizardCurrentStep: nil
    )
    let body = "{\"onboardingAgentId\":\"a\",\"agentAllChannelGreetingEnabled\":true,\"onboardingWizardEnabled\":false,\"setupModalReminderOptOut\":true,\"dismissedAddComputerStepAt\":\"2026-01-01T00:00:00.000Z\",\"dismissedCreateAgentStepAt\":null,\"dismissedInviteStepAt\":null,\"dismissedCommunityStepAt\":null,\"dismissedNotificationStepAt\":null,\"onboardingWizardCurrentStep\":null}"
    #expect(onboarding.jsonBody.render() == body)
    #expect(ServerSettingsResponse(onboarding: onboarding).jsonBody.render() == "{\"settings\":{\"onboardSettings\":\(body),\"feedbackSettings\":{\"enabled\":true}}}")

    let prefs = ServerNotificationSettingsResponse(serverPushMuted: false, serverPushMentionsOnly: true, serverPushMode: "mentions", prefsVersion: 2)
    #expect(prefs.jsonBody.render() == "{\"serverPushMuted\":false,\"serverPushMentionsOnly\":true,\"serverPushMode\":\"mentions\",\"prefsVersion\":2}")
    #expect(prefs.updatedEventPayload(serverId: "s") == "{\"serverId\":\"s\",\"scopeId\":\"s\",\"prefs\":{\"serverPushMuted\":false,\"serverPushMentionsOnly\":true,\"serverPushMode\":\"mentions\"},\"prefsVersion\":2}")

    let machine = ServerMachineRegistrationResponse(id: "m", serverId: "s", name: "N", userId: "u", apiKey: "k")
    #expect(machine.jsonBody.render() == "{\"machine\":{\"id\":\"m\",\"serverId\":\"s\",\"name\":\"N\",\"userId\":\"u\",\"description\":null},\"apiKey\":\"k\"}")
    #expect(machine.updatedEventPayload() == "{\"serverId\":\"s\",\"machineId\":\"m\"}")
}

@Test func domainErrorsKeepTheLegacyBodies() {
    func body(_ error: RuntimeFormsAndProbesError) -> String { error.publishedErrorBody.render() }
    #expect(body(.unauthorized) == "{\"error\":\"Unauthorized\"}")
    #expect(body(.editAgentsRequired) == "{\"error\":\"The `editAgents` capability or human creator authority is required to edit agents\"}")
    #expect(body(.noRuntimeForm) == "{\"error\":\"This agent's runtime configuration has no editable runtime form\",\"issues\":[{\"code\":\"no_runtime_form\",\"pointer\":\"/runtimeConfig\"}]}")
    #expect(body(.runtimeFormNotFound) == "{\"error\":\"Runtime form not found\",\"issues\":[{\"code\":\"unknown_form_runtime\",\"pointer\":\"/runtimeId\"}]}")
    #expect(body(.runtimeFormOptionSourceNotFound) == "{\"error\":\"Runtime form option source not found\",\"issues\":[{\"code\":\"unknown_form_runtime\",\"pointer\":\"/runtimeId\"}]}")
    #expect(body(.unknownOptionSource) == "{\"error\":\"Runtime form option source not found\",\"issues\":[{\"code\":\"unknown_option_source\",\"pointer\":\"/sourceId\"}]}")
    #expect(body(.staleFormSchema) == "{\"error\":\"Runtime form schema is stale or unknown\",\"issues\":[{\"code\":\"stale_form_schema\",\"pointer\":\"/schemaVersion\"}]}")
    #expect(body(.builtinCatalogCapabilityRequired) == "{\"error\":\"This Computer is too old to prove which Built-in models it supports. Upgrade the Computer before selecting or starting this model.\",\"code\":\"builtin_catalog_capability_required\",\"daemonVersion\":\"1.0.17\",\"computerVersion\":\"1.0.17\",\"recovery\":\"upgrade_required\"}")
    #expect(body(.builtinCatalogUnavailable) == "{\"issues\":[{\"code\":\"builtin_catalog_unavailable\",\"pointer\":\"/optionSources/model\"}]}")
    #expect(body(.kimiSDKSource(code: "runtime_model_source_no_models")) == "{\"issues\":[{\"code\":\"runtime_model_source_no_models\",\"pointer\":\"/optionSources/model\"}]}")
    #expect(body(.editMachinesRequired(purpose: "inspect runtime models")) == "{\"error\":\"The `editMachines` capability or machine creator authority is required to inspect runtime models\"}")
    #expect(body(.attachingHumanRequired(purpose: "refresh runtime account usage")) == "{\"error\":\"The `editMachines` capability or attaching-human authority is required to refresh runtime account usage\"}")
    #expect(RuntimeFormsAndProbesError.invalidPushMode.status == 400)
    #expect(RuntimeFormsAndProbesError.staleFormSchema.status == 409)
    #expect(RuntimeAccountUsageRefreshDeferral.cooldown.publishedErrorBody.render() == "{\"accepted\":false,\"state\":\"cooldown\"}")
    #expect(RuntimeAccountUsageRefreshDeferral.requested.publishedErrorBody.render() == "{\"accepted\":true,\"state\":\"requested\"}")
    #expect(RuntimeAccountUsageRefreshDeferral.computerOffline.publishedErrorBody.render() == "{\"accepted\":false,\"state\":\"computer_offline\"}")
    #expect(RuntimeAccountUsageRefreshDeferral.cooldown.status == 202)
}

@Test func lenientRequestsKeepTheLegacyTypeReads() throws {
    let decoded = try JSONDecoder().decode(
        LenientJSONObjectRequest.self,
        from: Data("{\"a\":true,\"b\":1,\"c\":2,\"d\":1.0,\"e\":null,\"f\":\"x\",\"g\":[1]}".utf8)
    )
    #expect(decoded["a"]?.legacyBool == true)
    #expect(decoded["b"]?.legacyBool == true)
    #expect(decoded["c"]?.legacyBool == nil)
    #expect(decoded["d"]?.legacyBool == true)
    #expect(decoded["e"]?.isJSONNull == true && decoded["e"]?.legacyBool == nil)
    #expect(decoded["f"]?.legacyString == "x")
    #expect(decoded["g"] != nil && decoded["g"]?.legacyString == nil)
    #expect(decoded["missing"] == nil)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(LenientJSONObjectRequest.self, from: Data("[1]".utf8))
    }
}

// MARK: - Atomic sections

private func collectConcurrently<T: Sendable>(_ count: Int, _ work: @escaping @Sendable (Int) -> T) async -> [T] {
    await withTaskGroup(of: T.self) { group in
        for index in 0..<count {
            group.addTask { work(index) }
        }
        var results: [T] = []
        for await result in group { results.append(result) }
        return results
    }
}

@Test func usageRefreshClaimGrantsExactlyOneConcurrentRequest() async {
    let store = MachinesAndComputersStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let claims = await collectConcurrently(16) { _ in
        store.claimRuntimeAccountUsageRefresh(key: "m\nclaude", now: now, cooldown: 60)
    }
    #expect(claims.filter { $0 }.count == 1)
    // After the cooldown the slot opens again, once.
    let later = now.addingTimeInterval(61)
    let reclaims = await collectConcurrently(16) { _ in
        store.claimRuntimeAccountUsageRefresh(key: "m\nclaude", now: later, cooldown: 60)
    }
    #expect(reclaims.filter { $0 }.count == 1)
    #expect(store.runtimeAccountUsageRefreshInCooldown(key: "m\nclaude", now: later, cooldown: 60))
}

@Test func notificationPatchVersionAdvancesOncePerRealChange() async {
    let store = NotificationsStore()
    let results = await collectConcurrently(12) { _ in
        store.patchServerNotificationPref(key: "s\nu", mode: "mentions", muted: nil)
    }
    #expect(results.filter(\.changed).count == 1)
    #expect(store.serverNotificationPref(key: "s\nu").version == 1)
    #expect(store.serverNotificationPref(key: "s\nu").mentionsOnly)

    let muted = store.patchServerNotificationPref(key: "s\nu", mode: nil, muted: true)
    #expect(muted.changed && muted.prefs.mode == "none" && !muted.prefs.mentionsOnly && muted.prefs.version == 2)
    let unmuted = store.patchServerNotificationPref(key: "s\nu", mode: nil, muted: false)
    #expect(unmuted.prefs.mode == "all" && !unmuted.prefs.muted && unmuted.prefs.version == 3)
    // A patch that changes nothing keeps the version.
    let same = store.patchServerNotificationPref(key: "s\nu", mode: "all", muted: nil)
    #expect(!same.changed && same.prefs.version == 3)
}

@Test func onboardingPatchWritesServerAndMemberRowsInOneSection() async {
    let store = ServersAndChannelsStore()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshots = await collectConcurrently(12) { index in
        var patch = ServersAndChannelsStore.OnboardingPatch(isAdmin: true)
        patch.agentId = .set("agent-\(index)")
        patch.dismissedSteps = ["add-computer"]
        patch.reminderOptOut = true
        return store.applyOnboardingPatch(
            serverId: "s",
            userId: "u",
            patch: patch,
            now: base.addingTimeInterval(TimeInterval(index))
        )
    }
    // Every reply reports the dismissal stamped by the single first writer.
    #expect(Set(snapshots.compactMap { $0.user.dismissed["add-computer"] }).count == 1)
    let final = store.onboardingSnapshot(serverId: "s", userId: "u")
    #expect(final.user.reminderOptOut)
    #expect(final.agentId?.hasPrefix("agent-") == true)
    #expect(final.user.dismissed["add-computer"] == snapshots.compactMap { $0.user.dismissed["add-computer"] }.first)

    // A member patch never touches the server row but still writes the member row.
    var member = ServersAndChannelsStore.OnboardingPatch(isAdmin: false)
    member.agentId = .clear
    member.greeting = false
    member.currentStep = .set("notifications")
    let afterMember = store.applyOnboardingPatch(serverId: "s", userId: "m", patch: member, now: base)
    #expect(afterMember.agentId == final.agentId && afterMember.greeting == true)
    #expect(afterMember.user.currentStep == "notifications")
    #expect(store.onboardingSnapshot(serverId: "s", userId: "u").agentId == final.agentId)
}

@Test func serviceRefreshClaimsTheCooldownSlotOnce() async throws {
    let ownerId = "11111111-1111-4111-8111-000001170001"
    let serverId = "33333333-3333-4333-8333-000001170001"
    let directory = EmailLoginDirectory()
    directory.addAccount(id: ownerId, email: "rfp-refresh@slock.test", password: "password123")
    directory.markEmailVerified(userId: ownerId)
    directory.oauth.addOwnedServer(id: serverId, slug: "rfp-refresh", name: "rfp", ownerId: ownerId)
    let machineId = directory.registerMachine(serverId: serverId, userId: ownerId, name: "m")
    let token = directory.mintAccessTokenForTesting(userId: ownerId)
    let service = directory.runtimeFormsAndProbes

    let outcomes = await collectConcurrently(10) { _ -> String in
        do {
            _ = try service.refreshMachineRuntimeAccountUsage(
                authorization: "Bearer \(token)",
                serverId: serverId,
                machineId: machineId,
                provider: "claude",
                body: nil
            )
            return "completed"
        } catch let deferral as RuntimeAccountUsageRefreshDeferral {
            return deferral == .requested ? "requested" : "cooldown"
        } catch {
            return "error"
        }
    }
    #expect(outcomes.filter { $0 == "requested" }.count == 1)
    #expect(outcomes.filter { $0 == "cooldown" }.count == 9)
}

@Test func credentialLiveChecksReadMachinesAndComputersTogether() {
    let directory = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001170002"
    directory.oauth.addOwnedServer(
        id: serverId,
        slug: "rfp-cred",
        name: "rfp",
        ownerId: "11111111-1111-4111-8111-000001170002"
    )
    let machineId = directory.registerMachine(
        serverId: serverId,
        userId: "11111111-1111-4111-8111-000001170002",
        name: "m"
    )
    let key = directory.machineAPIKey(machineId: machineId) ?? ""
    let service = directory.runtimeFormsAndProbes
    #expect(service.machineCredentialIsLive(authorization: "Bearer \(key)"))
    #expect(!service.machineCredentialIsLive(authorization: "Bearer"))
    #expect(!service.machineCredentialIsLive(authorization: "Bearer "))
    #expect(!service.machineCredentialIsLive(authorization: nil))
    // A machine key is not a Computer credential.
    #expect(!service.computerCredentialIsLive(authorization: "Bearer \(key)"))
    #expect(service.machineCredential(id: machineId)?.serverId == serverId)
    #expect(service.serverExists(id: serverId))
    #expect(!service.serverExists(id: "missing"))
}
