import Foundation

/// A role-change notice prepares its existing DM surface through the owning
/// stores, then enters the common system-notice commit.
///
/// Upstream `agentServerRoleNoticeService` posts through
/// `messageService.broadcastSystemMessage`, so the retained row is a
/// system-sender `system` message in the actor/agent DM and the frontend sees
/// `message:new` plus `dm:new`. Channels enters only OAuth while preparing the
/// DM; it releases that borrow before Messages -> OAuth.
struct AgentRoleNoticeService: Sendable {
    let profiles: AuthProfileStore
    let channels: ServersAndChannelsStore
    let oauth: OAuthLedger
    let notices: SystemNoticeAppender

    func post(serverId: String, actorUserId: String, agentId: String, agentName: String, from: String, to: String) {
        let actorName = profiles.account(userId: actorUserId)?.name ?? "Someone"
        let dmId = channels.prepareRoleNoticeDirectChannel(
            serverId: serverId,
            actorUserId: actorUserId,
            agentId: agentId,
            ledger: RoleNoticeLedgerPort(oauth: oauth)
        )
        notices.append(StoredHumanMessage(
            id: UUID().uuidString.lowercased(),
            channelId: dmId,
            senderId: "system",
            content: "@\(actorName) changed @\(agentName)'s server role from \(from) to \(to).",
            messageType: "system",
            senderType: "system",
            actionKind: "agent.server_role_changed",
            systemSubtype: "agent.server_role_changed",
            causalActorType: "user",
            causalActorId: actorUserId
        ), nil)
    }
}
