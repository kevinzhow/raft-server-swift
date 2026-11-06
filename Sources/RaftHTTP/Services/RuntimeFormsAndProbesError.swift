import Foundation

/// Domain failure for the runtime-form, runtime-probe, runtime account usage,
/// onboarding/notification settings and machine registration routes.
///
/// Every case is one published refusal; `Respond.swift` renders the body from
/// `errorMessage`, or from `errorBody` where the published object has other
/// members (`issues`, the builtin catalog recovery fields) or none of the
/// default ones.
public enum RuntimeFormsAndProbesError: DomainError, Equatable {
    case unauthorized
    case serverNotFound
    /// `403 Forbidden`.
    case forbidden
    /// `403 Not a member of this server`.
    case notAMember
    case agentNotFound
    case editAgentsRequired
    case noRuntimeForm
    case computerNotFound
    /// `404 Machine not found in this server`.
    case machineNotFound
    /// The machine-creator authority text; `purpose` completes the sentence.
    case editMachinesRequired(purpose: String)
    /// The attaching-human authority text of the runtime account usage routes.
    case attachingHumanRequired(purpose: String)
    case runtimeFormNotFound
    case runtimeFormOptionSourceNotFound
    case unknownOptionSource
    case staleFormSchema
    case usageProviderNotFound
    case registerMachinesRequired
    case nameRequired
    case invalidOnboardingSettings
    case onboardingAdminOnly
    case greetingNotBoolean
    case invalidOnboardingStep
    case invalidNotificationSettings
    case pushMutedNotBoolean
    case invalidPushMode
    case workspacesForbidden
    case builtinCatalogCapabilityRequired
    case builtinCatalogUnavailable
    /// The kimi-sdk model source refused with its `runtime_model_source_*` issue.
    case kimiSDKSource(code: String)

    public var status: UInt {
        switch self {
        case .unauthorized:
            401
        case .forbidden, .notAMember, .editAgentsRequired, .editMachinesRequired,
             .attachingHumanRequired, .registerMachinesRequired, .onboardingAdminOnly,
             .workspacesForbidden:
            403
        case .serverNotFound, .agentNotFound, .noRuntimeForm, .computerNotFound,
             .machineNotFound, .runtimeFormNotFound, .runtimeFormOptionSourceNotFound,
             .unknownOptionSource, .usageProviderNotFound:
            404
        case .nameRequired, .invalidOnboardingSettings, .greetingNotBoolean,
             .invalidOnboardingStep, .invalidNotificationSettings, .pushMutedNotBoolean,
             .invalidPushMode:
            400
        case .staleFormSchema, .builtinCatalogCapabilityRequired, .builtinCatalogUnavailable,
             .kimiSDKSource:
            409
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized:
            "Unauthorized"
        case .serverNotFound:
            "Server not found"
        case .forbidden:
            "Forbidden"
        case .notAMember:
            "Not a member of this server"
        case .agentNotFound:
            "Agent not found"
        case .editAgentsRequired:
            "The `editAgents` capability or human creator authority is required to edit agents"
        case .noRuntimeForm:
            "This agent's runtime configuration has no editable runtime form"
        case .computerNotFound:
            "Computer not found"
        case .machineNotFound:
            "Machine not found in this server"
        case .editMachinesRequired(let purpose):
            "The `editMachines` capability or machine creator authority is required to \(purpose)"
        case .attachingHumanRequired(let purpose):
            "The `editMachines` capability or attaching-human authority is required to \(purpose)"
        case .runtimeFormNotFound:
            "Runtime form not found"
        case .runtimeFormOptionSourceNotFound, .unknownOptionSource:
            "Runtime form option source not found"
        case .staleFormSchema:
            "Runtime form schema is stale or unknown"
        case .usageProviderNotFound:
            "Runtime account usage provider not found"
        case .registerMachinesRequired:
            "The `registerMachines` capability is required to register machines"
        case .nameRequired:
            "Name is required"
        case .invalidOnboardingSettings:
            "Invalid onboarding settings"
        case .onboardingAdminOnly:
            "Only server owners and admins can update onboarding settings"
        case .greetingNotBoolean:
            "agentAllChannelGreetingEnabled must be a boolean"
        case .invalidOnboardingStep:
            "Invalid onboarding step"
        case .invalidNotificationSettings:
            "Invalid notification settings"
        case .pushMutedNotBoolean:
            "serverPushMuted must be a boolean"
        case .invalidPushMode:
            "serverPushMode must be one of all, mentions, none"
        case .workspacesForbidden:
            "You do not have permission to view machine workspaces"
        case .builtinCatalogCapabilityRequired:
            "This Computer is too old to prove which Built-in models it supports. Upgrade the Computer before selecting or starting this model."
        case .builtinCatalogUnavailable, .kimiSDKSource:
            "Runtime model source is unavailable"
        }
    }

