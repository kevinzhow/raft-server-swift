import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// `/internal/agent-api/knowledge` and `.../knowledge/search`.
///
/// Ported from `packages/server/src/routes/agentKnowledge.ts` plus the
/// `internalAgentApi.ts` `knowledgeGet` / `knowledgeSearch` mounts at
/// raft-source v1.21.23-source.1. The handlers keep the upstream gate order:
/// credential capability (`knowledge`) → implemented CLI source → topic/query
/// and scope → intent/reason context contract → correlation ids → retrieval.
/// Operation and resolution are route-owned and are never read from the query.
struct KnowledgeFeature: RouteCollection, Sendable {
    let services: FallbackServices

    init(services: FallbackServices) {
        self.services = services
    }

    func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    func register(routes: any RoutesBuilder) {
        let knowledge = routes.grouped("internal", "agent-api", "knowledge")
        knowledge.get { request -> Response in
            routeResponse(Self.getReply(request: request, services: services))
        }
        knowledge.get("search") { request -> Response in
            routeResponse(Self.searchReply(request: request, services: services))
        }
    }

    // MARK: - Identity and capability

    private struct KnowledgeIdentity {
        let agentId: String
        let serverId: String
    }

    private enum IdentityResolution {
        case identity(KnowledgeIdentity)
        case denial(HTTPReply)
    }

    private static func resolveIdentity(
        _ request: Request,
        _ services: FallbackServices
    ) -> IdentityResolution {
        let identity: AgentApiIdentityDTO
        do {
            identity = try services.emailAccounts.agentsLifecycle.resolveAgentApiIdentity(
                authorization: request.headers[.authorization]
            )
        } catch let error as any DomainError {
            return .denial(KnowledgeDirectory.reply(Int(error.status), error.publishedErrorBody.render()))
        } catch {
            return .denial(KnowledgeDirectory.reply(500, "{\"error\":\"Internal error\"}"))
        }
        guard identity.scopes.contains("knowledge") else {
            let body = KnowledgeDirectory.jsonObject([
                "error": "Agent credential is not authorized for this capability",
                "code": "capability_not_authorized",
                "requiredCapability": "knowledge",
            ])
            return .denial(KnowledgeDirectory.reply(403, body))
        }
        return .identity(KnowledgeIdentity(agentId: identity.agentId, serverId: identity.serverId))
    }

    // MARK: - Request projection

    private static func resolveSource(_ request: Request) -> String? {
        let client = request.headers[HTTPField.Name("X-Raft-Client")!]
            ?? request.headers[HTTPField.Name("X-Slock-Client")!]
        return client == "cli" ? "cli" : nil
    }

    private static func header(_ request: Request, _ name: String) -> String? {
        guard let field = HTTPField.Name(name) else { return nil }
        return request.headers[field]
    }

