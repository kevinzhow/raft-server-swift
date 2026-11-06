import Foundation
import RaftHTTP
import Synchronization

/// Agent-facing Manual directory: registry, retrieval, search ranking, not-found
/// guidance and the metadata-only telemetry seam.
///
/// Ported from `packages/server/src/services/agentKnowledgeService.ts` at
/// raft-source v1.21.23-source.1. The corpus is embedded verbatim from
/// `manual/agent-knowledge/*.md` and `manual/recipes/*.md`; content is sanitized
/// at read time (`sanitizeAgentKnowledgeContent`) and the document version is
/// the first 16 hex characters of SHA-256 over the sanitized bytes.

struct KnowledgeRegistryEntry: Sendable {
    let docId: String
    let aliases: [String]
    let docState: String
    let contentType: String
    let sourcePath: String
    let content: String
}

struct KnowledgeDoc: Sendable, Equatable {
    let docId: String
    let topicOrPath: String
    let docVersion: String
    let docState: String
    let content: String
    let contentType: String
}

enum KnowledgeGetResolution: String, Sendable {
    case exactId = "exact_id"
    case alias
    case tokenRoute = "token_route"
}

struct KnowledgeSearchOutcome: Sendable {
    let results: [AgentKnowledgeSearchResult]
    let resolution: String?
}

struct KnowledgeMissCandidate: Sendable, Equatable {
    let slug: String
    let title: String
    let matchedTerms: [String]
}

struct KnowledgeNotFoundGuidance: Sendable {
    let indexTopic: String
    let suggestedTopicIds: [String]
    let suggestedNextAction: String
    let error: String
    let candidates: [KnowledgeMissCandidate]
}

struct KnowledgeTelemetryEvent: Sendable, Equatable {
    var serverId: String
    var agentId: String
    var computerId: String?
    var docId: String?
    var topicOrPath: String
    var docVersion: String?
    var docState: String?
    var source: String
    var status: String
    var requestedAt: Date = Date()
    var latencyMs: Int?
    var responseBytes: Int?
    var turnId: String?
    var traceId: String?
    var intent: String?
    var reason: String?
    var contextContractVersion: String?
    var operation: String?
    var resolution: String?

    /// Metadata projection used by tests to prove the event never carries the
    /// document body. Same field set as the stored row, no content field.
    func metadataJSON() -> String {
        var object: [String: Any] = [
            "serverId": serverId,
            "agentId": agentId,
            "topicOrPath": topicOrPath,
            "source": source,
            "status": status,
        ]
        object["computerId"] = computerId
        object["docId"] = docId
        object["docVersion"] = docVersion
        object["docState"] = docState
        object["latencyMs"] = latencyMs
        object["responseBytes"] = responseBytes
        object["turnId"] = turnId
        object["traceId"] = traceId
        object["intent"] = intent
        object["reason"] = reason
        object["contextContractVersion"] = contextContractVersion
        object["operation"] = operation
        object["resolution"] = resolution
        return KnowledgeDirectory.jsonObject(object)
    }
}

/// In-memory telemetry seam for `agent_knowledge_events`. The upstream row has
/// the same metadata fields; the body is never stored.
final class KnowledgeTelemetryStore: Sendable {
    private let events = Mutex<[KnowledgeTelemetryEvent]>([])

    func record(_ event: KnowledgeTelemetryEvent) {
        events.withLock { $0.append(event) }
    }

    func reset() {
        events.withLock { $0.removeAll() }
    }

    func all() -> [KnowledgeTelemetryEvent] {
        events.withLock { $0 }
    }

    func events(agentId: String) -> [KnowledgeTelemetryEvent] {
        all().filter { $0.agentId == agentId }
    }

    func latest() -> KnowledgeTelemetryEvent? {
        all().last
    }

    func latest(agentId: String) -> KnowledgeTelemetryEvent? {
        events(agentId: agentId).last
    }
}

enum KnowledgeTelemetry {
    static let store = KnowledgeTelemetryStore()
}

// ==== GENERATED TABLES START ====
// ==== GENERATED TABLES END ====

// ==== GENERATED REGISTRY START ====
// ==== GENERATED REGISTRY END ====

enum KnowledgeScopeParse {
    case omitted
    case recipes
    case invalid
}

enum KnowledgeContextValidation {
    case ok(String)
    case invalid(String)
}

enum KnowledgeDirectory {
    static let maxTopicLength = 200
    static let maxCorrelationLength = 200
    static let maxSearchResults = 3
    static let firstScreenMaxChars = 700
    static let minSearchScore = 70
    static let minFuzzyTermLength = 5
    static let minMultiTermCoverage = 0.5
    static let manualContextCapability = "manual-context-v1"
    static let manualIndexCommand = "raft manual get index --intent \"Learn available Raft workflows\" --reason \"Browse the topic catalog after a missing topic\""
    static let legacyIndexCommand = "raft manual get index"

