import Foundation

/// The additive `machine:runtime_models:result` carrier: typed truth for new
/// servers plus the legacy models/default/error fields a mixed-version rollout
/// still reads. Ported from the upstream daemon projection.
public struct RuntimeModelEntry: Sendable, Equatable {
    public var id: String
    public var label: String
    public var verified: String?
    public init(id: String, label: String, verified: String? = nil) {
        self.id = id
        self.label = label
        self.verified = verified
    }
}

public struct RuntimeModelCatalog: Sendable, Equatable {
    public var protocolVersion: Int
    public var runtime: String
    public var runtimeVersion: String?
    public init(protocolVersion: Int, runtime: String, runtimeVersion: String? = nil) {
        self.protocolVersion = protocolVersion
        self.runtime = runtime
        self.runtimeVersion = runtimeVersion
    }
}

public struct RuntimeModelLiveValue: Sendable, Equatable {
    public var models: [RuntimeModelEntry]
    public var defaultModel: String?
    public var catalog: RuntimeModelCatalog?
    public init(models: [RuntimeModelEntry], defaultModel: String? = nil, catalog: RuntimeModelCatalog? = nil) {
        self.models = models
        self.defaultModel = defaultModel
        self.catalog = catalog
    }
}

public enum RuntimeModelSourceOutcome: Sendable, Equatable {
    case live(RuntimeModelLiveValue)
    case missingConfig(recovery: String?)
    case noModels
    case unsupported
    case error(retryable: Bool, code: String?, reason: String?)
}

public struct RuntimeModelSourceResultMessage: Sendable, Equatable {
    public var type = "machine:runtime_models:result"
    public var requestId: String
    public var outcome: RuntimeModelSourceOutcome
    public var models: [RuntimeModelEntry]?
    public var defaultModel: String?
    public var error: String?

    /// Wire projection with the legacy fields populated.
    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["type": type, "requestId": requestId]
        object["outcome"] = RuntimeModelSourceProjection.outcomeJSON(outcome)
        if let models { object["models"] = RuntimeModelSourceProjection.modelsJSON(models) }
        if let defaultModel { object["default"] = defaultModel }
        if let error { object["error"] = error }
        return object
    }
}

public enum RuntimeModelSourceProjection {
    public static func build(
        requestId: String,
        detectedOutcome: RuntimeModelSourceOutcome,
        verifiedAs: String
    ) -> RuntimeModelSourceResultMessage {
        var outcome = detectedOutcome
        if case .live(let value) = detectedOutcome, value.models.isEmpty {
            outcome = .noModels
        }
        switch outcome {
        case .live(let value):
            let models = value.models.map { model -> RuntimeModelEntry in
                RuntimeModelEntry(id: model.id, label: model.label, verified: model.verified ?? verifiedAs)
            }
            let live = RuntimeModelLiveValue(models: models, defaultModel: value.defaultModel, catalog: value.catalog)
            return RuntimeModelSourceResultMessage(
                requestId: requestId, outcome: .live(live), models: models,
                defaultModel: value.defaultModel, error: nil
            )
        case .noModels:
            return RuntimeModelSourceResultMessage(requestId: requestId, outcome: .noModels, models: [], defaultModel: nil, error: nil)
        case .missingConfig:
            return RuntimeModelSourceResultMessage(requestId: requestId, outcome: outcome, models: nil, defaultModel: nil, error: "missing_config")
        case .unsupported:
            return RuntimeModelSourceResultMessage(requestId: requestId, outcome: outcome, models: nil, defaultModel: nil, error: "unsupported")
        case .error:
            return RuntimeModelSourceResultMessage(requestId: requestId, outcome: outcome, models: nil, defaultModel: nil, error: "error")
        }
    }

    static func modelsJSON(_ models: [RuntimeModelEntry]) -> [[String: Any]] {
        models.map { model in
            var object: [String: Any] = ["id": model.id, "label": model.label]
            if let verified = model.verified, !verified.isEmpty { object["verified"] = verified }
            return object
        }
    }

    static func catalogJSON(_ catalog: RuntimeModelCatalog) -> [String: Any] {
        var object: [String: Any] = ["protocolVersion": catalog.protocolVersion, "runtime": catalog.runtime]
        if let version = catalog.runtimeVersion { object["runtimeVersion"] = version }
        return object
    }

    public static func outcomeJSON(_ outcome: RuntimeModelSourceOutcome) -> [String: Any] {
        switch outcome {
        case .live(let value):
            var payload: [String: Any] = ["models": modelsJSON(value.models)]
            if let defaultModel = value.defaultModel { payload["default"] = defaultModel }
            if let catalog = value.catalog { payload["catalog"] = catalogJSON(catalog) }
            return ["kind": "live", "value": payload]
        case .missingConfig(let recovery):
            var object: [String: Any] = ["kind": "missing_config"]
            if let recovery { object["recovery"] = recovery }
            return object
        case .noModels:
            return ["kind": "no_models"]
        case .unsupported:
            return ["kind": "unsupported"]
        case .error(let retryable, let code, let reason):
            var object: [String: Any] = ["kind": "error", "retryable": retryable]
            if let code { object["code"] = code }
            if let reason { object["reason"] = reason }
            return object
        }
    }
}
