import Foundation

/// Static runtime-form definitions and bundled option sources. These are the
/// published v2 form bodies and bundled model lists; dynamic probes only
/// replace the option list, never the form itself.
enum RuntimeFormCatalog {
    static let v2Forms: [String: String] = [
        "pi": #"""
{
  "protocolVersion": 2,
  "runtimeId": "pi",
  "schemaVersion": "pi.create.v1",
  "requiredClientCapabilities": [
    "select.custom_value",
    "choice.labels",
    "option_source.status"
  ],
  "dataSchema": {
    "type": "object",
    "additionalProperties": false,
    "required": [
      "provider",
      "model",
      "providerModel"
    ],
    "properties": {
      "provider": {
        "type": "string",
        "title": "Provider",
        "minLength": 1,
        "x-optionSource": "provider"
      },
      "apiKey": {
        "type": "string",
        "title": "API Key",
        "writeOnly": true
      },
      "model": {
        "type": "string",
        "title": "Model",
        "minLength": 1,
        "x-optionSource": "model"
      },
      "reasoningEffort": {
        "type": "string",
        "title": "Reasoning",
        "x-optionsFrom": {
          "field": "model",
          "attribute": "supportedReasoningEfforts",
          "defaultAttribute": "defaultReasoningEffort"
        }
      },
      "providerModel": {
        "type": "string",
        "title": "Model",
        "minLength": 1,
        "x-optionSource": "providerModel"
      },
      "providerReasoningEffort": {
        "type": "string",
        "title": "Reasoning",
        "x-optionsFrom": {
          "field": "providerModel",
          "attribute": "supportedReasoningEfforts",
          "defaultAttribute": "defaultReasoningEffort"
        }
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
      "provider",
      "apiKey",
      "model",
      "reasoningEffort",
      "providerModel",
      "providerReasoningEffort",
      "envVars"
    ],
    "layout": {
      "advanced": [
        "/envVars"
      ]
    },
    "visibility": [
      {
        "pointer": "/apiKey",
        "when": {
          "pointer": "/provider",
          "in": [
            "deepseek"
          ]
        }
      },
      {
        "pointer": "/model",
        "when": {
          "pointer": "/provider",
          "in": [
            "configured"
          ]
        }
      },
      {
        "pointer": "/reasoningEffort",
        "when": {
          "pointer": "/provider",
          "in": [
            "configured"
          ]
        }
      },
      {
        "pointer": "/providerModel",
        "when": {
          "pointer": "/provider",
          "in": [
            "deepseek"
          ]
        }
      },
      {
        "pointer": "/providerReasoningEffort",
        "when": {
          "pointer": "/provider",
          "in": [
            "deepseek"
          ]
        }
      }
    ],
    "localization": {
      "provider": {
        "label": "Provider",
        "hint": "Configured uses your machine's Pi auth.json. Other options inject the matching API key as an env var so the Pi SDK picks it up — no auth.json edit on your machine."
      },
      "apiKey": {
        "label": "API Key",
        "placeholder": "sk-..."
      },
      "model": {
        "label": "Model",
        "hint": "Models available from this computer's Pi configuration. You can also type a model ID."
      },
      "reasoningEffort": {
        "label": "Reasoning",
        "hint": "Available values depend on the selected model.",
        "choices": {
          "low": {
            "label": "Low",
            "description": "Fast responses with lighter reasoning"
          },
          "medium": {
            "label": "Medium",
            "description": "Balances speed and reasoning depth for everyday tasks"
          },
          "high": {
            "label": "High",
            "description": "Greater reasoning depth for complex problems"
          },
          "xhigh": {
            "label": "Extra High",
            "description": "Extra high reasoning depth for complex problems"
          },
          "max": {
            "label": "Max",
            "description": "Maximum reasoning depth for the hardest problems"
          },
          "ultra": {
            "label": "Ultra",
            "description": "Maximum reasoning with automatic task delegation"
          }
        }
      },
      "providerModel": {
        "label": "Model",
        "hint": "Models the selected provider offers."
      },
      "providerReasoningEffort": {
        "label": "Reasoning",
        "hint": "Available values depend on the selected model.",
        "choices": {
          "low": {
            "label": "Low",
            "description": "Fast responses with lighter reasoning"
          },
          "medium": {
            "label": "Medium",
            "description": "Balances speed and reasoning depth for everyday tasks"
          },
          "high": {
            "label": "High",
            "description": "Greater reasoning depth for complex problems"
          },
          "xhigh": {
            "label": "Extra High",
            "description": "Extra high reasoning depth for complex problems"
          },
          "max": {
            "label": "Max",
            "description": "Maximum reasoning depth for the hardest problems"
          },
          "ultra": {
            "label": "Ultra",
            "description": "Maximum reasoning with automatic task delegation"
          }
        }
      },
      "envVars": {
        "label": "Environment Variables",
        "hint": "These will be injected into the runtime command environment."
      }
    }
  },
  "capabilities": {
    "providerKinds": [],
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
      "runtimeId": "pi",
      "schemaVersion": "pi.create.v1",
      "sourceId": "provider",
      "kind": "select",
      "pointer": "/provider"
    },
    "model": {
      "protocolVersion": 1,
      "runtimeId": "pi",
      "schemaVersion": "pi.create.v1",
      "sourceId": "model",
      "kind": "select",
      "pointer": "/model"
    },
    "providerModel": {
      "protocolVersion": 1,
      "runtimeId": "pi",
      "schemaVersion": "pi.create.v1",
      "sourceId": "providerModel",
      "kind": "dependent_select",
      "pointer": "/providerModel",
      "dependsOn": "/provider"
    }
  }
}
"""#,
        "opencode": #"""
{
  "protocolVersion": 2,
  "runtimeId": "opencode",
  "schemaVersion": "opencode.create.v1",
  "dataSchema": {
    "type": "object",
    "additionalProperties": false,
    "required": [
      "model"
    ],
    "properties": {
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
      "model",
      "envVars"
    ],
    "layout": {
      "advanced": [
        "/envVars"
      ]
    },
    "visibility": [],
    "localization": {
      "model": {
        "label": "Model",
        "hint": "Models available from this computer's OpenCode configuration."
      },
      "envVars": {
        "label": "Environment Variables",
        "hint": "These will be injected into the runtime command environment."
      }
    }
  },
  "capabilities": {
    "providerKinds": [],
    "writeOnlyPointers": [],
    "forbiddenPointers": [
      "/hostUserState"
    ]
  },
  "optionSources": {
    "model": {
      "protocolVersion": 1,
      "runtimeId": "opencode",
      "schemaVersion": "opencode.create.v1",
      "sourceId": "model",
      "kind": "select",
      "pointer": "/model"
    }
  }
}
"""#,
        "codex": #"""
{
  "protocolVersion": 2,
  "runtimeId": "codex",
  "schemaVersion": "codex.create.v1",
  "requiredClientCapabilities": [
    "select.custom_value",
    "choice.labels",
    "option_source.status"
  ],
  "dataSchema": {
    "type": "object",
    "additionalProperties": false,
    "required": [
      "model"
    ],
    "properties": {
      "model": {
        "type": "string",
        "title": "Model",
        "minLength": 1,
        "x-optionSource": "model"
      },
      "reasoningEffort": {
        "type": "string",
        "title": "Reasoning",
        "x-optionsFrom": {
          "field": "model",
          "attribute": "supportedReasoningEfforts",
          "defaultAttribute": "defaultReasoningEffort"
        }
      },
      "fastMode": {
        "type": "boolean",
        "title": "Fast mode"
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
      "model",
      "reasoningEffort",
      "fastMode",
      "envVars"
    ],
    "layout": {
      "advanced": [
        "/envVars"
      ]
    },
    "visibility": [],
    "localization": {
      "model": {
        "label": "Model",
        "hint": "Models available from this computer's Codex CLI. You can also type a model ID."
      },
      "reasoningEffort": {
        "label": "Reasoning",
        "hint": "Available values depend on the selected model.",
        "choices": {
          "low": {
            "label": "Low",
            "description": "Fast responses with lighter reasoning"
          },
          "medium": {
            "label": "Medium",
            "description": "Balances speed and reasoning depth for everyday tasks"
          },
          "high": {
            "label": "High",
            "description": "Greater reasoning depth for complex problems"
          },
          "xhigh": {
            "label": "Extra High",
            "description": "Extra high reasoning depth for complex problems"
          },
          "max": {
            "label": "Max",
            "description": "Maximum reasoning depth for the hardest problems"
          },
          "ultra": {
            "label": "Ultra",
            "description": "Maximum reasoning with automatic task delegation"
          }
        }
      },
      "fastMode": {
        "label": "Fast mode",
        "hint": "Launch this runtime with higher speed at a higher cost per token."
      },
      "envVars": {
        "label": "Environment Variables",
        "hint": "These will be injected into the runtime command environment."
      }
    }
  },
  "capabilities": {
    "providerKinds": [],
    "writeOnlyPointers": [],
    "forbiddenPointers": [
      "/hostUserState"
    ]
  },
  "optionSources": {
    "model": {
      "protocolVersion": 1,
      "runtimeId": "codex",
      "schemaVersion": "codex.create.v1",
      "sourceId": "model",
      "kind": "select",
      "pointer": "/model"
    }
  }
}
"""#,
        "grok": #"""
{
  "protocolVersion": 2,
  "runtimeId": "grok",
  "schemaVersion": "grok.create.v1",
  "requiredClientCapabilities": [
    "choice.labels",
    "option_source.status"
  ],
  "dataSchema": {
    "type": "object",
    "additionalProperties": false,
    "required": [
      "model"
    ],
    "properties": {
      "model": {
        "type": "string",
        "title": "Model",
        "minLength": 1,
        "x-optionSource": "model"
      },
      "reasoningEffort": {
        "type": "string",
        "title": "Reasoning",
        "x-optionsFrom": {
          "field": "model",
          "attribute": "supportedReasoningEfforts",
          "defaultAttribute": "defaultReasoningEffort"
        }
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
      "model",
      "reasoningEffort",
      "envVars"
    ],
    "layout": {
      "advanced": [
        "/envVars"
      ]
    },
    "visibility": [],
    "localization": {
      "model": {
        "label": "Model",
        "hint": "Models available from this computer's Grok CLI."
      },
      "reasoningEffort": {
        "label": "Reasoning",
        "hint": "Available values depend on the selected model.",
        "choices": {
          "low": {
            "label": "Low",
            "description": "Fast responses with lighter reasoning"
          },
          "medium": {
            "label": "Medium",
            "description": "Balances speed and reasoning depth for everyday tasks"
          },
          "high": {
            "label": "High",
            "description": "Greater reasoning depth for complex problems"
          },
          "xhigh": {
            "label": "Extra High",
            "description": "Extra high reasoning depth for complex problems"
          },
          "max": {
            "label": "Max",
            "description": "Maximum reasoning depth for the hardest problems"
          },
          "ultra": {
            "label": "Ultra",
            "description": "Maximum reasoning with automatic task delegation"
          }
        }
      },
      "envVars": {
        "label": "Environment Variables",
        "hint": "These will be injected into the runtime command environment."
      }
    }
  },
  "capabilities": {
    "providerKinds": [],
    "writeOnlyPointers": [],
    "forbiddenPointers": [
      "/hostUserState"
    ]
  },
  "optionSources": {
    "model": {
      "protocolVersion": 1,
      "runtimeId": "grok",
      "schemaVersion": "grok.create.v1",
      "sourceId": "model",
      "kind": "select",
      "pointer": "/model"
    }
  }
}
"""#,
        "claude": #"""
{
  "protocolVersion": 2,
  "runtimeId": "claude",
  "schemaVersion": "claude.create.v1",
  "requiredClientCapabilities": [
    "select.custom_value",
    "choice.labels",
    "option_source.status"
  ],
  "dataSchema": {
    "type": "object",
    "additionalProperties": false,
    "required": [
      "provider",
      "model"
    ],
    "properties": {
      "provider": {
        "type": "string",
        "title": "Provider",
        "minLength": 1,
        "x-optionSource": "provider"
      },
      "apiUrl": {
        "type": "string",
        "title": "API URL",
        "format": "uri"
      },
      "apiKey": {
        "type": "string",
        "title": "API Key",
        "writeOnly": true
      },
      "model": {
        "type": "string",
        "title": "Model",
        "minLength": 1,
        "x-optionSource": "model"
      },
      "reasoningEffort": {
        "type": "string",
        "title": "Reasoning",
        "x-optionsFrom": {
          "field": "model",
          "attribute": "supportedReasoningEfforts",
          "defaultAttribute": "defaultReasoningEffort"
        }
      },
      "fastMode": {
        "type": "boolean",
        "title": "Fast mode"
      },
      "command": {
        "type": "string",
        "title": "Claude Command"
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
      "provider",
      "apiUrl",
      "apiKey",
      "model",
      "reasoningEffort",
      "fastMode",
      "command",
      "envVars"
    ],
    "layout": {
      "advanced": [
        "/command",
        "/envVars"
      ]
    },
    "visibility": [
      {
        "pointer": "/apiUrl",
        "when": {
          "pointer": "/provider",
          "in": [
            "custom"
          ]
        }
      },
      {
        "pointer": "/apiKey",
        "when": {
          "pointer": "/provider",
          "in": [
            "custom"
          ]
        }
      }
    ],
    "localization": {
      "provider": {
        "label": "Provider",
        "hint": "Default leaves Claude Code provider settings untouched. Custom sets ANTHROPIC_BASE_URL and ANTHROPIC_API_KEY for this agent."
      },
      "apiUrl": {
        "label": "API URL",
        "placeholder": "https://gateway.example.com"
      },
      "apiKey": {
        "label": "API Key",
        "placeholder": "sk-ant-..."
      },
      "model": {
        "label": "Model",
        "hint": "Models Claude Code accepts. You can also type a model ID."
      },
      "reasoningEffort": {
        "label": "Reasoning",
        "hint": "Available values depend on the selected model.",
        "choices": {
          "low": {
            "label": "Low",
            "description": "Fast responses with lighter reasoning"
          },
          "medium": {
            "label": "Medium",
            "description": "Balances speed and reasoning depth for everyday tasks"
          },
          "high": {
            "label": "High",
            "description": "Greater reasoning depth for complex problems"
          },
          "xhigh": {
            "label": "Extra High",
            "description": "Extra high reasoning depth for complex problems"
          },
          "max": {
            "label": "Max",
            "description": "Maximum reasoning depth for the hardest problems"
          },
          "ultra": {
            "label": "Ultra",
            "description": "Maximum reasoning with automatic task delegation"
          }
        }
      },
      "fastMode": {
        "label": "Fast mode",
        "hint": "Launch this runtime with higher speed at a higher cost per token."
      },
      "command": {
        "label": "Claude Command",
        "hint": "Executable path or command name; Slock adds the Claude stream-json runtime arguments.",
        "placeholder": "claude"
      },
      "envVars": {
        "label": "Environment Variables",
        "hint": "These will be injected into the runtime command environment."
      }
    }
  },
  "capabilities": {
    "providerKinds": [],
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
      "runtimeId": "claude",
      "schemaVersion": "claude.create.v1",
      "sourceId": "provider",
      "kind": "select",
      "pointer": "/provider"
    },
    "model": {
      "protocolVersion": 1,
      "runtimeId": "claude",
      "schemaVersion": "claude.create.v1",
      "sourceId": "model",
      "kind": "select",
      "pointer": "/model"
    }
  }
}
"""#,
        "cursor": #"""
{
  "protocolVersion": 2,
  "runtimeId": "cursor",
  "schemaVersion": "cursor.create.v1",
  "requiredClientCapabilities": [
    "select.custom_value",
    "option_source.status"
  ],
  "dataSchema": {
    "type": "object",
    "additionalProperties": false,
    "required": [
      "model"
    ],
    "properties": {
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
      "model",
      "envVars"
    ],
    "layout": {
      "advanced": [
        "/envVars"
      ]
    },
    "visibility": [],
    "localization": {
      "model": {
        "label": "Model",
        "hint": "Models available from this computer's Cursor CLI. You can also type a model ID."
      },
      "envVars": {
        "label": "Environment Variables",
        "hint": "These will be injected into the runtime command environment."
      }
    }
  },
  "capabilities": {
    "providerKinds": [],
    "writeOnlyPointers": [],
    "forbiddenPointers": [
      "/hostUserState"
    ]
  },
  "optionSources": {
    "model": {
      "protocolVersion": 1,
      "runtimeId": "cursor",
      "schemaVersion": "cursor.create.v1",
      "sourceId": "model",
      "kind": "select",
      "pointer": "/model"
    }
  }
}
"""#,
        "kimi-sdk": #"""
{
  "protocolVersion": 2,
  "runtimeId": "kimi-sdk",
  "schemaVersion": "kimi-sdk.create.v1",
  "dataSchema": {
    "type": "object",
    "additionalProperties": false,
    "required": [
      "model"
    ],
    "properties": {
      "model": {
        "type": "string",
        "title": "Model",
        "minLength": 1,
        "x-optionSource": "model"
      },
      "reasoningEffort": {
        "type": "string",
        "title": "Thinking effort",
        "minLength": 1,
        "x-optionsFrom": {
          "field": "model",
          "attribute": "supportedReasoningEfforts",
          "defaultAttribute": "defaultReasoningEffort"
        }
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
      "model",
      "reasoningEffort",
      "envVars"
    ],
    "layout": {
      "advanced": [
        "/envVars"
      ]
    },
    "visibility": [],
    "localization": {
      "model": {
        "label": "Model",
        "hint": "Models available from this computer's Kimi configuration."
      },
      "reasoningEffort": {
        "label": "Thinking effort",
        "hint": "Available values are declared by the selected model."
      },
      "envVars": {
        "label": "Environment Variables",
        "hint": "These will be injected into the runtime command environment."
      }
    }
  },
  "capabilities": {
    "providerKinds": [],
    "writeOnlyPointers": [],
    "forbiddenPointers": [
      "/hostUserState"
    ]
  },
  "optionSources": {
    "model": {
      "protocolVersion": 1,
      "runtimeId": "kimi-sdk",
      "schemaVersion": "kimi-sdk.create.v1",
      "sourceId": "model",
      "kind": "select",
      "pointer": "/model"
    }
  },
  "requiredClientCapabilities": [
    "option_source.status"
  ]
}
"""#,
    ]

    static let optionSources: [String: String] = [
        "pi/provider": #"""
{
  "protocolVersion": 1,
  "runtimeId": "pi",
  "schemaVersion": "pi.create.v1",
  "sourceId": "provider",
  "kind": "select",
  "pointer": "/provider",
  "options": [
    {
      "value": "configured",
      "label": "Configured"
    },
    {
      "value": "deepseek",
      "label": "DeepSeek"
    }
  ],
  "defaultValue": "configured",
  "customValueAllowed": false
}
"""#,
        "pi/providerModel": #"""
{
  "protocolVersion": 1,
  "runtimeId": "pi",
  "schemaVersion": "pi.create.v1",
  "sourceId": "providerModel",
  "kind": "dependent_select",
  "pointer": "/providerModel",
  "dependsOn": "/provider",
  "optionsByValue": {
    "deepseek": [
      {
        "value": "deepseek/deepseek-v4-pro",
        "label": "DeepSeek V4 Pro",
        "supportedReasoningEfforts": [
          "low",
          "medium",
          "high",
          "xhigh"
        ]
      },
      {
        "value": "deepseek/deepseek-flash",
        "label": "DeepSeek V4.1 Flash",
        "supportedReasoningEfforts": [
          "low",
          "medium",
          "high",
          "xhigh"
        ]
      }
    ]
  },
  "defaultValueByValue": {
    "deepseek": "deepseek/deepseek-v4-pro"
  },
  "customValueAllowedByValue": {
    "deepseek": false
  }
}
"""#,
        "pi/model": #"""
{
  "protocolVersion": 1,
  "runtimeId": "pi",
  "schemaVersion": "pi.create.v1",
  "sourceId": "model",
  "kind": "select",
  "pointer": "/model",
  "options": [
    {
      "value": "default",
      "label": "Configured Default / Auto",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh"
      ]
    }
  ],
  "defaultValue": "default",
  "customValueAllowed": true,
  "status": "fallback",
  "reason": "missing_config",
  "retryable": false
}
"""#,
        "kimi/model": #"""
{
  "protocolVersion": 1,
  "runtimeId": "kimi",
  "schemaVersion": "kimi.edit.v1",
  "sourceId": "model",
  "kind": "select",
  "pointer": "/model",
  "options": [
    {
      "value": "default",
      "label": "Configured Default"
    }
  ],
  "defaultValue": "default"
}
"""#,
        "gemini/model": #"""
{
  "protocolVersion": 1,
  "runtimeId": "gemini",
  "schemaVersion": "gemini.edit.v1",
  "sourceId": "model",
  "kind": "select",
  "pointer": "/model",
  "options": [
    {
      "value": "default",
      "label": "Configured Default / Auto"
    },
    {
      "value": "gemini-3.1-pro-preview",
      "label": "Gemini 3.1 Pro (Preview)"
    },
    {
      "value": "gemini-3-flash-preview",
      "label": "Gemini 3 Flash (Preview)"
    },
    {
      "value": "gemini-2.5-pro",
      "label": "Gemini 2.5 Pro"
    },
    {
      "value": "gemini-2.5-flash",
      "label": "Gemini 2.5 Flash"
    }
  ],
  "defaultValue": "default"
}
"""#,
        "opencode/model": #"""
{
  "protocolVersion": 1,
  "runtimeId": "opencode",
  "schemaVersion": "opencode.create.v1",
  "sourceId": "model",
  "kind": "select",
  "pointer": "/model",
  "options": [
    {
      "value": "default",
      "label": "Configured Default / Auto"
    },
    {
      "value": "deepseek/deepseek-v4-pro",
      "label": "DeepSeek V4 Pro · DeepSeek"
    },
    {
      "value": "openrouter/anthropic/claude-opus-4.5",
      "label": "Claude Opus 4.5 · Anthropic via OpenRouter"
    },
    {
      "value": "fusecode/opus[1m]",
      "label": "Opus 1M · FuseCode"
    }
  ],
  "defaultValue": "default"
}
"""#,
        "codex/model": #"""
{
  "protocolVersion": 1,
  "runtimeId": "codex",
  "schemaVersion": "codex.create.v1",
  "sourceId": "model",
  "kind": "select",
  "pointer": "/model",
  "options": [
    {
      "value": "gpt-6.1-sol",
      "label": "GPT-6.1 Sol",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max",
        "ultra"
      ],
      "defaultReasoningEffort": "low"
    },
    {
      "value": "gpt-6-astra",
      "label": "GPT-6-Astra",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max",
        "ultra"
      ],
      "defaultReasoningEffort": "low"
    },
    {
      "value": "gpt-6-sol",
      "label": "GPT-6 Sol",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max",
        "ultra"
      ],
      "defaultReasoningEffort": "medium"
    },
    {
      "value": "gpt-6-luna",
      "label": "GPT-6 Luna",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ],
      "defaultReasoningEffort": "medium"
    },
    {
      "value": "gpt-5.6-sol",
      "label": "GPT-5.6 Sol",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max",
        "ultra"
      ],
      "defaultReasoningEffort": "medium"
    },
    {
      "value": "gpt-5.6-terra",
      "label": "GPT-5.6 Terra",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max",
        "ultra"
      ],
      "defaultReasoningEffort": "medium"
    },
    {
      "value": "gpt-5.6-luna",
      "label": "GPT-5.6 Luna",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ],
      "defaultReasoningEffort": "medium"
    },
    {
      "value": "gpt-5.5",
      "label": "GPT-5.5",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh"
      ]
    },
    {
      "value": "gpt-5.4",
      "label": "GPT-5.4",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh"
      ]
    },
    {
      "value": "gpt-5.3-codex",
      "label": "GPT-5.3 Codex",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh"
      ]
    },
    {
      "value": "gpt-5.3-codex-spark",
      "label": "GPT-5.3 Codex Spark",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh"
      ]
    },
    {
      "value": "gpt-5.2-codex",
      "label": "GPT-5.2 Codex",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh"
      ]
    },
    {
      "value": "gpt-5.2",
      "label": "GPT-5.2",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh"
      ]
    },
    {
      "value": "gpt-5.1-codex-max",
      "label": "GPT-5.1 Codex Max",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh"
      ]
    },
    {
      "value": "gpt-5.1-codex",
      "label": "GPT-5.1 Codex",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh"
      ]
    },
    {
      "value": "gpt-5-codex",
      "label": "GPT-5 Codex",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh"
      ]
    },
    {
      "value": "gpt-5",
      "label": "GPT-5",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh"
      ]
    }
  ],
  "defaultValue": "gpt-6.1-sol",
  "customValueAllowed": true,
  "status": "fallback",
  "reason": "missing_config",
  "retryable": false
}
"""#,
        "claude/provider": #"""
{
  "protocolVersion": 1,
  "runtimeId": "claude",
  "schemaVersion": "claude.create.v1",
  "sourceId": "provider",
  "kind": "select",
  "pointer": "/provider",
  "options": [
    {
      "value": "default",
      "label": "Default"
    },
    {
      "value": "custom",
      "label": "Custom"
    }
  ],
  "defaultValue": "default",
  "customValueAllowed": false
}
"""#,
        "claude/model": #"""
{
  "protocolVersion": 1,
  "runtimeId": "claude",
  "schemaVersion": "claude.create.v1",
  "sourceId": "model",
  "kind": "select",
  "pointer": "/model",
  "options": [
    {
      "value": "opus",
      "label": "Claude Opus",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ]
    },
    {
      "value": "fable",
      "label": "Claude Fable",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ]
    },
    {
      "value": "sonnet",
      "label": "Claude Sonnet",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ]
    },
    {
      "value": "haiku",
      "label": "Claude Haiku",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh"
      ]
    },
    {
      "value": "claude-opus-5-5",
      "label": "Claude Opus 5.5",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ]
    },
    {
      "value": "claude-opus-5",
      "label": "Claude Opus 5",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ]
    },
    {
      "value": "claude-opus-4-8",
      "label": "Claude Opus 4.8",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ]
    },
    {
      "value": "claude-opus-4-7",
      "label": "Claude Opus 4.7",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ]
    },
    {
      "value": "claude-opus-4-6",
      "label": "Claude Opus 4.6",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ]
    },
    {
      "value": "claude-fable-5-1",
      "label": "Claude Fable 5.1",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ]
    },
    {
      "value": "claude-fable-5",
      "label": "Claude Fable 5",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ]
    },
    {
      "value": "claude-sonnet-5-5",
      "label": "Claude Sonnet 5.5",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ]
    },
    {
      "value": "claude-sonnet-5",
      "label": "Claude Sonnet 5",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ]
    },
    {
      "value": "claude-sonnet-4-6",
      "label": "Claude Sonnet 4.6",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ]
    },
    {
      "value": "claude-haiku-5-5",
      "label": "Claude Haiku 5.5",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
      ]
    },
    {
      "value": "claude-haiku-4-5",
      "label": "Claude Haiku 4.5",
      "supportedReasoningEfforts": [
        "low",
        "medium",
        "high",
        "xhigh"
      ]
    }
  ],
  "defaultValue": "opus",
  "customValueAllowed": true,
  "status": "fallback",
  "reason": "machine_offline",
  "retryable": true
}
"""#,
        "cursor/model": #"""
{
  "protocolVersion": 1,
  "runtimeId": "cursor",
  "schemaVersion": "cursor.create.v1",
  "sourceId": "model",
  "kind": "select",
  "pointer": "/model",
  "options": [
    {
      "value": "composer-2-fast",
      "label": "Composer 2 Fast"
    },
    {
      "value": "composer-2",
      "label": "Composer 2"
    },
    {
      "value": "auto",
      "label": "Auto"
    }
  ],
  "defaultValue": "composer-2-fast",
  "customValueAllowed": true,
  "status": "fallback",
  "reason": "missing_config",
  "retryable": false
}
"""#,
        "kimi-sdk/edit": #"""
{
  "protocolVersion": 2,
  "runtimeId": "kimi-sdk",
  "schemaVersion": "kimi-sdk.create.v1",
  "dataSchema": {
    "type": "object",
    "additionalProperties": false,
    "required": [
      "model"
    ],
    "properties": {
      "model": {
        "type": "string",
        "title": "Model",
        "minLength": 1,
        "x-optionSource": "model"
      },
      "reasoningEffort": {
        "type": "string",
        "title": "Thinking effort",
        "minLength": 1,
        "x-optionsFrom": {
          "field": "model",
          "attribute": "supportedReasoningEfforts",
          "defaultAttribute": "defaultReasoningEffort"
        }
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
      "model",
      "reasoningEffort",
      "envVars"
    ],
    "layout": {
      "advanced": [
        "/envVars"
      ]
    },
    "visibility": [],
    "localization": {
      "model": {
        "label": "Model",
        "hint": "Models available from this computer's Kimi configuration."
      },
      "reasoningEffort": {
        "label": "Thinking effort",
        "hint": "Available values are declared by the selected model."
      },
      "envVars": {
        "label": "Environment Variables",
        "hint": "These will be injected into the runtime command environment."
      }
    }
  },
  "capabilities": {
    "providerKinds": [],
    "writeOnlyPointers": [],
    "forbiddenPointers": [
      "/hostUserState"
    ]
  },
  "optionSources": {
    "model": {
      "protocolVersion": 1,
      "runtimeId": "kimi-sdk",
      "schemaVersion": "kimi-sdk.create.v1",
      "sourceId": "model",
      "kind": "select",
      "pointer": "/model"
    }
  },
  "requiredClientCapabilities": [
    "option_source.status"
  ],
  "values": {
    "model": "kimi-k2",
    "reasoningEffort": "high",
    "envVars": {}
  }
}
"""#,
    ]
}