    // MARK: - Field normalization

    static func hasManualContextCapability(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return raw.split(separator: ",", omittingEmptySubsequences: false).contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == manualContextCapability
        }
    }

    static func normalizeTopic(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let topic = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty, topic.count <= maxTopicLength else { return nil }
        return topic
    }

    static func normalizeSearchScope(_ raw: String?) -> KnowledgeScopeParse {
        guard let raw, !raw.isEmpty else { return .omitted }
        let scope = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if scope.isEmpty { return .omitted }
        return scope == "recipes" ? .recipes : .invalid
    }

    static func normalizeOptionalField(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maxCorrelationLength else { return nil }
        return value
    }

    static func normalizeLookupTopic(_ topicOrPath: String) -> String {
        var value = topicOrPath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasPrefix("/") { value.removeFirst() }
        // JS `/[?#].*$/` without the `m` flag: `.` never crosses a newline, so a
        // marker only truncates when it sits on the final line (the usual
        // single-line topic/path case). Markdown bodies keep their headings.
        let lastLineStart = value.lastIndex(of: "\n").map { value.index(after: $0) } ?? value.startIndex
        if let marker = value[lastLineStart...].firstIndex(where: { $0 == "?" || $0 == "#" }) {
            value = String(value[value.startIndex..<marker])
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func validateContext(_ raw: String?, field: String) -> KnowledgeContextValidation {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid("\(field) is required")
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count < 12 { return .invalid("\(field) must be at least 12 characters") }
        if value.count > 500 { return .invalid("\(field) must be at most 500 characters") }
        if value.range(of: #"\[target=.*\bmsg="#, options: .regularExpression) != nil {
            return .invalid("\(field) must not contain raw Slock message headers")
        }
        if value.components(separatedBy: "```").count >= 3 {
            return .invalid("\(field) must not contain raw prompts or code blocks")
        }
        if value.range(of: "https?://", options: [.regularExpression, .caseInsensitive]) != nil {
            return .invalid("\(field) must not contain URLs")
        }
        if value.range(of: #"\bsk_(?:agent|machine|computer)_[a-z0-9_-]+\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .invalid("\(field) must not contain credentials")
        }
        if value.range(of: #"\bBearer\s+\S+"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .invalid("\(field) must not contain credentials")
        }
        if value.range(of: #"\b(?:api[_ -]?key|token|password|secret)\s*[:=]\s*\S+"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .invalid("\(field) must not contain credentials")
        }
        let lineCount = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).count
        if lineCount > 4 { return .invalid("\(field) must be a concise natural-language summary") }
        return .ok(value)
    }

    enum ContextResolution {
        case value(String?)
        case invalid(String)
    }

    static func resolveContext(_ raw: String?, field: String, required: Bool) -> ContextResolution {
        let missing = raw == nil || (raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !required && missing { return .value(nil) }
        switch validateContext(raw, field: field) {
        case .ok(let value): return .value(value)
        case .invalid(let error): return .invalid(error)
        }
    }

    enum CorrelationResolution {
        case value(String?)
        case invalid(String)
    }

    static func resolveCorrelation(queryValue: String?, headerValue: String?) -> CorrelationResolution {
        let fromQuery = normalizeOptionalField(queryValue)
        let fromHeader = normalizeOptionalField(headerValue)
        if let fromQuery, let fromHeader, fromQuery != fromHeader {
            return .invalid("query parameter and header value disagree")
        }
        return .value(fromHeader ?? fromQuery)
    }

    // MARK: - Corpus access

    static func sanitizeAgentKnowledgeContent(_ source: String) -> String {
        var output = ""
        var cursor = source.startIndex
        var inFence = false
        while let marker = nextFenceMarker(in: source, from: cursor) {
            let segment = String(source[cursor..<marker])
            output += inFence ? segment : stripSourceOnlyComments(segment)
            output += "```"
            cursor = source.index(marker, offsetBy: 3)
            inFence.toggle()
        }
        let tail = String(source[cursor...])
        output += inFence ? tail : stripSourceOnlyComments(tail)
        return output
    }

    private static func nextFenceMarker(in source: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < source.endIndex {
            if source[index...].hasPrefix("```") {
                let isLineStart = index == source.startIndex || source[source.index(before: index)] == "\n"
                if isLineStart { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func stripSourceOnlyComments(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\/\\*[\\s\\S]*?\\*\\/\\}", options: []) else {
            return source
        }
        return regex.stringByReplacingMatches(
            in: source,
            options: [],
            range: NSRange(source.startIndex..<source.endIndex, in: source),
            withTemplate: ""
        )
    }

    private static func content(of entry: KnowledgeRegistryEntry) -> String {
        sanitizeAgentKnowledgeContent(entry.content)
    }

    private static func docVersion(of content: String) -> String {
        "sha256:" + sha256Hex16(content)
    }

    static func sha256Hex16(_ input: String) -> String {
        String(KnowledgeSHA256.hexDigest(input).prefix(16))
    }

    private static func entry(forDocId docId: String) -> KnowledgeRegistryEntry? {
        knowledgeRegistry.first { $0.docId == docId }
    }

    private static func makeDoc(_ entry: KnowledgeRegistryEntry, topicOrPath: String) -> KnowledgeDoc {
        let body = content(of: entry)
        return KnowledgeDoc(
            docId: entry.docId,
            topicOrPath: topicOrPath,
            docVersion: docVersion(of: body),
            docState: entry.docState,
            content: body,
            contentType: entry.contentType
        )
    }

    static func resolveExact(_ topicOrPath: String) -> KnowledgeDoc? {
        let normalized = normalizeLookupTopic(topicOrPath)
        guard let entry = knowledgeRegistry.first(where: { candidate in
            candidate.aliases.contains { $0.lowercased() == normalized }
        }) else { return nil }
        return makeDoc(entry, topicOrPath: topicOrPath)
    }

    static func resolveWithDiscovery(_ topicOrPath: String) -> (doc: KnowledgeDoc, resolution: KnowledgeGetResolution)? {
        let normalized = normalizeLookupTopic(topicOrPath)
        if let doc = resolveExact(topicOrPath) {
            let resolution: KnowledgeGetResolution =
                normalized == doc.docId.lowercased() ? .exactId : .alias
            return (doc, resolution)
        }
        let tokens = tokenizeTopicForRouting(topicOrPath)
        for route in knowledgeTokenRoutes {
            guard route.tokens.contains(where: { tokens.contains($0) }) else { continue }
            if let entry = entry(forDocId: route.docId) {
                return (makeDoc(entry, topicOrPath: topicOrPath), .tokenRoute)
            }
        }
        return nil
    }

    private static func tokenizeTopicForRouting(_ topicOrPath: String) -> Set<String> {
        Set(splitAsciiAlnum(topicOrPath))
    }

    // MARK: - Search

    private struct ScoreDetail {
        var score = 0
        var matchedTerms: Set<String> = []
        var hasExactMatch = false
        var fuzzyTerms: [String: String] = [:]
        var resolution: String = "lexical"
    }

    static func search(query: String, scope: String?) -> KnowledgeSearchOutcome {
        let normalizedQuery = normalizeLookupTopic(query)
        let queryTerms = tokenizeSearchText(normalizedQuery)
        let rawTerms = rawSearchTokens(normalizedQuery)
        let entries = knowledgeRegistry.filter { entry in
            guard let scope else { return true }
            return entry.sourcePath.hasPrefix("manual/\(scope)/")
        }
        var contents: [String: String] = [:]
        var titles: [String: String] = [:]
        var firstScreens: [String: String] = [:]
        var versions: [String: String] = [:]
        var corpusVocabulary: Set<String> = []
        for entry in entries {
            let body = content(of: entry)
            contents[entry.docId] = body
            titles[entry.docId] = extractKnowledgeTitle(body) ?? entry.docId
            firstScreens[entry.docId] = extractFirstScreen(body)
            versions[entry.docId] = docVersion(of: body)
            for token in tokenizeKnowledgeTextParts(normalizeLookupTopic(body)) {
                corpusVocabulary.insert(token)
            }
            for alias in entry.aliases {
                for token in tokenizeKnowledgeTextParts(normalizeLookupTopic(alias)) {
                    corpusVocabulary.insert(token)
                }
            }
        }

        var scored: [(result: AgentKnowledgeSearchResult, score: Int, resolution: String)] = []
        for entry in entries {
            let body = contents[entry.docId] ?? content(of: entry)
            let title = titles[entry.docId] ?? extractKnowledgeTitle(body) ?? entry.docId
            let firstScreen = firstScreens[entry.docId] ?? extractFirstScreen(body)
            let detail = scoreEntryDetailed(
                entry: entry,
                title: title,
                content: body,
                normalizedQuery: normalizedQuery,
                queryTerms: queryTerms,
                rawTerms: rawTerms,
                corpusVocabulary: corpusVocabulary
            )
            let score = applyRelevanceFloor(detail.score, queryTerms: queryTerms, matchedTerms: detail.matchedTerms, hasExactMatch: detail.hasExactMatch)
            if score <= 0 { continue }
            scored.append((
                AgentKnowledgeSearchResult(
                    slug: entry.docId,
                    title: title,
                    firstScreen: firstScreen,
                    docVersion: versions[entry.docId] ?? docVersion(of: body),
                    docState: entry.docState,
                    matchedTerms: detail.matchedTerms.sorted(),
                    correctedTerms: detail.fuzzyTerms
                        .map { AgentKnowledgeCorrectedTerm(term: $0.key, matched: $0.value) }
                        .sorted { $0.term < $1.term }
                ),
                score,
                detail.resolution
            ))
        }

        scored.sort { left, right in
            left.score == right.score ? left.result.slug < right.result.slug : left.score > right.score
        }
        let ranked = Array(scored.prefix(maxSearchResults))
        return KnowledgeSearchOutcome(
            results: ranked.map(\.result),
            resolution: ranked.first?.resolution
        )
    }

    private static func applyRelevanceFloor(
        _ score: Int,
        queryTerms: [String],
        matchedTerms: Set<String>,
        hasExactMatch: Bool
    ) -> Int {
        if !hasExactMatch && !passesSearchRelevanceFloor(score: score, queryTerms: queryTerms, matchedTerms: matchedTerms) {
            return 0
        }
        return score
    }

    private static func passesSearchRelevanceFloor(
        score: Int,
        queryTerms: [String],
        matchedTerms: Set<String>
    ) -> Bool {
        let minMatchedTerms = queryTerms.count >= 4 ? 3 : (queryTerms.count >= 2 ? 2 : 1)
        if matchedTerms.count < minMatchedTerms { return false }
        if queryTerms.count >= 2 && matchedTerms.allSatisfy({ lowSignalSearchTerms.contains($0) }) {
            return false
        }
        if score >= 240 { return true }
        if score < minSearchScore { return false }
        if queryTerms.count <= 1 {
            return !matchedTerms.isEmpty && score >= minSearchScore
        }
        return matchedTerms.count >= 2
            && Double(matchedTerms.count) / Double(queryTerms.count) >= minMultiTermCoverage
    }

    private static func scoreEntryDetailed(
        entry: KnowledgeRegistryEntry,
        title: String,
        content: String,
        normalizedQuery: String,
        queryTerms: [String],
        rawTerms: [String],
        corpusVocabulary: Set<String>?
    ) -> ScoreDetail {
        var detail = ScoreDetail()
        let normalizedTitle = normalizeLookupTopic(title)
        let normalizedAliases = entry.aliases.map(normalizeLookupTopic)
        let normalizedContent = normalizeLookupTopic(content)
        let aliasText = normalizedAliases.joined(separator: " ")
        let docIdTokens = tokenizeKnowledgeText(entry.docId)
        let titleTokens = tokenizeKnowledgeText(normalizedTitle)
        let aliasTokens = tokenizeKnowledgeText(aliasText)
        let contentTokenParts = tokenizeKnowledgeTextParts(normalizedContent)
        let contentTokens = Set(contentTokenParts)

        let exactAliasMatch = normalizedAliases.contains(normalizedQuery)
        let exactDocIdMatch = entry.docId.lowercased() == normalizedQuery
        let exactTitleMatch = normalizedTitle == normalizedQuery
        detail.hasExactMatch = exactAliasMatch || exactDocIdMatch || exactTitleMatch

        if exactAliasMatch { detail.score += 1000 }
        if exactDocIdMatch { detail.score += 800 }
        if exactTitleMatch { detail.score += 700 }
        if normalizedTitle.contains(normalizedQuery) { detail.score += 240 }
        if normalizedContent.contains(normalizedQuery) { detail.score += 90 }

        for alias in normalizedAliases {
            if alias.contains(normalizedQuery) || normalizedQuery.contains(alias) {
                detail.score += 220
            }
        }

        for term in queryTerms {
            var termMatched = false
            if docIdTokens.contains(term) {
                detail.score += 120
                termMatched = true
            }
            if titleTokens.contains(term) {
                detail.score += term == "reminder" ? 160 : 90
                termMatched = true
            }
            if aliasTokens.contains(term) {
                detail.score += 70
                termMatched = true
            }
            if contentTokens.contains(term) {
                detail.score += 35
                termMatched = true
            }
            if termMatched {
                detail.matchedTerms.insert(term)
                continue
            }
            guard let rawTerm = rawTerms.first(where: { $0 == term || stemSearchTerm($0) == term }) else {
                continue
            }
            if let corpusVocabulary, corpusVocabulary.contains(rawTerm) { continue }
            let fuzzyFields: [(String, Set<String>, Int)] = [
                ("docId", docIdTokens, fuzzyFieldScores["docId"] ?? 80),
                ("title", titleTokens, fuzzyFieldScores["title"] ?? 75),
                ("alias", aliasTokens, fuzzyFieldScores["alias"] ?? 45),
                ("content", contentTokens, fuzzyFieldScores["content"] ?? 25),
            ]
            for (_, tokens, fieldScore) in fuzzyFields {
                guard let fuzzyToken = findFuzzyTokenMatch(rawTerm, tokens: tokens) else { continue }
                detail.score += fieldScore
                detail.matchedTerms.insert(term)
                detail.fuzzyTerms[rawTerm] = fuzzyToken
                break
            }
        }

        if queryTerms.count >= 2
            && orderedCoverage(contentTokenParts, queryTerms) >= minMultiTermCoverage {
            detail.score += 180
        }
        if queryTerms.count >= 2 && isRecipeAggregateSearchEntry(entry) {
            detail.score = Int(Double(detail.score) * 0.2)
        }
        detail.resolution = classifySearchRetrievalPath(
            normalizedQuery: normalizedQuery,
            matchedTerms: detail.matchedTerms,
            fuzzyTerms: detail.fuzzyTerms,
            hasExactMatch: detail.hasExactMatch
        )
        return detail
    }

    private static func isRecipeAggregateSearchEntry(_ entry: KnowledgeRegistryEntry) -> Bool {
        entry.docId == "recipes/index" || entry.docId == "recipes/seeded"
    }

    private static func classifySearchRetrievalPath(
        normalizedQuery: String,
        matchedTerms: Set<String>,
        fuzzyTerms: [String: String],
        hasExactMatch: Bool
    ) -> String {
        var lexicalTerms: Set<String> = []
        var expansionTerms: Set<String> = []
        for rawTerm in rawSearchTokens(normalizedQuery) {
            let stemmed = stemSearchTerm(rawTerm)
            let synonyms = searchSynonyms[stemmed] ?? []
            if !searchSynonymReplacements.contains(stemmed) { lexicalTerms.insert(stemmed) }
            for synonym in synonyms { expansionTerms.insert(synonym) }
        }
        let fuzzyQueryTerms = Set(fuzzyTerms.keys.map(stemSearchTerm))
        let hasTypo = !fuzzyTerms.isEmpty
        let hasExpansion = matchedTerms.contains { expansionTerms.contains($0) }
        let hasLexical = hasExactMatch || matchedTerms.contains {
            lexicalTerms.contains($0) && !fuzzyQueryTerms.contains($0)
        }
        let mechanisms = [hasLexical, hasExpansion, hasTypo].filter { $0 }.count
        if mechanisms > 1 { return "mixed" }
        if hasTypo { return "typo_correction" }
        if hasExpansion { return "concept_expansion" }
        return "lexical"
    }

    // MARK: - Tokenization and scoring primitives

    private static func splitAsciiAlnum(_ input: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for scalar in input.lowercased().unicodeScalars {
            let value = scalar.value
            if (value >= 97 && value <= 122) || (value >= 48 && value <= 57) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    static func tokenizeSearchText(_ input: String) -> [String] {
        var terms: [String] = []
        var seen: Set<String> = []
        for part in splitAsciiAlnum(input) where part.count >= 3 && !searchStopWords.contains(part) {
            let stemmed = stemSearchTerm(part)
            let synonyms = searchSynonyms[stemmed] ?? []
            let produced = searchSynonymReplacements.contains(stemmed) ? synonyms : [stemmed] + synonyms
            for term in produced where !seen.contains(term) {
                seen.insert(term)
                terms.append(term)
            }
        }
        return terms
    }

    private static func rawSearchTokens(_ input: String) -> [String] {
        var tokens: [String] = []
        var seen: Set<String> = []
        for part in splitAsciiAlnum(input) where part.count >= 3 && !searchStopWords.contains(part) {
            if !seen.contains(part) {
                seen.insert(part)
                tokens.append(part)
            }
        }
        return tokens
    }

    private static func stemSearchTerm(_ term: String) -> String {
        if let override = searchStemOverrides[term] { return override }
        if term.count > 5 && term.hasSuffix("ing") { return String(term.dropLast(3)) }
        if term.count > 4 && term.hasSuffix("ies") { return String(term.dropLast(3)) + "y" }
        if term.count > 4 && term.hasSuffix("ed") { return String(term.dropLast(2)) }
        if term.count > 4 && term.hasSuffix("ion") { return String(term.dropLast(3)) }
        if term.count > 3 && term.hasSuffix("s") { return String(term.dropLast(1)) }
        return term
    }

    private static func tokenizeKnowledgeText(_ input: String) -> Set<String> {
        Set(tokenizeKnowledgeTextParts(input))
    }

    private static func tokenizeKnowledgeTextParts(_ input: String) -> [String] {
        splitAsciiAlnum(input).filter { $0.count >= 3 }.map(stemSearchTerm)
    }

    private static func findByEditDistanceOne(_ term: String, tokens: Set<String>) -> String? {
        guard term.count >= minFuzzyTermLength else { return nil }
        for token in tokens {
            guard token.count >= minFuzzyTermLength else { continue }
            if isWithinEditDistanceOne(term, token) { return token }
        }
        return nil
    }

    private static func findFuzzyTokenMatch(_ term: String, tokens: Set<String>) -> String? {
        findByEditDistanceOne(term, tokens: tokens)
    }

    private static func isWithinEditDistanceOne(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let aChars = Array(a)
        let bChars = Array(b)
        let lengthDiff = aChars.count - bChars.count
        if lengthDiff > 1 || lengthDiff < -1 { return false }
        let shorter = aChars.count <= bChars.count ? aChars : bChars
        let longer = aChars.count <= bChars.count ? bChars : aChars
        var i = 0
        var j = 0
        var edited = false
        while i < shorter.count && j < longer.count {
            if shorter[i] == longer[j] {
                i += 1
                j += 1
                continue
            }
            if edited { return false }
            edited = true
            if shorter.count == longer.count { i += 1 }
            j += 1
        }
        return true
    }

    private static func orderedCoverage(_ haystack: [String], _ needles: [String]) -> Double {
        guard !needles.isEmpty else { return 0 }
        var cursor = 0
        for token in haystack {
            if token == needles[cursor] { cursor += 1 }
            if cursor >= needles.count { return Double(cursor) / Double(needles.count) }
        }
        return Double(cursor) / Double(needles.count)
    }

    // MARK: - Title and first screen

    static func extractKnowledgeTitle(_ content: String) -> String? {
        if let regex = try? NSRegularExpression(pattern: "^---\\n[\\s\\S]*?\\ntitle:\\s*(.+?)\\n[\\s\\S]*?\\n---", options: []),
           let match = regex.firstMatch(in: content, options: [], range: NSRange(content.startIndex..<content.endIndex, in: content)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: content) {
            var title = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if title.hasPrefix("\"") || title.hasPrefix("'") { title.removeFirst() }
            if title.hasSuffix("\"") || title.hasSuffix("'") { title.removeLast() }
            return title
        }
        if let regex = try? NSRegularExpression(pattern: "(?m)^#\\s+(.+)$", options: []),
           let match = regex.firstMatch(in: content, options: [], range: NSRange(content.startIndex..<content.endIndex, in: content)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: content) {
            return String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func extractFirstScreen(_ content: String) -> String {
        var body = content
        if let regex = try? NSRegularExpression(pattern: "^---\\n[\\s\\S]*?\\n---\\n?", options: []),
           let match = regex.firstMatch(in: content, options: [], range: NSRange(content.startIndex..<content.endIndex, in: content)),
           let range = Range(match.range, in: content) {
            body = String(content[range.upperBound...])
        }
        let lines = body
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("<!--") }
        var excerpt = String(lines.joined(separator: "\n").prefix(firstScreenMaxChars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if excerpt.count == firstScreenMaxChars {
            excerpt = excerpt.replacingOccurrences(of: "\\s+\\S*$", with: "", options: .regularExpression)
            excerpt += "..."
        }
        return excerpt
    }

    // MARK: - Guidance

    static func findKnowledgeMissCandidates(_ topicOrPath: String, limit: Int = 3) -> [KnowledgeMissCandidate] {
        let normalizedQuery = normalizeLookupTopic(topicOrPath)
        let queryTerms = tokenizeSearchText(normalizedQuery)
        guard !queryTerms.isEmpty else { return [] }
        var scored: [(candidate: KnowledgeMissCandidate, score: Int)] = []
        for entry in knowledgeRegistry {
            let body = content(of: entry)
            let title = extractKnowledgeTitle(body) ?? entry.docId
            let detail = scoreEntryDetailed(
                entry: entry,
                title: title,
                content: body,
                normalizedQuery: normalizedQuery,
                queryTerms: queryTerms,
                rawTerms: queryTerms,
                corpusVocabulary: nil
            )
            if detail.score <= 0 || detail.matchedTerms.isEmpty { continue }
            scored.append((
                KnowledgeMissCandidate(
                    slug: entry.docId,
                    title: title,
                    matchedTerms: detail.matchedTerms.sorted()
                ),
                detail.score
            ))
        }
        scored.sort { left, right in
            left.score == right.score ? left.candidate.slug < right.candidate.slug : left.score > right.score
        }
        return scored.prefix(limit).map(\.candidate)
    }

    static func buildAgentKnowledgeIndexCommand(contextRequired: Bool) -> String {
        contextRequired ? manualIndexCommand : legacyIndexCommand
    }

    private static func deriveManualSearchKeywords(_ topicOrPath: String) -> String {
        let keywords = splitAsciiAlnum(topicOrPath).joined(separator: " ")
        return keywords.isEmpty ? "the workflow I need" : keywords
    }

    static func buildAgentKnowledgeSearchCommand(_ topicOrPath: String, contextRequired: Bool) -> String {
        let keywords = deriveManualSearchKeywords(topicOrPath)
        return contextRequired
            ? "raft manual search \"\(keywords)\" --intent \"Find the Raft workflow I need\" --reason \"An exact topic id did not resolve\""
            : "raft manual search \"\(keywords)\""
    }

    static func listAgentKnowledgeTopicIds() -> [String] {
        knowledgeRegistry
            .filter { $0.sourcePath.hasPrefix("manual/agent-knowledge/") }
            .map(\.docId)
            .sorted()
    }

    static func suggestAgentKnowledgeTopicIds(_ topicOrPath: String, limit: Int) -> [String] {
        let normalized = normalizeLookupTopic(topicOrPath)
        let topicIds = listAgentKnowledgeTopicIds()
        let preferred = ["index", "server", "agent-status", "raft-cli-overview", "task", "channel"]
        let normalizedParts = Set(splitAsciiAlnum(normalized))
        let scoredRaw: [(docId: String, score: Int)] = topicIds.map { docId in
            let idParts = splitAsciiAlnum(docId)
            var score = 0
            if docId == normalized { score += 100 }
            if docId.contains(normalized) || normalized.contains(docId) { score += 40 }
            for part in idParts where normalizedParts.contains(part) { score += 10 }
            return (docId: docId, score: score)
        }
        let filteredScored = scoredRaw.filter { $0.score > 0 }
        let orderedScored = filteredScored.sorted { left, right in
            left.score == right.score ? left.docId < right.docId : left.score > right.score
        }
        let scored: [String] = orderedScored.map(\.docId)
        var suggestions = Set(scored)
        for docId in preferred {
            if topicIds.contains(docId) { suggestions.insert(docId) }
            if suggestions.count >= limit { break }
        }
        return Array(suggestions).sorted().prefix(limit).map { $0 }
    }

    static func buildNotFoundGuidance(_ topicOrPath: String, contextRequired: Bool) -> KnowledgeNotFoundGuidance {
        let suggestedTopicIds = suggestAgentKnowledgeTopicIds(topicOrPath, limit: 5)
        let suggestionText = suggestedTopicIds.isEmpty
            ? ""
            : " Available topics include: \(suggestedTopicIds.joined(separator: ", "))."
        let retryContext = contextRequired ? ", keeping your --intent/--reason" : ""
        let suggestedNextAction = "No topic matched. Retry with a close topic id\(retryContext). "
            + "If you do not know the exact id, search for it:\n\(buildAgentKnowledgeSearchCommand(topicOrPath, contextRequired: contextRequired))\n"
            + "Or browse all topics:\n\(buildAgentKnowledgeIndexCommand(contextRequired: contextRequired))"
            + suggestionText
        return KnowledgeNotFoundGuidance(
            indexTopic: "index",
            suggestedTopicIds: suggestedTopicIds,
            suggestedNextAction: suggestedNextAction,
            error: "Manual topic not found. \(suggestedNextAction)",
            candidates: []
        )
    }

    static func buildNotFoundGuidanceWithCandidates(
        _ topicOrPath: String,
        contextRequired: Bool
    ) -> KnowledgeNotFoundGuidance {
        let base = buildNotFoundGuidance(topicOrPath, contextRequired: contextRequired)
        let candidates = findKnowledgeMissCandidates(topicOrPath)
        guard !candidates.isEmpty else { return base }
        let candidateLines = candidates.enumerated().map { index, candidate in
            "\(index + 1). \(candidate.slug) — \"\(candidate.title)\" (matched: \(candidate.matchedTerms.joined(separator: ", ")))"
        }.joined(separator: "\n")
        let candidateBlock = "Closest matches by content:\n\(candidateLines)"
        let suggestedNextAction = "\(candidateBlock)\n\(base.suggestedNextAction)"
        return KnowledgeNotFoundGuidance(
            indexTopic: base.indexTopic,
            suggestedTopicIds: base.suggestedTopicIds,
            suggestedNextAction: suggestedNextAction,
            error: "Manual topic not found. \(suggestedNextAction)",
            candidates: candidates
        )
    }

    static func manualQueryNeedsEnglish(_ query: String) -> Bool {
        let normalized = normalizeLookupTopic(query)
        guard containsNonLatinScript(normalized) else { return false }
        return tokenizeSearchText(normalized).isEmpty
    }

    private static func containsNonLatinScript(_ input: String) -> Bool {
        for scalar in input.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2FA1F,
                 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF,
                 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F,
                 0x0400...0x04FF, 0x0600...0x06FF, 0x0750...0x077F,
                 0x0590...0x05FF, 0x0E00...0x0E7F, 0x0900...0x097F, 0x0370...0x03FF:
                return true
            default:
                continue
            }
        }
        return false
    }

    // MARK: - Replies

    static func reply(_ status: Int, _ body: String) -> HTTPReply {
        HTTPReply(
            status: status,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Content-Length": String(body.utf8.count),
            ],
            body: body
        )
    }

    static func jsonObject(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }


    static func docPayload(_ doc: KnowledgeDoc) -> String {
        jsonObject([
            "ok": true,
            "docId": doc.docId,
            "topicOrPath": doc.topicOrPath,
            "docVersion": doc.docVersion,
            "docState": doc.docState,
            "contentType": doc.contentType,
            "content": doc.content,
        ])
    }

    static func getNotFoundPayload(_ guidance: KnowledgeNotFoundGuidance) -> String {
        jsonObject([
            "ok": false,
            "code": "knowledge_not_found",
            "error": guidance.error,
            "indexTopic": guidance.indexTopic,
            "suggestedTopicIds": guidance.suggestedTopicIds,
            "suggested_next_action": guidance.suggestedNextAction,
            "candidates": guidance.candidates.map { candidate in
                [
                    "slug": candidate.slug,
                    "title": candidate.title,
                    "matchedTerms": candidate.matchedTerms,
                ] as [String: Any]
            },
        ])
    }

    static func searchMissPayload(scope: String?, contextRequired: Bool) -> String {
        let scopeHint = scope.map { " in \($0)" } ?? ""
        let retryContext = contextRequired ? ", keeping your --intent/--reason" : ""
        let indexCommand = buildAgentKnowledgeIndexCommand(contextRequired: contextRequired)
        return jsonObject([
            "ok": false,
            "code": "knowledge_not_found",
            "error": "Manual search found no matching topics\(scopeHint). Retry with different keywords\(retryContext).",
            "suggested_next_action": "Retry with different keywords\(retryContext). To browse all topics, run:\n\(indexCommand)",
        ])
    }

    static func languageUnsupportedPayload(contextRequired: Bool) -> String {
        let retryContext = contextRequired ? ", keeping your --intent/--reason" : ""
        let indexCommand = buildAgentKnowledgeIndexCommand(contextRequired: contextRequired)
        return jsonObject([
            "ok": false,
            "code": "knowledge_language_unsupported",
            "error": "The Manual is written in English and is not translated. Search in English.",
            "suggested_next_action": "Retry the same question using English keywords\(retryContext). To browse all topics, run:\n\(indexCommand)",
        ])
    }

    static func errorPayload(code: String, error: String) -> String {
        jsonObject(["ok": false, "code": code, "error": error])
    }
}

// MARK: - SHA-256

enum KnowledgeSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hexDigest(_ input: String) -> String {
        var message = Array(input.utf8)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }
        var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var schedule = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            for index in 0..<16 {
                let base = chunkStart + index * 4
                schedule[index] = (UInt32(message[base]) << 24)
                    | (UInt32(message[base + 1]) << 16)
                    | (UInt32(message[base + 2]) << 8)
                    | UInt32(message[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(schedule[index - 15], 7) ^ rotateRight(schedule[index - 15], 18) ^ (schedule[index - 15] >> 3)
                let s1 = rotateRight(schedule[index - 2], 17) ^ rotateRight(schedule[index - 2], 19) ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ ch &+ k[index] &+ schedule[index]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                h = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            state[0] = state[0] &+ a; state[1] = state[1] &+ b
            state[2] = state[2] &+ c; state[3] = state[3] &+ d
            state[4] = state[4] &+ e; state[5] = state[5] &+ f
            state[6] = state[6] &+ g; state[7] = state[7] &+ h
        }
        return state.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
