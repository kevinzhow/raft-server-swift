import Foundation
import Testing
@testable import RaftHTTP

/// Behavior pinned by `packages/server/src/routes/agentKnowledgeSearchSerialization.test.ts`
/// at raft-source v1.21.23-source.1.

private let knowledgeResult = AgentKnowledgeSearchResult(
    slug: "channel",
    title: "Channels",
    firstScreen: "About channels.",
    docVersion: "sha256:deadbeef",
    docState: "published",
    matchedTerms: ["chanel"],
    correctedTerms: [AgentKnowledgeCorrectedTerm(term: "chanel", matched: "channel")]
)

@Test func knowledgeSearchPayloadCarriesTheMatchReasons() throws {
    let payload = try #require(
        try JSONSerialization.jsonObject(
            with: Data(AgentKnowledgeSearchSerializer.serialize(query: "chanel", scope: nil, results: [knowledgeResult]).utf8)
        ) as? [String: Any]
    )
    #expect(payload["ok"] as? Bool == true)
    #expect(payload["query"] as? String == "chanel")
    #expect(payload["scope"] is NSNull)
    let results = try #require(payload["results"] as? [[String: Any]])
    #expect(results.count == 1)
    let served = try #require(results.first)
    #expect(served["matchedTerms"] as? [String] == ["chanel"])
    let corrected = try #require(served["correctedTerms"] as? [[String: Any]])
    #expect(corrected as NSArray == [["term": "chanel", "matched": "channel"]] as NSArray)
}

@Test func knowledgeSearchPayloadDoesNotLeakInternalScoringFields() throws {
    let payload = try #require(
        try JSONSerialization.jsonObject(
            with: Data(AgentKnowledgeSearchSerializer.serialize(query: "chanel", scope: nil, results: [knowledgeResult]).utf8)
        ) as? [String: Any]
    )
    let results = try #require(payload["results"] as? [[String: Any]])
    let served = try #require(results.first)
    #expect(Array(served.keys).sorted() == ["correctedTerms", "firstScreen", "matchedTerms", "slug", "title"])
    #expect(served["docVersion"] == nil)
    #expect(served["docState"] == nil)
}
