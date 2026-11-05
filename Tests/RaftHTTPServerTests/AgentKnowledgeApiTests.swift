import Foundation
import HTTPTypes
import RaftHTTP
import Testing
import Vapor
import VaporTesting
@testable import RaftHTTPServer

/// Behavior pinned by `packages/server/src/routes/internalAgentKnowledge.api.test.ts`
/// at raft-source v1.21.23-source.1 (24 cases).

private let defaultIntent = "Help the user accomplish their Raft workflow"
private let defaultReason = "Need the relevant Manual guidance at this point"
private let manualContextCapability = "manual-context-v1"

private struct KnowledgeFixture {
    let accounts: EmailLoginDirectory
    let agentId: String
    let serverId: String
    let apiKey: String
    let readOnlyApiKey: String
}

private func seedKnowledgeFixture() -> KnowledgeFixture {
    let accounts = EmailLoginDirectory()
    let suffix = UUID().uuidString.lowercased()
    let ownerId = UUID().uuidString.lowercased()
    accounts.addAccount(
        id: ownerId,
        email: "agent-knowledge-\(suffix)@slock.test",
        password: "password123"
    )
    accounts.markEmailVerified(userId: ownerId)
    let serverId = UUID().uuidString.lowercased()
    accounts.oauth.addOwnedServer(
        id: serverId,
        slug: "agent-knowledge-\(suffix.prefix(8))",
        name: "Agent Knowledge Test",
        ownerId: ownerId
    )
    let agentId = accounts.oauth.createAgent(
        serverId: serverId,
        name: "AgentKnowledgeBot",
        runtime: "claude"
    )
    let apiKey = accounts.mintAgentCredential(
        agentId: agentId,
        scopes: ["knowledge"],
        name: "knowledge-test"
    )
    let readOnlyApiKey = accounts.mintAgentCredential(
        agentId: agentId,
        scopes: ["read"],
        name: "readonly-test"
    )
    return KnowledgeFixture(
        accounts: accounts,
        agentId: agentId,
        serverId: serverId,
        apiKey: apiKey,
        readOnlyApiKey: readOnlyApiKey
    )
}

private func agentHeaders(_ apiKey: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Raft-Client")!] = "cli"
    headers[HTTPField.Name("X-Raft-Client-Capabilities")!] = manualContextCapability
    return headers
}

private func legacyAgentHeaders(_ apiKey: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Raft-Client")!] = "cli"
    return headers
}

private func encodedQueryValue(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func knowledgeQuery(_ pairs: [(String, String?)]) -> String {
    pairs.compactMap { pair in
        pair.1.map { "\(pair.0)=\(encodedQueryValue($0))" }
    }.joined(separator: "&")
}

private func knowledgeContext(_ extra: [(String, String?)] = []) -> [(String, String?)] {
    extra + [("intent", defaultIntent), ("reason", defaultReason)]
}

private func jsonBody(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
}

private func withKnowledgeApp(
    _ fixture: KnowledgeFixture,
    _ body: @escaping (any TestClient) async throws -> Void
) async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            try await body(client)
        }
    }
}

private func getKnowledge(
    _ client: any TestClient,
    topic: String,
    extra: [(String, String?)] = [],
    headers: HTTPFields
) async throws -> ClientResponse {
    let query = knowledgeQuery([("topic", topic)] + knowledgeContext(extra))
    return try await client.get(
        URI(string: "/internal/agent-api/knowledge?\(query)"),
        headers: headers
    )
}

private func searchKnowledge(
    _ client: any TestClient,
    query: String,
    scope: String? = nil,
    extra: [(String, String?)] = [],
    headers: HTTPFields
) async throws -> ClientResponse {
    let queryString = knowledgeQuery([("query", query), ("scope", scope)] + knowledgeContext(extra))
    return try await client.get(
        URI(string: "/internal/agent-api/knowledge/search?\(queryString)"),
        headers: headers
    )
}

@Suite(.serialized)
struct AgentKnowledgeApiTests {
    // MARK: 1

