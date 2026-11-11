import Foundation

/// The integration-logo mutations shared by `POST`/`DELETE
/// /api/integrations/clients/:clientId/logo` and the public logo route.
///
/// The ledger stores only the capability URL and the storage key. Image bytes
/// live in the encrypted public-asset store.
extension OAuthLedger {
    /// A user-managed App of `serverId` addressed by record id or client key.
    /// Cross-server and built-in clients are deliberately invisible.
    func userManagedClientRecordId(serverId: String, clientKey: String) -> String? {
        state.withLock { ledgerState in
            ledgerState.clients.first {
                $0.serverId == serverId
                    && ($0.id == clientKey || $0.clientId == clientKey)
                    && isUserManaged($0)
            }?.id
        }
    }

    /// The storage key when it belongs to the requested App and content hash.
    /// A stale hash for the same App does not authorize the old object.
    func clientLogoStorageKey(clientRecordId: String, contentHash: String) -> String? {
        state.withLock { ledgerState in
            guard let client = ledgerState.clients.first(where: { $0.id == clientRecordId }),
                  isUserManaged(client),
                  let key = client.logoStorageKey,
                  key.hasSuffix("/\(contentHash).webp")
            else { return nil }
            return key
        }
    }

    func setClientLogo(clientRecordId: String, logoUrl: String, logoStorageKey: String) {
        state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) else { return }
            ledgerState.clients[index].logoUrl = logoUrl
            ledgerState.clients[index].logoStorageKey = logoStorageKey
        }
    }

    /// Clear both fields and return the previous key so the caller can delete
    /// the object best-effort after the row transaction.
    func clearClientLogo(clientRecordId: String) -> String? {
        state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) else { return nil }
            let previous = ledgerState.clients[index].logoStorageKey
            ledgerState.clients[index].logoUrl = nil
            ledgerState.clients[index].logoStorageKey = nil
            return previous
        }
    }

    /// The same public projection `GET /api/integrations/clients` publishes,
    /// used by the logo upload and clear responses.
    func integrationSettingsClient(clientRecordId: String) -> IntegrationSettingsClient? {
        state.withLock { ledgerState in
            guard let client = ledgerState.clients.first(where: { $0.id == clientRecordId }),
                  isUserManaged(client)
            else { return nil }
            return IntegrationSettingsClient(
                id: client.id,
                clientId: client.clientId,
                name: client.name,
                appType: client.appType,
                description: client.descriptionText,
                homepageUrl: client.homepageUrl,
                publishStatus: client.publishStatus,
                logoUrl: client.logoUrl
            )
        }
    }
}
