import Foundation

/// Shared machine read authority for byte and URL routes. The authority channel
/// comes from the stored message (or its unlinked draft), never a request hint.
/// This query reads one checked-store snapshot and does not create principals.
struct AttachmentMachineReadAccessQuery: Sendable {
    let channels: ServersAndChannelsStore

    func canRead(authorityChannelId: String, serverId: String, messageLinked: Bool) -> Bool {
        let state = channels.state
        guard let source = state.postableChannels[authorityChannelId], source.deletedAt == nil else { return false }
        // Preserve ordinary same-server access without requiring joint links.
        if source.serverId == serverId { return true }
        guard messageLinked else { return false }

        let localLinks = state.jointProjections.filter { $0.localChannelId == authorityChannelId }
        let canonicalId: String
        if !localLinks.isEmpty {
            // A known local source cannot be retried as a canonical ID when its
            // mapping is inactive, inconsistent, or ambiguous.
            let active = localLinks.filter { $0.status == "active" }
            guard active.count == 1, let link = active.first,
                  link.serverId == source.serverId else { return false }
            canonicalId = link.canonicalChannelId
        } else {
            // The message can already name canonical storage. Establish that
            // identity from live stored projection facts, not from ID spelling.
            let canonicalLinks = state.jointProjections.filter {
                $0.canonicalChannelId == authorityChannelId && $0.status == "active"
            }
            let candidates = Set(canonicalLinks.map(\.canonicalChannelId))
            guard candidates.count == 1, let storedId = candidates.first else { return false }
            canonicalId = storedId
        }
        guard let canonical = state.postableChannels[canonicalId], canonical.deletedAt == nil else { return false }

        let targets = state.jointProjections.filter {
            $0.canonicalChannelId == canonicalId && $0.serverId == serverId && $0.status == "active"
        }
        guard targets.count == 1, let target = targets.first,
              let local = state.postableChannels[target.localChannelId],
              local.serverId == serverId, local.deletedAt == nil else { return false }
        return true
    }
}