    @Test func agentApiKnowledgeGetReturnsVersionedDocAndEmitsMetadataOnlyEvent() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        let intent = "Help the user understand their Raft workspace"
        let reason = "Need workspace home guidance"
        try await withKnowledgeApp(fixture) { client in
            let path = "/internal/agent-api/knowledge?" + knowledgeQuery([
                ("topic", "slock-home"),
                ("turn_id", "turn-1"),
                ("trace_id", "trace-1"),
                ("operation", "search"),
                ("resolution", "language_gate"),
                ("intent", intent),
                ("reason", reason),
            ])
            let response = try await client.get(URI(string: path), headers: agentHeaders(fixture.apiKey))
            #expect(response.status == .ok)
            let body = jsonBody(response)
            #expect(body["ok"] as? Bool == true)
            #expect(body["docId"] as? String == "slock-home")
            #expect(matches(body["docVersion"] as? String ?? "", "^sha256:[0-9a-f]{16}$"))
            #expect(body["docState"] as? String == "published")
            let content = body["content"] as? String ?? ""
            #expect(!content.isEmpty)

            let event = try #require(KnowledgeTelemetry.store.latest(agentId: fixture.agentId))
            #expect(event.agentId == fixture.agentId)
            #expect(event.serverId == fixture.serverId)
            #expect(event.docId == "slock-home")
            #expect(event.topicOrPath == "slock-home")
            #expect(event.docVersion == body["docVersion"] as? String)
            #expect(event.docState == "published")
            #expect(event.source == "cli")
            #expect(event.status == "success")
            #expect(event.operation == "get")
            #expect(event.resolution == "exact_id")
            #expect(event.turnId == "turn-1")
            #expect(event.traceId == "trace-1")
            #expect(event.intent == intent)
            #expect(event.reason == reason)
            #expect(event.contextContractVersion == manualContextCapability)
            #expect(event.responseBytes == content.utf8.count)
            #expect(!event.metadataJSON().contains(String(content.prefix(20))))
        }
    }

    // MARK: 2

    @Test func agentApiKnowledgeGetEmitsActionableNotFoundGuidanceWithoutDocVersion() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        try await withKnowledgeApp(fixture) { client in
            let response = try await getKnowledge(client, topic: "missing-topic", headers: agentHeaders(fixture.apiKey))
            #expect(response.status == .notFound)
            let body = jsonBody(response)
            #expect(body["code"] as? String == "knowledge_not_found")
            #expect(body["indexTopic"] as? String == "index")
            #expect(matches(body["error"] as? String ?? "", "raft manual get index --intent"))
            let suggested = body["suggested_next_action"] as? String ?? ""
            #expect(matches(suggested, "--intent \"Learn available Raft workflows\""))
            #expect(matches(suggested, "--reason \"Browse the topic catalog after a missing topic\""))
            #expect(!matches(suggested, "['$`;]"))
            let topicIds = body["suggestedTopicIds"] as? [String] ?? []
            #expect(!topicIds.isEmpty)
            #expect(topicIds.count <= 5)
            #expect(topicIds.contains("server"))
            for topicId in topicIds {
                #expect(!topicId.contains("/"))
                #expect(!topicId.hasPrefix("docs-"))
            }

            let event = try #require(KnowledgeTelemetry.store.latest(agentId: fixture.agentId))
            #expect(event.agentId == fixture.agentId)
            #expect(event.topicOrPath == "missing-topic")
            #expect(event.status == "not_found")
            #expect(event.operation == "get")
            #expect(event.resolution == nil)
            #expect(event.docId == nil)
            #expect(event.docVersion == nil)
            #expect(event.docState == nil)
        }
    }

    // MARK: 3

    @Test func agentApiKnowledgeGetResolvesImportedAgentKnowledgeDocsByDocIdAndPathAlias() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        try await withKnowledgeApp(fixture) { client in
            for topic in ["server", "agent-knowledge/server", "manual/agent-knowledge/server", "docs/agent-knowledge/server"] {
                let response = try await getKnowledge(client, topic: topic, headers: agentHeaders(fixture.apiKey))
                #expect(response.status == .ok, "\(topic) should resolve")
                let body = jsonBody(response)
                #expect(body["ok"] as? Bool == true)
                #expect(body["docId"] as? String == "server")
                #expect(matches(body["docVersion"] as? String ?? "", "^sha256:[0-9a-f]{16}$"))
                #expect(body["docState"] as? String == "published")
                #expect(body["contentType"] as? String == "text/markdown")
                let content = body["content"] as? String ?? ""
                #expect(content.contains("doc_id: server"))
                #expect(!content.contains("Verified against"))
            }
        }
    }

    // MARK: 4

    @Test func agentApiKnowledgeGetResolvesEvidenceDrivenExtraAliases() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        let cases: [(String, String)] = [
            ("list", "index"),
            ("topics", "index"),
            ("channels", "channel"),
            ("agents", "agent"),
            ("threads", "thread"),
            ("runtimes", "runtime"),
            ("role", "server-role"),
            ("daemon", "computer"),
            ("onboarding", "computer"),
            ("setup", "computer"),
            ("agent-browser", "agent-access-boundaries"),
            ("agent not replying", "agent-status"),
            ("agent permissions", "agent-access-boundaries"),
            ("pricing", "pricing-safe-answer"),
            ("slock-cli-overview", "raft-cli-overview"),
            ("legacy slock references", "rename-slock-to-raft"),
            ("overview", "index"),
            ("tasks", "task"),
            ("action", "action-cards"),
            ("action-card", "action-cards"),
            ("agent-create", "agent"),
            ("agent-creation", "agent"),
            ("messages", "message"),
            ("messaging", "message"),
            ("runtime-profile", "runtime"),
            ("machine", "computer"),
            ("machines", "computer"),
            ("agent:create", "agent"),
            ("creating agents", "agent"),
            ("agent-runtime", "runtime"),
            ("action_prepare", "action-cards"),
            ("action-prepare", "action-cards"),
            ("action prepare", "action-cards"),
            ("computers", "computer"),
            ("external-agent", "external-agent"),
            ("external-agents", "external-agent"),
            ("hermes", "external-agent"),
            ("device-code-login", "external-agent"),
            ("joint-channel", "joint-channel"),
            ("joint-channels", "joint-channel"),
            ("integration", "integration"),
            ("connected-apps", "integration"),
            ("login-with-raft", "integration"),
            ("agent-session", "agent-status"),
            ("session", "agent-status"),
            ("channel-delivery", "mention"),
            ("thread-visibility", "thread"),
            ("claude-md", "runtime"),
            ("project-instructions", "runtime"),
            ("runtime-config", "runtime"),
        ]
        try await withKnowledgeApp(fixture) { client in
            for (topic, expectedDocId) in cases {
                let response = try await getKnowledge(client, topic: topic, headers: agentHeaders(fixture.apiKey))
                #expect(response.status == .ok, "\(topic) should resolve")
                let body = jsonBody(response)
                #expect(body["ok"] as? Bool == true)
                #expect(body["docId"] as? String == expectedDocId, "\(topic) should be \(expectedDocId)")
                #expect(body["docState"] as? String == "published")
                #expect(body["contentType"] as? String == "text/markdown")
                #expect((body["content"] as? String ?? "").contains("doc_id: \(expectedDocId)"))
            }
        }
    }

    // MARK: 5

    @Test func agentApiKnowledgeGetExposesRaftCliOverviewAndSeparateRenameGuidance() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        try await withKnowledgeApp(fixture) { client in
            let overview = try await getKnowledge(client, topic: "raft-cli-overview", headers: agentHeaders(fixture.apiKey))
            #expect(overview.status == .ok)
            let overviewBody = jsonBody(overview)
            #expect(overviewBody["docId"] as? String == "raft-cli-overview")
            let overviewContent = overviewBody["content"] as? String ?? ""
            #expect(overviewContent.contains("Raft (former Slock) communication CLI"))
            #expect(!overviewContent.contains("## Product Rename - Slock to Raft"))

            let rename = try await getKnowledge(client, topic: "rename-slock-to-raft", headers: agentHeaders(fixture.apiKey))
            #expect(rename.status == .ok)
            let renameBody = jsonBody(rename)
            #expect(renameBody["docId"] as? String == "rename-slock-to-raft")
            let renameContent = renameBody["content"] as? String ?? ""
            #expect(renameContent.contains("Executable commands must match the CLI that is actually available"))
            #expect(!renameContent.contains("doc_id: raft-cli-overview"))
        }
    }

    // MARK: 6

    @Test func agentApiKnowledgeGetResolvesLegacyNestedDocLinksAfterFlatTopicMigration() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        let cases: [(String, String)] = [
            ("agent-knowledge/workspace/server", "server"),
            ("/agent-knowledge/participants/agent", "agent"),
            ("agent-knowledge/conversations/message#react-to-a-message", "message"),
        ]
        try await withKnowledgeApp(fixture) { client in
            for (topic, docId) in cases {
                let response = try await getKnowledge(client, topic: topic, headers: agentHeaders(fixture.apiKey))
                #expect(response.status == .ok, "\(topic) should resolve")
                let body = jsonBody(response)
                #expect(body["ok"] as? Bool == true)
                #expect(body["docId"] as? String == docId)
            }
        }
    }

    // MARK: 7

    @Test func agentApiKnowledgeGetResolvesRegisteredRecipeTopicsWithSlashSlugs() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        let cases: [(String, String, String)] = [
            ("recipes/index", "recipes/index", "Recipe index"),
            ("recipes/seeded", "recipes/seeded", "Seeded recipes"),
            ("recipes/archetype/analyst", "recipes/archetype/analyst", "doc_id:"),
            ("recipes/archetype/designer", "recipes/archetype/designer", "doc_id:"),
            ("recipes/archetype/operator", "recipes/archetype/operator", "doc_id:"),
            ("recipes/archetype/pa-coordinator", "recipes/archetype/pa-coordinator", "doc_id:"),
            ("recipes/archetype/patrol", "recipes/archetype/patrol", "message-id <anchor>"),
            ("recipes/archetype/verify-gate", "recipes/archetype/verify-gate", "doc_id:"),
            ("recipes/archetype/writer", "recipes/archetype/writer", "doc_id:"),
            ("recipes/decision/lane-design", "recipes/decision/lane-design", "doc_id:"),
            ("recipes/decision/one-or-many", "recipes/decision/one-or-many", "doc_id:"),
            ("recipes/decision/stake-strictness", "recipes/decision/stake-strictness", "doc_id:"),
            ("recipes/decision/when-to-ask-human", "recipes/decision/when-to-ask-human", "doc_id:"),
            ("recipes/pattern/coordinator-synthesis", "recipes/pattern/coordinator-synthesis", "doc_id:"),
            ("recipes/pattern/discuss-then-assign", "recipes/pattern/discuss-then-assign", "doc_id:"),
            ("recipes/pattern/evidence-handoff", "recipes/pattern/evidence-handoff", "doc_id:"),
            ("recipes/pattern/gate-chain", "recipes/pattern/gate-chain", "doc_id:"),
            ("recipes/pattern/interview-fanout", "recipes/pattern/interview-fanout", "doc_id:"),
            ("recipes/pattern/recurring-recovery", "recipes/pattern/recurring-recovery", "doc_id:"),
            ("recipes/pattern/shard-and-merge", "recipes/pattern/shard-and-merge", "doc_id:"),
            ("recipes/pattern/video-review-loop", "recipes/pattern/video-review-loop", "doc_id:"),
            ("recipes/playbook/billing-strictness", "recipes/playbook/billing-strictness", "doc_id:"),
            ("recipes/playbook/content-pipeline", "recipes/playbook/content-pipeline", "doc_id:"),
            ("recipes/technique/acceptance-surface", "recipes/technique/acceptance-surface", "doc_id:"),
            ("recipes/technique/attachment-comments", "recipes/technique/attachment-comments", "doc_id:"),
            ("recipes/technique/group-chat-debug", "recipes/technique/group-chat-debug", "doc_id:"),
            ("recipes/technique/html-artifact-discussion", "recipes/technique/html-artifact-discussion", "tier: seeded"),
            ("recipes/technique/login-with-raft", "recipes/technique/login-with-raft", "doc_id:"),
            ("recipes/technique/memory-hygiene", "recipes/technique/memory-hygiene", "doc_id:"),
            ("recipes/technique/preview-env", "recipes/technique/preview-env", "preview URL is actually reachable"),
            ("recipes/technique/proof-of-work-receipts", "recipes/technique/proof-of-work-receipts", "doc_id:"),
            ("recipes/technique/reminder-cron", "recipes/technique/reminder-cron", "doc_id:"),
            ("recipes/technique/sent-zero", "recipes/technique/sent-zero", "doc_id:"),
            ("recipes/technique/task-claim-lock", "recipes/technique/task-claim-lock", "Create-instead-of-claim"),
            ("recipes/technique/video-review", "recipes/technique/video-review", "tier: seeded"),
            ("manual/recipes/technique/sent-zero", "recipes/technique/sent-zero", "stage external actions"),
        ]
        try await withKnowledgeApp(fixture) { client in
            for (topic, docId, required) in cases {
                let response = try await getKnowledge(client, topic: topic, headers: agentHeaders(fixture.apiKey))
                #expect(response.status == .ok, "\(topic) should resolve")
                let body = jsonBody(response)
                #expect(body["ok"] as? Bool == true)
                #expect(body["docId"] as? String == docId)
                #expect(body["contentType"] as? String == "text/markdown")
                let content = body["content"] as? String ?? ""
                #expect(content.contains("doc_id: \(docId)"), "\(topic) content should carry its doc_id")
                #expect(content.contains(required), "\(topic) content should contain \(required)")
            }
        }
    }

    // MARK: 8

    @Test func agentApiKnowledgeSearchReturnsScopedTopThreeRecipeCandidatesAndEmitsTelemetry() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        let intent = "Help the user safely preview a change before merge"
        let reason = "Need recipe candidates for preview review."
        try await withKnowledgeApp(fixture) { client in
            let path = "/internal/agent-api/knowledge/search?" + knowledgeQuery([
                ("query", "preview before merge"),
                ("scope", "recipes"),
                ("turn_id", "turn-1"),
                ("trace_id", "trace-1"),
                ("intent", intent),
                ("reason", reason),
            ])
            let response = try await client.get(URI(string: path), headers: agentHeaders(fixture.apiKey))
            #expect(response.status == .ok)
            let body = jsonBody(response)
            #expect(body["ok"] as? Bool == true)
            #expect(body["query"] as? String == "preview before merge")
            #expect(body["scope"] as? String == "recipes")
            let results = body["results"] as? [[String: Any]] ?? []
            #expect(!results.isEmpty)
            #expect(results.count <= 3)
            #expect(results.first?["slug"] as? String == "recipes/technique/preview-env")
            #expect(matches(results.first?["title"] as? String ?? "", "preview"))
            #expect(matches(results.first?["firstScreen"] as? String ?? "", "Spin up a preview environment"))
            for result in results {
                #expect(matches(result["slug"] as? String ?? "", "^recipes/"))
                #expect(!(result["firstScreen"] as? String ?? "").isEmpty)
            }

            let event = try #require(KnowledgeTelemetry.store.latest(agentId: fixture.agentId))
            #expect(event.agentId == fixture.agentId)
            #expect(event.topicOrPath == "preview before merge")
            #expect(event.docId == "recipes/technique/preview-env")
            #expect(event.source == "cli")
            #expect(event.status == "success")
            #expect(event.operation == "search")
            #expect(event.resolution == "lexical")
            #expect(event.turnId == "turn-1")
            #expect(event.traceId == "trace-1")
            #expect(event.intent == intent)
            #expect(event.reason == reason)
            #expect((event.responseBytes ?? 0) > 0)
        }
    }

    // MARK: 9

    @Test func agentApiKnowledgeSearchHandlesBlindTestPhrasingWithoutCommonWordRankingPollution() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        let cases: [(String, String)] = [
            ("wake me up tomorrow morning", "recipes/technique/reminder-cron"),
            ("follow up next week when the PR lands", "recipes/technique/reminder-cron"),
            ("demo before merge", "recipes/technique/preview-env"),
            ("should I claim this before starting", "recipes/technique/task-claim-lock"),
            ("need approval before sending", "recipes/technique/sent-zero"),
        ]
        try await withKnowledgeApp(fixture) { client in
            for (query, expectedSlug) in cases {
                let response = try await searchKnowledge(
                    client,
                    query: query,
                    scope: "recipes",
                    headers: agentHeaders(fixture.apiKey)
                )
                #expect(response.status == .ok, "\(query) should hit")
                let body = jsonBody(response)
                let results = body["results"] as? [[String: Any]] ?? []
                #expect(results.first?["slug"] as? String == expectedSlug, "\(query) should rank \(expectedSlug) first")
            }
        }
    }

    // MARK: 10

    @Test func agentApiKnowledgeSearchMissReturnsCleanNotFoundAndEmitsMetadataOnlyTelemetry() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        try await withKnowledgeApp(fixture) { client in
            let response = try await searchKnowledge(
                client,
                query: "qzxv jjjq zzzqq",
                scope: "recipes",
                headers: agentHeaders(fixture.apiKey)
            )
            #expect(response.status == .notFound)
            let body = jsonBody(response)
            #expect(body["code"] as? String == "knowledge_not_found")
            #expect(matches(body["error"] as? String ?? "", "no matching topics"))
            let suggested = body["suggested_next_action"] as? String ?? ""
            #expect(matches(suggested, "manual get index --intent"))
            #expect(matches(suggested, "--intent \"Learn available Raft workflows\""))
            #expect(matches(suggested, "--reason \"Browse the topic catalog after a missing topic\""))
            #expect(!matches(suggested, "['$`;]"))

            let event = try #require(KnowledgeTelemetry.store.latest(agentId: fixture.agentId))
            #expect(event.agentId == fixture.agentId)
            #expect(event.topicOrPath == "qzxv jjjq zzzqq")
            #expect(event.status == "not_found")
            #expect(event.operation == "search")
            #expect(event.resolution == nil)
            #expect(event.docId == nil)
            #expect(event.docVersion == nil)
            #expect(event.docState == nil)
            #expect(!event.metadataJSON().contains("results"))
        }
    }

    // MARK: 11

    @Test func agentApiKnowledgeSearchAnswersNonEnglishQueryByAskingForEnglish() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        try await withKnowledgeApp(fixture) { client in
            let response = try await searchKnowledge(
                client,
                query: "频道权限",
                headers: agentHeaders(fixture.apiKey)
            )
            #expect(response.status == .notFound)
            let body = jsonBody(response)
            #expect(body["code"] as? String == "knowledge_language_unsupported")
            #expect(matches(body["error"] as? String ?? "", "English"))
            let suggested = body["suggested_next_action"] as? String ?? ""
            #expect(matches(suggested, "English keywords"))
            #expect(!matches(suggested, "['$`;]"))

            let event = try #require(KnowledgeTelemetry.store.latest(agentId: fixture.agentId))
            #expect(event.status == "not_found")
            #expect(event.topicOrPath == "频道权限")
            #expect(event.docId == nil)
            #expect(event.operation == "search")
            #expect(event.resolution == "language_gate")
        }
    }

    // MARK: 12

    @Test func agentApiKnowledgeSearchAppliesRelevanceFloorInsteadOfFabricatingNearestNeighbors() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        let queries = [
            "how do I deploy to production",
            "linux kernel module signing guide",
            "ci cache failed on the release branch",
            "sales lead qualification script",
            "employee payroll tax withholding form",
            "onboard a new human employee",
            "database migration rollback checklist",
        ]
        try await withKnowledgeApp(fixture) { client in
            for query in queries {
                let response = try await searchKnowledge(
                    client,
                    query: query,
                    scope: "recipes",
                    headers: agentHeaders(fixture.apiKey)
                )
                #expect(response.status == .notFound, "\(query) should be a clean miss")
                let body = jsonBody(response)
                #expect(body["code"] as? String == "knowledge_not_found")
                #expect(matches(body["error"] as? String ?? "", "no matching topics"))
            }
        }
    }

    // MARK: 13

    @Test func agentApiKnowledgeSearchRejectsUnsupportedScopeAndGetStaysExactOnly() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        try await withKnowledgeApp(fixture) { client in
            let badScope = try await searchKnowledge(
                client,
                query: "preview",
                scope: "agents",
                headers: agentHeaders(fixture.apiKey)
            )
            #expect(badScope.status == .badRequest)
            #expect(jsonBody(badScope)["code"] as? String == "knowledge_scope_invalid")

            let fuzzyGet = try await getKnowledge(
                client,
                topic: "preview before merge",
                headers: agentHeaders(fixture.apiKey)
            )
            #expect(fuzzyGet.status == .notFound)
            #expect(jsonBody(fuzzyGet)["code"] as? String == "knowledge_not_found")
        }
    }

    // MARK: 14

    @Test func sanitizeAgentKnowledgeContentStripsSourceOnlyCommentsOutsideFencedCodeBlocksOnly() {
        let source = [
            "---",
            "doc_id: source-comments",
            "---",
            "{/* source-only verification metadata */}",
            "Visible before fence.",
            "```md",
            "{/* this stays as an example */}",
            "```",
            "{/* another source-only comment */}",
            "Visible after fence.",
            "",
        ].joined(separator: "\n")

        let sanitized = KnowledgeDirectory.sanitizeAgentKnowledgeContent(source)
        #expect(!sanitized.contains("source-only verification metadata"))
        #expect(!sanitized.contains("another source-only comment"))
        #expect(sanitized.contains("{/* this stays as an example */}"))
        #expect(sanitized.contains("Visible before fence"))
        #expect(sanitized.contains("Visible after fence"))
    }

    // MARK: 15

    @Test func agentApiKnowledgeGetAcceptsTurnAndTraceIdsFromHeaders() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        try await withKnowledgeApp(fixture) { client in
            var headers = agentHeaders(fixture.apiKey)
            headers[HTTPField.Name("X-Slock-Turn-Id")!] = "turn-header"
            headers[HTTPField.Name("X-Slock-Trace-Id")!] = "trace-header"
            let response = try await getKnowledge(client, topic: "slock-home", headers: headers)
            #expect(response.status == .ok)
            let event = try #require(KnowledgeTelemetry.store.latest(agentId: fixture.agentId))
            #expect(event.turnId == "turn-header")
            #expect(event.traceId == "trace-header")
        }
    }

    // MARK: 16

    @Test func agentApiKnowledgeGetRejectsConflictingQueryAndHeaderCorrelationIds() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        try await withKnowledgeApp(fixture) { client in
            var headers = agentHeaders(fixture.apiKey)
            headers[HTTPField.Name("X-Slock-Turn-Id")!] = "header-turn"
            let response = try await getKnowledge(
                client,
                topic: "slock-home",
                extra: [("turn_id", "query-turn")],
                headers: headers
            )
            #expect(response.status == .badRequest)
            let body = jsonBody(response)
            #expect(body["code"] as? String == "knowledge_turn_id_invalid")
            #expect(matches(body["error"] as? String ?? "", "disagree"))
        }
    }

    // MARK: 17

    @Test func agentApiKnowledgeGetRequiresKnowledgeCapability() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        try await withKnowledgeApp(fixture) { client in
            let response = try await getKnowledge(
                client,
                topic: "slock-home",
                headers: agentHeaders(fixture.readOnlyApiKey)
            )
            #expect(response.status == .forbidden)
            let body = jsonBody(response)
            #expect(body["code"] as? String == "capability_not_authorized")
            #expect(body["requiredCapability"] as? String == "knowledge")
            #expect(KnowledgeTelemetry.store.events(agentId: fixture.agentId).isEmpty)
        }
    }

    // MARK: 18

    @Test func agentApiKnowledgeGetRejectsRawPayloadRationale() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        let rawReason = "[target=#secret msg=abcdef12] @human: raw quoted message"
        try await withKnowledgeApp(fixture) { client in
            let response = try await getKnowledge(
                client,
                topic: "slock-home",
                extra: [("reason", rawReason)],
                headers: agentHeaders(fixture.apiKey)
            )
            #expect(response.status == .badRequest)
            let body = jsonBody(response)
            #expect(body["code"] as? String == "knowledge_reason_invalid")
            #expect(matches(body["error"] as? String ?? "", "raw Slock message headers"))
        }
    }

    // MARK: 19

    @Test func agentApiKnowledgeGetRequiresIntentAndReasonIndependently() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        try await withKnowledgeApp(fixture) { client in
            let missingIntentQuery = knowledgeQuery([("topic", "slock-home"), ("reason", defaultReason)])
            let missingIntent = try await client.get(
                URI(string: "/internal/agent-api/knowledge?\(missingIntentQuery)"),
                headers: agentHeaders(fixture.apiKey)
            )
            #expect(missingIntent.status == .badRequest)
            #expect(jsonBody(missingIntent)["code"] as? String == "knowledge_intent_invalid")

            let missingReasonQuery = knowledgeQuery([("topic", "slock-home"), ("intent", defaultIntent)])
            let missingReason = try await client.get(
                URI(string: "/internal/agent-api/knowledge?\(missingReasonQuery)"),
                headers: agentHeaders(fixture.apiKey)
            )
            #expect(missingReason.status == .badRequest)
            #expect(jsonBody(missingReason)["code"] as? String == "knowledge_reason_invalid")
        }
    }

    // MARK: 20

    @Test func agentApiManualSearchRequiresBothFieldsForCapabilityBearingClients() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        try await withKnowledgeApp(fixture) { client in
            let missingIntentQuery = knowledgeQuery([("query", "preview"), ("reason", defaultReason)])
            let missingIntent = try await client.get(
                URI(string: "/internal/agent-api/knowledge/search?\(missingIntentQuery)"),
                headers: agentHeaders(fixture.apiKey)
            )
            #expect(missingIntent.status == .badRequest)
            #expect(jsonBody(missingIntent)["code"] as? String == "knowledge_intent_invalid")

            let missingReasonQuery = knowledgeQuery([("query", "preview"), ("intent", defaultIntent)])
            let missingReason = try await client.get(
                URI(string: "/internal/agent-api/knowledge/search?\(missingReasonQuery)"),
                headers: agentHeaders(fixture.apiKey)
            )
            #expect(missingReason.status == .badRequest)
            #expect(jsonBody(missingReason)["code"] as? String == "knowledge_reason_invalid")
        }
    }

    // MARK: 21

    @Test func agentApiManualKeepsPublishedLegacyClientsCompatibleAndRecordsRolloutEligibility() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        try await withKnowledgeApp(fixture) { client in
            let getResponse = try await client.get(
                URI(string: "/internal/agent-api/knowledge?topic=slock-home"),
                headers: legacyAgentHeaders(fixture.apiKey)
            )
            #expect(getResponse.status == .ok)

            let searchResponse = try await client.get(
                URI(string: "/internal/agent-api/knowledge/search?query=preview&scope=recipes"),
                headers: legacyAgentHeaders(fixture.apiKey)
            )
            #expect(searchResponse.status == .ok)

            let missingGet = try await client.get(
                URI(string: "/internal/agent-api/knowledge?topic=legacy-missing-topic"),
                headers: legacyAgentHeaders(fixture.apiKey)
            )
            #expect(missingGet.status == .notFound)
            let missingGetSuggested = jsonBody(missingGet)["suggested_next_action"] as? String ?? ""
            #expect(matches(missingGetSuggested, "raft manual get index"))
            #expect(!missingGetSuggested.contains("--intent"))
            #expect(!missingGetSuggested.contains("--reason"))

            let missingSearch = try await client.get(
                URI(string: "/internal/agent-api/knowledge/search?query=legacyzzzznomatch&scope=recipes"),
                headers: legacyAgentHeaders(fixture.apiKey)
            )
            #expect(missingSearch.status == .notFound)
            let missingSearchSuggested = jsonBody(missingSearch)["suggested_next_action"] as? String ?? ""
            #expect(matches(missingSearchSuggested, "raft manual get index"))
            #expect(!missingSearchSuggested.contains("--intent"))
            #expect(!missingSearchSuggested.contains("--reason"))

            let events = KnowledgeTelemetry.store.events(agentId: fixture.agentId)
            #expect(events.count == 4)
            for event in events {
                #expect(event.intent == nil)
                #expect(event.reason == nil)
                #expect(event.contextContractVersion == nil)
            }
        }
    }

    // MARK: 22

    @Test func agentApiKnowledgeSearchRejectsRawPayloadIntent() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        let rawIntent = "[target=#secret msg=abcdef12] @human: raw quoted message"
        try await withKnowledgeApp(fixture) { client in
            let response = try await searchKnowledge(
                client,
                query: "preview",
                extra: [("intent", rawIntent)],
                headers: agentHeaders(fixture.apiKey)
            )
            #expect(response.status == .badRequest)
            let body = jsonBody(response)
            #expect(body["code"] as? String == "knowledge_intent_invalid")
            #expect(matches(body["error"] as? String ?? "", "raw Slock message headers"))
        }
    }

    // MARK: 23

    @Test func agentApiKnowledgeGetRejectsNonCliSource() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        try await withKnowledgeApp(fixture) { client in
            var headers = agentHeaders(fixture.apiKey)
            headers[HTTPField.Name("X-Raft-Client")!] = nil
            let response = try await getKnowledge(client, topic: "slock-home", headers: headers)
            #expect(response.status == .badRequest)
            #expect(jsonBody(response)["code"] as? String == "knowledge_source_invalid")
        }
    }

    // MARK: 24

    @Test func agentApiKnowledgeGetStillHonorsTheLegacyXSlockClientHeader() async throws {
        KnowledgeTelemetry.store.reset()
        let fixture = seedKnowledgeFixture()
        try await withKnowledgeApp(fixture) { client in
            var headers = agentHeaders(fixture.apiKey)
            headers[HTTPField.Name("X-Raft-Client")!] = nil
            headers[HTTPField.Name("X-Slock-Client")!] = "cli"
            let response = try await getKnowledge(client, topic: "slock-home", headers: headers)
            #expect(response.status == .ok)
        }
    }
}
