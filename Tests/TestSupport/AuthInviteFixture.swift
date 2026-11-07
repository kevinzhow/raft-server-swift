import Foundation
@testable import RaftHTTP

/// Only the channel-invite and OAuth rows needed by the focused auth scene.
public struct AuthInviteFixture: Sendable {
    private let channels: ServersAndChannelsStore
    private let oauth: OAuthLedger

    init(channels: ServersAndChannelsStore, oauth: OAuthLedger) {
        self.channels = channels
        self.oauth = oauth
    }

    public func addOwnedServer(id: String, slug: String, name: String, ownerId: String) {
        oauth.addOwnedServer(id: id, slug: slug, name: name, ownerId: ownerId)
    }

    public func seedEmailInvite(
        id: String, serverId: String, email: String, role: String, token: String
    ) {
        channels.insertServerInvite(id: id, serverId: serverId, email: AccountNaming.normalize(email), role: role)
        channels.setInviteTokenHash(id: id, tokenHash: AuthTokenCodec.sha256(token))
    }

    public func memberRole(serverId: String, userId: String) -> String? {
        oauth.memberRole(serverId: serverId, userId: userId)
    }

    public func inviteCount(serverId: String) -> Int {
        channels.serverInviteRows(serverId: serverId).count
    }
}
