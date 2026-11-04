import Foundation
import Testing
import RaftDaemonClient

@Test func liveTruthAndLegacyCatalogRideTogether() {
    let message = RuntimeModelSourceProjection.build(
        requestId: "req-live",
        detectedOutcome: .live(.init(models: [.init(id: "live-model", label: "Live model")], defaultModel: "live-model")),
        verifiedAs: "launchable"
    )
    #expect(message.outcome == .live(.init(
        models: [.init(id: "live-model", label: "Live model", verified: "launchable")],
        defaultModel: "live-model"
    )))
    #expect(message.models == [.init(id: "live-model", label: "Live model", verified: "launchable")])
    #expect(message.defaultModel == "live-model")
    #expect(message.error == nil)
}

@Test func additiveBuiltInCatalogProvenanceIsPreserved() {
    let catalog = RuntimeModelCatalog(protocolVersion: 1, runtime: "builtin", runtimeVersion: "0.84.3")
    let message = RuntimeModelSourceProjection.build(
        requestId: "req-catalog",
        detectedOutcome: .live(.init(models: [.init(id: "live-model", label: "Live model")], catalog: catalog)),
        verifiedAs: "launchable"
    )
    #expect(message.outcome == .live(.init(
        models: [.init(id: "live-model", label: "Live model", verified: "launchable")],
        defaultModel: nil, catalog: catalog
    )))
    #expect(message.models == [.init(id: "live-model", label: "Live model", verified: "launchable")])
}

@Test func everyNonLiveOutcomeStaysTypedAndLegacySafe() {
    let cases: [(RuntimeModelSourceOutcome, [String: Any])] = [
        (.missingConfig(recovery: "kimi_login"), ["error": "missing_config"]),
        (.noModels, ["models": []]),
        (.unsupported, ["error": "unsupported"]),
        (.error(retryable: true, code: nil, reason: nil), ["error": "error"]),
        (.error(retryable: true, code: "runtime_not_authenticated", reason: nil), ["error": "error"]),
    ]
    for (outcome, legacy) in cases {
        let message = RuntimeModelSourceProjection.build(requestId: "req-non-live", detectedOutcome: outcome, verifiedAs: "launchable")
        #expect(message.outcome == outcome)
        let json = message.jsonObject()
        if legacy.keys.contains("models") {
            #expect((json["models"] as? [Any])?.count == 0)
        } else {
            #expect(json["error"] as? String == legacy["error"] as? String)
        }
    }
}

@Test func emptyLiveCatalogNormalizesToNoModels() {
    let message = RuntimeModelSourceProjection.build(
        requestId: "req-empty",
        detectedOutcome: .live(.init(models: [])),
        verifiedAs: "launchable"
    )
    #expect(message.outcome == .noModels)
    #expect(message.models?.isEmpty == true)
}

@Test func serializedFrameKeepsLookupVerdictBesideLegacyError() throws {
    let message = RuntimeModelSourceProjection.build(
        requestId: "req-nf",
        detectedOutcome: .error(retryable: true, code: "runtime_not_found", reason: "probe_timeout"),
        verifiedAs: "launchable"
    )
    let data = try JSONSerialization.data(withJSONObject: message.jsonObject())
    let wire = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let outcome = try #require(wire["outcome"] as? [String: Any])
    #expect(outcome["kind"] as? String == "error")
    #expect(outcome["retryable"] as? Bool == true)
    #expect(outcome["code"] as? String == "runtime_not_found")
    #expect(outcome["reason"] as? String == "probe_timeout")
    #expect(wire["error"] as? String == "error")
}
