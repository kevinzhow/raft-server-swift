import Crypto
import Foundation
import RaftShared

/// The agent-API idempotency ledger behind `POST /internal/agent-api/tasks`.
///
/// The ledger rows live in `ManagedMCPAndCardsStore`, keyed by
/// `(agent, route, idempotencyKey)`. This type owns the request-side rules the
/// retired directory closures held: the key is the trimmed `idempotencyKey`
/// string of the raw JSON object (absent or blank means no idempotency), and the
/// fingerprint is the SHA-256 of the canonical request.
enum ActionCardTaskIdempotencyLedger {
    /// The published 409 body for a key reused by a different request.
    static let conflictBody = OrderedJSON.object([
        OrderedJSONField("error", "This idempotencyKey was already used for a different request"),
        OrderedJSONField("code", "idempotency_key_reused"),
        OrderedJSONField("mismatch", "request"),
        OrderedJSONField("suggestedNextAction", "Retry with a new idempotencyKey."),
    ]).render()

    static func port(
        cards: ManagedMCPAndCardsStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ActionCardTaskIdempotency {
        ActionCardTaskIdempotency(
            lookup: { agentId, route, rawBody in
                guard let request = Request(rawBody: rawBody) else { return .miss }
                switch cards.agentApiIdempotencyLookup(
                    agentId: agentId,
                    route: route,
                    key: request.key,
                    fingerprint: request.fingerprint,
                    now: now()
                ) {
                case .none:
                    return .miss
                case .replay(_, let body):
                    return .replay(body: body)
                case .mismatch:
                    return .conflict(body: conflictBody)
                }
            },
            store: { agentId, route, rawBody, body in
                guard let request = Request(rawBody: rawBody) else { return }
                cards.storeAgentApiIdempotency(
                    agentId: agentId,
                    route: route,
                    key: request.key,
                    fingerprint: request.fingerprint,
                    status: 200,
                    body: body,
                    now: now()
                )
            }
        )
    }

    /// The parsed idempotency identity of one raw request body.
    struct Request {
        let key: String
        let fingerprint: String

        init?(rawBody: String) {
            guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: Data(rawBody.utf8)),
                  case .string(let rawKey)? = object["idempotencyKey"]
            else { return nil }
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            self.key = key
            self.fingerprint = Self.fingerprint(of: .object(object))
        }

        /// SHA-256 of the canonical sorted-key request: `idempotencyKey` members,
        /// `false`/`0` members and `null` members are dropped from every object
        /// (arrays keep their elements), as the legacy canonicalization did.
        static func fingerprint(of value: JSONValue) -> String {
            let text = LegacySortedJSON.render(canonical(value)) ?? ""
            return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        private static func canonical(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(let members):
                var result: [String: JSONValue] = [:]
                for (key, child) in members {
                    if key == "idempotencyKey" { continue }
                    switch child {
                    case .null, .bool(false): continue
                    case .integer(0): continue
                    case .number(let number) where number == 0: continue
                    default: result[key] = canonical(child)
                    }
                }
                return .object(result)
            case .array(let values):
                return .array(values.map(canonical))
            default:
                return value
            }
        }
    }
}
