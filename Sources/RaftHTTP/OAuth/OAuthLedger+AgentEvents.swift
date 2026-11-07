import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    /// Seeds a queued event for the duplicate-retry contract.
    public func seedQueuedAgentEvent(
        serverId: String,
        agentId: String,
        clientRecordId: String,
        externalEventId: String
    ) -> String {
        let id = UUID().uuidString.lowercased()
        self.state.withLock { ledgerState in
            ledgerState.agentEvents.append(AgentEvent(
                id: id,
                serverId: serverId,
                agentId: agentId,
                clientId: clientRecordId,
                kind: "event",
                summary: "Queued before delivery failed",
                payloadHash: String(repeating: "0", count: 64),
                externalEventId: externalEventId,
                status: "queued",
                expiresAt: Date().addingTimeInterval(24 * 60 * 60),
                createdAt: Date()
            ))
        }
        return id
    }

    /// Validates the resource-bound principal and claims or appends an event in
    /// one transaction. Invalid field markers are consumed in the original order.
    func ingestAgentEvent(_ attempt: AppAgentEventAttempt) -> AppAgentEventOutcome {
        return self.state.withLock { ledgerState in
            guard let token = principalTokenLocked(attempt.bearerToken, state: ledgerState) else {
                return .invalidToken
            }
            guard token.principalType == "agent", let agentId = token.agentId else {
                return .agentTokenRequired
            }
            let expectedResource = "urn:raft:server:\(token.serverId):agent-inbound"
            guard token.resource == expectedResource else {
                return .resourceRequired(expectedResource)
            }
            guard let kind = attempt.kind else {
                return .invalidKind
            }
            let requiredScope = kind.requiredScope
            guard token.scopes.contains(requiredScope) else {
                return .insufficientScope(requiredScope)
            }
            let target = (attempt.target ?? agentId).lowercased()
            guard target == agentId else {
                return .crossAgentTarget
            }
            guard let summary = attempt.summary else {
                return .summaryRequired
            }
            guard let payloadJSON = attempt.payloadJSON else {
                return .invalidPayload
            }
            let external = attempt.externalEventId
            let payloadHash = sha256(payloadJSON)
            let now = Date()
            if let external, !external.isEmpty,
               let index = ledgerState.agentEvents.firstIndex(where: {
                   $0.serverId == token.serverId && $0.agentId == agentId
                       && $0.clientId == token.clientId && $0.externalEventId == external
                       && $0.expiresAt > now
               }) {
                var event = ledgerState.agentEvents[index]
                let claimed = event.status == "queued"
                if claimed {
                    event.status = "delivering"
                    ledgerState.agentEvents[index] = event
                }
                let receipt = AppAgentEventReceipt(id: event.id, expiresAt: event.expiresAt, payloadHash: event.payloadHash)
                return claimed ? .reclaimed(receipt) : .duplicate(receipt)
            }
            let event = AgentEvent(
                id: UUID().uuidString.lowercased(),
                serverId: token.serverId,
                agentId: agentId,
                clientId: token.clientId,
                kind: kind.rawValue,
                summary: summary,
                payloadHash: payloadHash,
                payloadJSON: payloadJSON,
                externalEventId: external,
                status: "delivering",
                expiresAt: now.addingTimeInterval(24 * 60 * 60),
                createdAt: now
            )
            ledgerState.agentEvents.append(event)
            return .created(AppAgentEventReceipt(id: event.id, expiresAt: event.expiresAt, payloadHash: event.payloadHash))
        }
    }

    /// One re-readable third-party event body, scoped to the agent that owns it.
    public struct ThirdPartyEventReadMessage: Sendable {
        public var id: String
        public var kind: String
        public var summary: String
        public var content: String
        public var clientKey: String
        public var clientName: String
        public var externalEventId: String?
        public var payloadHash: String
        public var payloadJSON: String
        public var createdAt: Date
        public var expiresAt: Date
    }

    public enum ThirdPartyEventReadResult: Sendable {
        case found(ThirdPartyEventReadMessage)
        case expired
        case ambiguous
        case absent
    }

    /// `agent-event:<id8 | uuid>`: only ever resolves rows the acting agent owns,
    /// so "not yours" and "does not exist" take the same path.
    public func readThirdPartyAgentEventForAgent(agentId: String, ref rawRef: String) -> ThirdPartyEventReadResult {
        let ref = rawRef.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isFull = ref.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) != nil
        let isShort = ref.wholeMatch(of: /^[0-9a-f]{8}$/) != nil
        guard isFull || isShort else { return .absent }
        let matches = self.state.withLock { ledgerState in
            ledgerState.agentEvents
                .filter { $0.agentId == agentId && (isFull ? $0.id == ref : $0.id.hasPrefix(ref)) }
                .sorted { $0.createdAt < $1.createdAt }
        }
        if matches.isEmpty { return .absent }
        if matches.count > 1 { return .ambiguous }
        let event = matches[0]
        if event.status == "expired" || event.expiresAt <= Date() {
            return .expired
        }
        let client = self.state.withLock { ledgerState in
            ledgerState.clients.first(where: { $0.id == event.clientId })
        }
        let clientKey = client?.clientId ?? ""
        let clientName = client?.name ?? ""
        let content = [
            "Third-party \(event.kind): \(event.summary)",
            "",
            "event_id: \(event.id)",
            "payload_hash: \(event.payloadHash)",
            "resource: urn:raft:server:\(event.serverId):agent-inbound",
        ].joined(separator: "\n")
        return .found(ThirdPartyEventReadMessage(
            id: event.id,
            kind: event.kind,
            summary: event.summary,
            content: content,
            clientKey: clientKey,
            clientName: clientName,
            externalEventId: event.externalEventId,
            payloadHash: event.payloadHash,
            payloadJSON: event.payloadJSON,
            createdAt: event.createdAt,
            expiresAt: event.expiresAt
        ))
    }

    public static let agentAppEventRetentionAfterExpiryMs = 30 * 24 * 60 * 60 * 1000

    public enum AgentAppEventListOutcome: Sendable {
        case events(rows: [AgentAppEventSummary], nextCursor: String?)
        case forbidden
        case notFound
        case invalidLimit
        case invalidCursor
    }

    public struct AgentAppEventSummary: Sendable, Equatable {
        public var id: String
        public var kind: String
        public var summary: String
        public var status: String
        public var createdAt: Date
        public var expiresAt: Date
        public var deliveredAt: Date?
        public var externalEventId: String?
        public var clientKey: String
        public var clientName: String
        public var payloadJSON: String
    }

    func appEventDisplayStatusLocked(_ event: AgentEvent, now: Date, state ledgerState: State) -> String {
        if event.status == "delivered" { return "delivered" }
        if event.status == "expired" || event.status == "rejected" { return "expired" }
        return event.expiresAt <= now ? "expired" : "queued"
    }

    func appEventCursorLocked(_ event: AgentEvent, state ledgerState: State) -> String {
        "\(Int(event.createdAt.timeIntervalSince1970 * 1000)).\(event.id)"
    }

    func parseAppEventCursorLocked(_ raw: String, state ledgerState: State) -> (createdAt: Int, id: String)? {
        let parts = raw.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let millis = Int(parts[0]) else { return nil }
        return (millis, parts[1])
    }

    public func agentAppEvents(userId: String, agentId: String, limit: Int, before: String?) -> AgentAppEventListOutcome {
        return self.state.withLock { ledgerState in
            guard let agent = ledgerState.agents[agentId], !agent.deleted else { return .notFound }
            guard isAgentAuthorityLocked(userId: userId, agent: agent, serverId: agent.serverId, state: ledgerState) else { return .forbidden }
            guard limit > 0, limit <= 100 else { return .invalidLimit }
            var cursor: (createdAt: Int, id: String)?
            if let before, !before.isEmpty {
                guard let parsed = parseAppEventCursorLocked(before, state: ledgerState) else { return .invalidCursor }
                cursor = parsed
            }
            let now = Date()
            var rows = ledgerState.agentEvents.filter { $0.agentId == agentId }
            if let cursor {
                rows = rows.filter { event in
                    let millis = Int(event.createdAt.timeIntervalSince1970 * 1000)
                    return millis < cursor.createdAt || (millis == cursor.createdAt && event.id < cursor.id)
                }
            }
            rows.sort { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id > rhs.id
            }
            let page = Array(rows.prefix(limit))
            let summaries = page.map { event -> AgentAppEventSummary in
                let client = ledgerState.clients.first(where: { $0.id == event.clientId })
                return AgentAppEventSummary(
                    id: event.id, kind: event.kind, summary: event.summary,
                    status: appEventDisplayStatusLocked(event, now: now, state: ledgerState),
                    createdAt: event.createdAt, expiresAt: event.expiresAt,
                    deliveredAt: event.deliveredAt, externalEventId: event.externalEventId,
                    clientKey: client?.clientId ?? "", clientName: client?.name ?? "",
                    payloadJSON: event.payloadJSON
                )
            }
            let next = rows.count > limit ? page.last.map { appEventCursorLocked($0, state: ledgerState) } : nil
            return .events(rows: summaries, nextCursor: next)
        }
    }

    public enum AgentAppEventDetailOutcome: Sendable {
        case event(AgentAppEventSummary)
        case forbidden
        case notFound
    }

    public func agentAppEventDetail(userId: String, agentId: String, eventId: String) -> AgentAppEventDetailOutcome {
        return self.state.withLock { ledgerState in
            guard let agent = ledgerState.agents[agentId], !agent.deleted else { return .notFound }
            guard isAgentAuthorityLocked(userId: userId, agent: agent, serverId: agent.serverId, state: ledgerState) else { return .forbidden }
            guard let event = ledgerState.agentEvents.first(where: { $0.id == eventId && $0.agentId == agentId }) else {
                return .notFound
            }
            let client = ledgerState.clients.first(where: { $0.id == event.clientId })
            let now = Date()
            return .event(AgentAppEventSummary(
                id: event.id, kind: event.kind, summary: event.summary,
                status: appEventDisplayStatusLocked(event, now: now, state: ledgerState),
                createdAt: event.createdAt, expiresAt: event.expiresAt,
                deliveredAt: event.deliveredAt, externalEventId: event.externalEventId,
                clientKey: client?.clientId ?? "", clientName: client?.name ?? "",
                payloadJSON: event.payloadJSON
            ))
        }
    }

    /// Deletes events whose expiry is past the retention window. Bounded by
    /// `batchSize`; callers may repeat until it returns 0.
    @discardableResult
    public func pruneExpiredAgentAppEvents(now: Date = Date(), batchSize: Int = 1000) -> Int {
        return self.state.withLock { ledgerState in
            let cutoff = now.addingTimeInterval(-Double(Self.agentAppEventRetentionAfterExpiryMs) / 1000)
            var candidates = ledgerState.agentEvents.indices.filter { ledgerState.agentEvents[$0].expiresAt <= cutoff }
            candidates.sort { ledgerState.agentEvents[$0].expiresAt < ledgerState.agentEvents[$1].expiresAt }
            let removing = Set(candidates.prefix(max(1, batchSize)))
            ledgerState.agentEvents = ledgerState.agentEvents.enumerated().filter { !removing.contains($0.offset) }.map(\.element)
            return removing.count
        }
    }

    public func pendingThirdPartyEventMessages(agentId: String) -> [ThirdPartyEventMessage] {
        return self.state.withLock { ledgerState in
            return ledgerState.agentEvents
                .filter { $0.agentId == agentId && $0.status == "delivering" && $0.expiresAt > Date() }
                .map { projectionLocked($0, state: ledgerState) }
        }
    }

    public func takeThirdPartyEventMessages(agentId: String) -> [ThirdPartyEventMessage] {
        return self.state.withLock { ledgerState in
            let now = Date()
            var messages: [ThirdPartyEventMessage] = []
            for index in ledgerState.agentEvents.indices where
                ledgerState.agentEvents[index].agentId == agentId
                    && ledgerState.agentEvents[index].status == "delivering"
                    && ledgerState.agentEvents[index].expiresAt > now {
                messages.append(projectionLocked(ledgerState.agentEvents[index], state: ledgerState))
                ledgerState.agentEvents[index].status = "delivered"
                ledgerState.agentEvents[index].deliveredAt = now
            }
            return messages
        }
    }

    public func markThirdPartyEventsDelivered(agentId: String, ids: [String]) -> Int {
        let wanted = Set(ids.map { $0.lowercased() })
        guard !wanted.isEmpty else { return 0 }
        return self.state.withLock { ledgerState in
            let now = Date()
            var delivered = 0
            for index in ledgerState.agentEvents.indices where
                ledgerState.agentEvents[index].agentId == agentId
                    && wanted.contains(ledgerState.agentEvents[index].id)
                    && ledgerState.agentEvents[index].status != "delivered" {
                ledgerState.agentEvents[index].status = "delivered"
                ledgerState.agentEvents[index].deliveredAt = now
                delivered += 1
            }
            return delivered
        }
    }

    func projectionLocked(_ event: AgentEvent, state ledgerState: State) -> ThirdPartyEventMessage {
        let client = ledgerState.clients.first(where: { $0.id == event.clientId })
        return ThirdPartyEventMessage(
            id: event.id,
            serverId: event.serverId,
            clientKey: client?.clientId ?? "",
            clientName: client?.name ?? "",
            clientRecordId: event.clientId,
            kind: event.kind,
            summary: event.summary
        )
    }

    func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
