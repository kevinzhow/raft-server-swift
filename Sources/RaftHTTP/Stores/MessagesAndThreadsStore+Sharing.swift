import Foundation

extension MessagesAndThreadsStore {
    // MARK: - System attention and share artifacts

    /// One recipient's active, not-dismissed attention incidents in the archive
    /// order (newest activation first), with the receipt timestamps from the
    /// same locked snapshot.
    struct SystemAttentionNotificationRow: Sendable {
        let incident: SystemAttentionIncident
        let seenAt: Date?
    }

    func systemAttentionNotifications(
        serverId: String,
        userId: String
    ) -> [SystemAttentionNotificationRow] {
        withState { state in
            return state.systemAttentionIncidents
                .filter { $0.serverId == serverId && $0.state == "active" }
                .compactMap { incident -> SystemAttentionNotificationRow? in
                    let receipt = state.systemAttentionReceipts["\(incident.id)\n\(userId)"]
                    guard receipt?.dismissedAt == nil else { return nil }
                    return SystemAttentionNotificationRow(incident: incident, seenAt: receipt?.seenAt)
                }
                .sorted { $0.incident.activatedAt > $1.incident.activatedAt }
        }
    }

    /// Decides and writes one recipient receipt in a single critical section.
    ///
    /// The enabled flag, the active-incident lookup and the receipt update all
    /// happen here, so two concurrent marks cannot both observe "not seen" and
    /// let a dismissal race a fresh seen-at. Returns `false` when the feed is
    /// disabled or the incident is not an active row of `serverId`.
    func recordSystemAttentionReceipt(
        serverId: String,
        incidentId: String,
        userId: String,
        attentionEnabled: Bool,
        dismiss: Bool,
        now: Date
    ) -> Bool {
        withState { state in
            guard attentionEnabled,
                  state.systemAttentionIncidents.contains(where: {
                      $0.id == incidentId && $0.serverId == serverId && $0.state == "active"
                  })
            else { return false }
            let key = "\(incidentId)\n\(userId)"
            var receipt = state.systemAttentionReceipts[key]
                ?? SystemAttentionReceipt(seenAt: nil, dismissedAt: nil)
            if receipt.seenAt == nil { receipt.seenAt = now }
            if dismiss { receipt.dismissedAt = now }
            state.systemAttentionReceipts[key] = receipt
            return true
        }
    }

    /// Stores one uploaded share artifact under the store lock. The id was
    /// already unique, so this is a single insert with no read first.
    func insertShareArtifact(
        id: String,
        bytes: Data,
        width: Int,
        height: Int,
        serverId: String,
        createdAt: Date
    ) {
        withState { state in
            state.shareArtifacts[id] = ShareArtifactRecord(
                bytes: bytes,
                width: width,
                height: height,
                serverId: serverId,
                createdAt: createdAt
            )
        }
    }

    // MARK: - Share artifacts and message translations

    /// One uploaded share artifact, or nil when no row carries the id.
    func shareArtifact(id: String) -> ShareArtifactRecord? {
        withState { state in
            return state.shareArtifacts[id]
        }
    }

    /// Records the translation outcome for one message in a single critical
    /// section, so a concurrent batch cannot interleave a half-written row.
    func recordMessageTranslation(
        messageId: String,
        status: String,
        providerBilledChars: Int,
        targetLanguage: String,
        translatedContent: String
    ) {
        withState { state in
            state.messageTranslationLedger[messageId] = (
                status: status,
                providerBilledChars: providerBilledChars,
                targetLanguage: targetLanguage,
                translatedContent: translatedContent
            )
        }
    }
}