    private static func queryValue(_ request: Request, _ name: String) -> String? {
        guard let raw = request.url.query, !raw.isEmpty else { return nil }
        for pair in raw.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard decodeQueryComponent(parts[0]) == name else { continue }
            return parts.count > 1 ? decodeQueryComponent(parts[1]) : ""
        }
        return nil
    }

    private static func decodeQueryComponent(_ raw: String) -> String {
        let withSpaces = raw.replacingOccurrences(of: "+", with: " ")
        return withSpaces.removingPercentEncoding ?? withSpaces
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private static func record(
        _ event: KnowledgeTelemetryEvent
    ) {
        KnowledgeTelemetry.store.record(event)
    }

    // MARK: - GET /internal/agent-api/knowledge

    private static func getReply(request: Request, services: FallbackServices) -> HTTPReply {
        let startedAt = Date()
        let identity: KnowledgeIdentity
        switch resolveIdentity(request, services) {
        case .identity(let value): identity = value
        case .denial(let reply): return reply
        }

        guard let source = resolveSource(request) else {
            return KnowledgeDirectory.reply(
                400,
                KnowledgeDirectory.errorPayload(
                    code: "knowledge_source_invalid",
                    error: "Knowledge requests must come from an implemented source"
                )
            )
        }

        guard let topic = KnowledgeDirectory.normalizeTopic(queryValue(request, "topic")) else {
            return KnowledgeDirectory.reply(
                400,
                KnowledgeDirectory.errorPayload(
                    code: "knowledge_topic_invalid",
                    error: "topic query parameter is required"
                )
            )
        }

        let contextContractVersion = KnowledgeDirectory.hasManualContextCapability(
            header(request, "X-Raft-Client-Capabilities")
        ) ? KnowledgeDirectory.manualContextCapability : nil
        let contextRequired = contextContractVersion != nil

        let intent: String?
        switch KnowledgeDirectory.resolveContext(queryValue(request, "intent"), field: "intent", required: contextRequired) {
        case .value(let value): intent = value
        case .invalid(let error):
            return KnowledgeDirectory.reply(
                400,
                KnowledgeDirectory.errorPayload(code: "knowledge_intent_invalid", error: error)
            )
        }

        let reason: String?
        switch KnowledgeDirectory.resolveContext(queryValue(request, "reason"), field: "reason", required: contextRequired) {
        case .value(let value): reason = value
        case .invalid(let error):
            return KnowledgeDirectory.reply(
                400,
                KnowledgeDirectory.errorPayload(code: "knowledge_reason_invalid", error: error)
            )
        }

        let turnId: String?
        switch KnowledgeDirectory.resolveCorrelation(
            queryValue: queryValue(request, "turn_id"),
            headerValue: header(request, "X-Slock-Turn-Id")
        ) {
        case .value(let value): turnId = value
        case .invalid(let error):
            return KnowledgeDirectory.reply(
                400,
                KnowledgeDirectory.errorPayload(code: "knowledge_turn_id_invalid", error: error)
            )
        }

        let traceId: String?
        switch KnowledgeDirectory.resolveCorrelation(
            queryValue: queryValue(request, "trace_id"),
            headerValue: header(request, "X-Slock-Trace-Id")
        ) {
        case .value(let value): traceId = value
        case .invalid(let error):
            return KnowledgeDirectory.reply(
                400,
                KnowledgeDirectory.errorPayload(code: "knowledge_trace_id_invalid", error: error)
            )
        }

        guard let resolved = KnowledgeDirectory.resolveWithDiscovery(topic) else {
            let guidance = KnowledgeDirectory.buildNotFoundGuidanceWithCandidates(
                topic,
                contextRequired: contextRequired
            )
            record(KnowledgeTelemetryEvent(
                serverId: identity.serverId,
                agentId: identity.agentId,
                topicOrPath: topic,
                source: source,
                status: "not_found",
                latencyMs: elapsedMilliseconds(since: startedAt),
                turnId: turnId,
                traceId: traceId,
                intent: intent,
                reason: reason,
                contextContractVersion: contextContractVersion,
                operation: "get"
            ))
            return KnowledgeDirectory.reply(404, KnowledgeDirectory.getNotFoundPayload(guidance))
        }

        let doc = resolved.doc
        let responseBytes = doc.content.utf8.count
        record(KnowledgeTelemetryEvent(
            serverId: identity.serverId,
            agentId: identity.agentId,
            docId: doc.docId,
            topicOrPath: topic,
            docVersion: doc.docVersion,
            docState: doc.docState,
            source: source,
            status: "success",
            latencyMs: elapsedMilliseconds(since: startedAt),
            responseBytes: responseBytes,
            turnId: turnId,
            traceId: traceId,
            intent: intent,
            reason: reason,
            contextContractVersion: contextContractVersion,
            operation: "get",
            resolution: resolved.resolution.rawValue
        ))
        return KnowledgeDirectory.reply(200, KnowledgeDirectory.docPayload(doc))
    }

    // MARK: - GET /internal/agent-api/knowledge/search

    private static func searchReply(request: Request, services: FallbackServices) -> HTTPReply {
        let startedAt = Date()
        let identity: KnowledgeIdentity
        switch resolveIdentity(request, services) {
        case .identity(let value): identity = value
        case .denial(let reply): return reply
        }

        guard let source = resolveSource(request) else {
            return KnowledgeDirectory.reply(
                400,
                KnowledgeDirectory.errorPayload(
                    code: "knowledge_source_invalid",
                    error: "Knowledge requests must come from an implemented source"
                )
            )
        }

        guard let query = KnowledgeDirectory.normalizeTopic(queryValue(request, "query")) else {
            return KnowledgeDirectory.reply(
                400,
                KnowledgeDirectory.errorPayload(
                    code: "knowledge_query_invalid",
                    error: "query parameter is required"
                )
            )
        }

        let scope: String?
        switch KnowledgeDirectory.normalizeSearchScope(queryValue(request, "scope")) {
        case .omitted: scope = nil
        case .recipes: scope = "recipes"
        case .invalid:
            return KnowledgeDirectory.reply(
                400,
                KnowledgeDirectory.errorPayload(
                    code: "knowledge_scope_invalid",
                    error: "scope must be omitted or set to recipes"
                )
            )
        }

        let contextContractVersion = KnowledgeDirectory.hasManualContextCapability(
            header(request, "X-Raft-Client-Capabilities")
        ) ? KnowledgeDirectory.manualContextCapability : nil
        let contextRequired = contextContractVersion != nil

        let intent: String?
        switch KnowledgeDirectory.resolveContext(queryValue(request, "intent"), field: "intent", required: contextRequired) {
        case .value(let value): intent = value
        case .invalid(let error):
            return KnowledgeDirectory.reply(
                400,
                KnowledgeDirectory.errorPayload(code: "knowledge_intent_invalid", error: error)
            )
        }

        let reason: String?
        switch KnowledgeDirectory.resolveContext(queryValue(request, "reason"), field: "reason", required: contextRequired) {
        case .value(let value): reason = value
        case .invalid(let error):
            return KnowledgeDirectory.reply(
                400,
                KnowledgeDirectory.errorPayload(code: "knowledge_reason_invalid", error: error)
            )
        }

        let turnId: String?
        switch KnowledgeDirectory.resolveCorrelation(
            queryValue: queryValue(request, "turn_id"),
            headerValue: header(request, "X-Slock-Turn-Id")
        ) {
        case .value(let value): turnId = value
        case .invalid(let error):
            return KnowledgeDirectory.reply(
                400,
                KnowledgeDirectory.errorPayload(code: "knowledge_turn_id_invalid", error: error)
            )
        }

        let traceId: String?
        switch KnowledgeDirectory.resolveCorrelation(
            queryValue: queryValue(request, "trace_id"),
            headerValue: header(request, "X-Slock-Trace-Id")
        ) {
        case .value(let value): traceId = value
        case .invalid(let error):
            return KnowledgeDirectory.reply(
                400,
                KnowledgeDirectory.errorPayload(code: "knowledge_trace_id_invalid", error: error)
            )
        }

        if KnowledgeDirectory.manualQueryNeedsEnglish(query) {
            record(KnowledgeTelemetryEvent(
                serverId: identity.serverId,
                agentId: identity.agentId,
                topicOrPath: query,
                source: source,
                status: "not_found",
                latencyMs: elapsedMilliseconds(since: startedAt),
                turnId: turnId,
                traceId: traceId,
                intent: intent,
                reason: reason,
                contextContractVersion: contextContractVersion,
                operation: "search",
                resolution: "language_gate"
            ))
            return KnowledgeDirectory.reply(
                404,
                KnowledgeDirectory.languageUnsupportedPayload(contextRequired: contextRequired)
            )
        }

        let outcome = KnowledgeDirectory.search(query: query, scope: scope)
        guard !outcome.results.isEmpty else {
            record(KnowledgeTelemetryEvent(
                serverId: identity.serverId,
                agentId: identity.agentId,
                topicOrPath: query,
                source: source,
                status: "not_found",
                latencyMs: elapsedMilliseconds(since: startedAt),
                turnId: turnId,
                traceId: traceId,
                intent: intent,
                reason: reason,
                contextContractVersion: contextContractVersion,
                operation: "search"
            ))
            return KnowledgeDirectory.reply(
                404,
                KnowledgeDirectory.searchMissPayload(scope: scope, contextRequired: contextRequired)
            )
        }

        let body = AgentKnowledgeSearchSerializer.serialize(
            query: query,
            scope: scope,
            results: outcome.results
        )
        let top = outcome.results[0]
        record(KnowledgeTelemetryEvent(
            serverId: identity.serverId,
            agentId: identity.agentId,
            docId: top.slug,
            topicOrPath: query,
            docVersion: top.docVersion,
            docState: top.docState,
            source: source,
            status: "success",
            latencyMs: elapsedMilliseconds(since: startedAt),
            responseBytes: body.utf8.count,
            turnId: turnId,
            traceId: traceId,
            intent: intent,
            reason: reason,
            contextContractVersion: contextContractVersion,
            operation: "search",
            resolution: outcome.resolution
        ))
        return KnowledgeDirectory.reply(200, body)
    }
}
