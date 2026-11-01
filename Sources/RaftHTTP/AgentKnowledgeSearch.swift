import Foundation

/// One knowledge-search hit as the agent-facing payload serves it.
public struct AgentKnowledgeSearchResult: Sendable, Equatable {
    public var slug: String
    public var title: String
    public var firstScreen: String
    public var docVersion: String
    public var docState: String
    public var matchedTerms: [String]
    public var correctedTerms: [AgentKnowledgeCorrectedTerm]

    public init(
        slug: String,
        title: String,
        firstScreen: String,
        docVersion: String,
        docState: String,
        matchedTerms: [String],
        correctedTerms: [AgentKnowledgeCorrectedTerm]
    ) {
        self.slug = slug
        self.title = title
        self.firstScreen = firstScreen
        self.docVersion = docVersion
        self.docState = docState
        self.matchedTerms = matchedTerms
        self.correctedTerms = correctedTerms
    }
}

public struct AgentKnowledgeCorrectedTerm: Sendable, Equatable {
    public var term: String
    public var matched: String

    public init(term: String, matched: String) {
        self.term = term
        self.matched = matched
    }
}

/// `serializeKnowledgeSearch` from `routes/agentKnowledge.ts`.
///
/// Match reasons (`matchedTerms`, `correctedTerms`) are part of the
/// agent-facing contract; `docVersion`/`docState` stay internal to the search
/// surface. The projection is explicit, never a blanket spread.
public enum AgentKnowledgeSearchSerializer {
    public static func serialize(
        query: String,
        scope: String?,
        results: [AgentKnowledgeSearchResult]
    ) -> String {
        let rows = results.map { result -> String in
            let terms = result.matchedTerms.map { jsonString($0) }.joined(separator: ",")
            let corrected = result.correctedTerms.map { entry in
                "{\"term\":\(jsonString(entry.term)),\"matched\":\(jsonString(entry.matched))}"
            }.joined(separator: ",")
            return "{\"slug\":\(jsonString(result.slug)),\"title\":\(jsonString(result.title)),\"firstScreen\":\(jsonString(result.firstScreen)),\"matchedTerms\":[\(terms)],\"correctedTerms\":[\(corrected)]}"
        }.joined(separator: ",")
        let scopeJSON = scope.map(jsonString) ?? "null"
        return "{\"ok\":true,\"query\":\(jsonString(query)),\"scope\":\(scopeJSON),\"results\":[\(rows)]}"
    }
}
