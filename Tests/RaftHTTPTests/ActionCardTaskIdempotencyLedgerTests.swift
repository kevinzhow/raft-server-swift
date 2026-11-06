import Crypto
import Foundation
import RaftShared
import Testing
@testable import RaftHTTP

private typealias Request = ActionCardTaskIdempotencyLedger.Request

@Test func requestIdentityNeedsATrimmedNonEmptyStringKey() {
    #expect(Request(rawBody: "{\"idempotencyKey\":\"  k1 \",\"a\":1}")?.key == "k1")
    for raw in ["{}", "{\"idempotencyKey\":\"   \"}", "{\"idempotencyKey\":5}", "[]", "nope", ""] {
        #expect(Request(rawBody: raw) == nil, "\(raw)")
    }
}

@Test func fingerprintIgnoresOrderKeysFalsyMembersAndNulls() throws {
    let base = try #require(Request(rawBody: "{\"idempotencyKey\":\"k\",\"a\":1,\"b\":{\"x\":\"y\",\"n\":[1,{\"p\":2}]}}"))
    let variants = [
        "{\"b\":{\"n\":[1,{\"p\":2}],\"x\":\"y\"},\"a\":1,\"idempotencyKey\":\"other\"}",
        "{\"idempotencyKey\":\"k\",\"a\":1,\"flag\":false,\"gone\":null,\"zero\":0,\"b\":{\"x\":\"y\",\"n\":[1,{\"p\":2,\"q\":false}],\"idempotencyKey\":\"nested\"}}",
    ]
    for variant in variants {
        #expect(try #require(Request(rawBody: variant)).fingerprint == base.fingerprint, "\(variant)")
    }
    for different in [
        "{\"idempotencyKey\":\"k\",\"a\":2,\"b\":{\"x\":\"y\",\"n\":[1,{\"p\":2}]}}",
        "{\"idempotencyKey\":\"k\",\"a\":1,\"b\":{\"x\":\"y\",\"n\":[{\"p\":2},1]}}",
        "{\"idempotencyKey\":\"k\",\"a\":1,\"flag\":true,\"b\":{\"x\":\"y\",\"n\":[1,{\"p\":2}]}}",
    ] {
        #expect(try #require(Request(rawBody: different)).fingerprint != base.fingerprint, "\(different)")
    }
}

/// The retired `canonicalJSON` / `agentApiRequestFingerprint`, copied verbatim.
private func legacyCanonicalJSON(_ value: Any) -> Any {
    if let dict = value as? [String: Any] {
        var result: [String: Any] = [:]
        for (key, child) in dict {
            if key == "idempotencyKey" { continue }
            if let bool = child as? Bool, bool == false { continue }
            if child is NSNull { continue }
            result[key] = legacyCanonicalJSON(child)
        }
        return result
    }
    if let array = value as? [Any] { return array.map(legacyCanonicalJSON) }
    return value
}

private func legacyFingerprint(_ object: [String: Any]) -> String {
    let canonical = legacyCanonicalJSON(object)
    let data = (try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Test func fingerprintIsTheSha256OfTheLegacyCanonicalBytes() throws {
    // The retired `agentApiRequestFingerprint` hashed the sorted-key
    // serialization of the canonicalized object.
    let raw = "{\"idempotencyKey\":\"k\",\"z\":\"a/b\",\"a\":[1.5,true],\"drop\":false}"
    let object = try #require((try JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any])
    let legacy = legacyFingerprint(object)
    #expect(try #require(Request(rawBody: raw)).fingerprint == legacy)
}

@Test func portReplaysAndConflictsLikeTheLegacyClosures() {
    let cards = ManagedMCPAndCardsStore()
    let port = ActionCardTaskIdempotencyLedger.port(cards: cards)
    let body = "{\"idempotencyKey\":\"k1\",\"title\":\"t\"}"
    #expect(port.lookup("agent", "taskCreate", body) == .miss)
    port.store("agent", "taskCreate", body, "{\"ok\":true}")
    #expect(port.lookup("agent", "taskCreate", body) == .replay(body: "{\"ok\":true}"))
    // Same key, different request: the exact published conflict body.
    #expect(
        port.lookup("agent", "taskCreate", "{\"idempotencyKey\":\"k1\",\"title\":\"other\"}")
            == .conflict(body: "{\"error\":\"This idempotencyKey was already used for a different request\",\"code\":\"idempotency_key_reused\",\"mismatch\":\"request\",\"suggestedNextAction\":\"Retry with a new idempotencyKey.\"}")
    )
    // Another agent or route is a different ledger row.
    #expect(port.lookup("agent-2", "taskCreate", body) == .miss)
    #expect(port.lookup("agent", "taskConvert", body) == .miss)
    // A body without a key never stores or replays.
    port.store("agent", "taskCreate", "{\"title\":\"t\"}", "{\"ok\":false}")
    #expect(port.lookup("agent", "taskCreate", "{\"title\":\"t\"}") == .miss)
}

@Test func concurrentFirstWritesLeaveOneReplayableRow() async {
    let cards = ManagedMCPAndCardsStore()
    let port = ActionCardTaskIdempotencyLedger.port(cards: cards)
    let body = "{\"idempotencyKey\":\"race\",\"title\":\"t\"}"
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<32 {
            group.addTask {
                if port.lookup("agent", "taskCreate", body) == .miss {
                    port.store("agent", "taskCreate", body, "{\"n\":\(index)}")
                }
            }
        }
    }
    guard case .replay(let stored) = port.lookup("agent", "taskCreate", body) else {
        Issue.record("expected a stored replay row")
        return
    }
    #expect(stored.hasPrefix("{\"n\":"))
}