    /// The bodies that are not the plain `{"error": …}` object.
    public var errorBody: OrderedJSON? {
        switch self {
        case .noRuntimeForm:
            Self.issueBody(error: errorMessage, code: "no_runtime_form", pointer: "/runtimeConfig")
        case .runtimeFormNotFound:
            Self.issueBody(error: errorMessage, code: "unknown_form_runtime", pointer: "/runtimeId")
        case .runtimeFormOptionSourceNotFound:
            Self.issueBody(error: errorMessage, code: "unknown_form_runtime", pointer: "/runtimeId")
        case .unknownOptionSource:
            Self.issueBody(error: errorMessage, code: "unknown_option_source", pointer: "/sourceId")
        case .staleFormSchema:
            Self.issueBody(error: errorMessage, code: "stale_form_schema", pointer: "/schemaVersion")
        case .builtinCatalogCapabilityRequired:
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "builtin_catalog_capability_required"),
                OrderedJSONField("daemonVersion", "1.0.17"),
                OrderedJSONField("computerVersion", "1.0.17"),
                OrderedJSONField("recovery", "upgrade_required"),
            ])
        case .builtinCatalogUnavailable:
            Self.issuesOnlyBody(code: "builtin_catalog_unavailable")
        case .kimiSDKSource(let code):
            Self.issuesOnlyBody(code: code)
        case .unauthorized, .serverNotFound, .forbidden, .notAMember, .agentNotFound,
             .editAgentsRequired, .computerNotFound, .machineNotFound, .editMachinesRequired,
             .attachingHumanRequired, .usageProviderNotFound, .registerMachinesRequired,
             .nameRequired, .invalidOnboardingSettings, .onboardingAdminOnly,
             .greetingNotBoolean, .invalidOnboardingStep, .invalidNotificationSettings,
             .pushMutedNotBoolean, .invalidPushMode, .workspacesForbidden:
            nil
        }
    }

    private static func issueBody(error: String, code: String, pointer: String) -> OrderedJSON {
        .object([
            OrderedJSONField("error", error),
            OrderedJSONField("issues", OrderedJSON.array([
                .object([OrderedJSONField("code", code), OrderedJSONField("pointer", pointer)]),
            ])),
        ])
    }

    private static func issuesOnlyBody(code: String) -> OrderedJSON {
        .object([
            OrderedJSONField("issues", OrderedJSON.array([
                .object([
                    OrderedJSONField("code", code),
                    OrderedJSONField("pointer", "/optionSources/model"),
                ]),
            ])),
        ])
    }
}

/// The answers of a usage refresh that did not complete synchronously. All of
/// them publish `202` with `accepted` and `state`; the completed answers are
/// the `RuntimeAccountUsageRefreshResponse` (`200`).
public enum RuntimeAccountUsageRefreshDeferral: DomainError, Equatable {
    /// The refresh ran less than a minute ago.
    case cooldown
    /// A background refresh was requested.
    case requested
    /// A manual refresh found the Computer offline.
    case computerOffline

    public var status: UInt { 202 }

    public var errorMessage: String {
        switch self {
        case .cooldown:
            "Runtime account usage refresh is cooling down"
        case .requested:
            "Runtime account usage refresh requested"
        case .computerOffline:
            "Computer is offline"
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .cooldown:
            .object([OrderedJSONField("accepted", false), OrderedJSONField("state", "cooldown")])
        case .requested:
            .object([OrderedJSONField("accepted", true), OrderedJSONField("state", "requested")])
        case .computerOffline:
            .object([OrderedJSONField("accepted", false), OrderedJSONField("state", "computer_offline")])
        }
    }
}
