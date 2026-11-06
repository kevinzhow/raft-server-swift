import Foundation

/// The hosted runtime provider's connection payloads, read leniently.
///
/// The provider answers with free-form JSON; each reader keeps the legacy
/// per-member casts (`as? String`, `as? Bool`) so a member of the wrong type
/// reads as absent instead of failing the whole reply. These readers moved out
/// of the directory statics unchanged; the service never touches the untyped
/// tree.
enum AgentConnectionProviderPayload {
    static let identifierPattern = "^[A-Za-z0-9_.~-]{1,200}$"

    static func isIdentifier(_ value: String) -> Bool {
        value.range(of: identifierPattern, options: .regularExpression) != nil
    }

    static func parseConnectionStatus(_ body: String) -> HostedConnectionStatusRecord? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return nil
        }
        let connected = object["connected"] as? Bool ?? false
        var connectors: [HostedConnectionConnectorRecord] = []
        if let raw = object["connectors"] as? [Any] {
            for entry in raw {
                guard let row = entry as? [String: Any],
                      let id = row["id"] as? String,
                      isIdentifier(id)
                else { continue }
                connectors.append(HostedConnectionConnectorRecord(
                    id: id,
                    account: row["account"] as? String ?? "",
                    creatorRaftUserId: row["creatorRaftUserId"] as? String,
                    createdAt: row["createdAt"] as? String,
                    current: row["current"] as? Bool ?? false
                ))
                if connectors.count >= 100 { break }
            }
        }
        let rawConnectorId = object["connectorId"] as? String
        let connectorId = connected ? rawConnectorId.flatMap { isIdentifier($0) ? $0 : nil } : nil
        return HostedConnectionStatusRecord(
            connected: connected,
            account: object["account"] as? String,
            connectedAt: object["connectedAt"] as? String,
            connectedBy: object["connectedBy"] as? String,
            scopes: (object["scopes"] as? [Any])?.compactMap { $0 as? String } ?? [],
            connectorId: connectorId,
            connectors: connectors
        )
    }

    static func providerErrorParts(_ body: String) -> (code: String?, message: String?) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else {
            return (nil, nil)
        }
        return (error["code"] as? String, error["message"] as? String)
    }

    /// The provider's connect-start answer: an http(s) `url`, an optional
    /// `expiresAt` and the granted `scopes`. `nil` when the url is missing or
    /// not an http(s) URL.
    static func parseConnectionStart(_ body: String) -> (url: String, expiresAt: String?, scopes: [String])? {
        guard let parsed = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let url = parsed["url"] as? String,
              let parsedURL = URL(string: url),
              parsedURL.scheme == "http" || parsedURL.scheme == "https"
        else { return nil }
        return (
            parsedURL.absoluteString,
            parsed["expiresAt"] as? String,
            ((parsed["scopes"] as? [Any])?.compactMap { $0 as? String }) ?? []
        )
    }

    /// How many connectors a partial disconnect left behind.
    static func failedConnectorCount(_ body: String) -> Int {
        let failed = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        return (failed?["failed"] as? [Any])?.count ?? 0
    }
}
