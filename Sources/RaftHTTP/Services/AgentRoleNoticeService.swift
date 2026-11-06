import Foundation

/// A role-change notice prepares its existing DM surface through the owning
/// stores, then enters the common message commit. Channels enters only OAuth
/// while preparing the DM; it releases that borrow before Messages -> OAuth.
struct AgentRoleNoticeService: Sendable {
    let profiles: AuthProfileStore
    let channels: ServersAndChannelsStore
    let messages: MessagesAndThreadsStore
    let oauth: OAuthLedger

    func post(serverId: String, actorUserId: String, agentId: String, agentName: String, from: String, to: String) {
        let actorName = profiles.account(userId: actorUserId)?.name ?? "Someone"
        let dmId = channels.prepareRoleNoticeDirectChannel(
            serverId: serverId,
            actorUserId: actorUserId,
            agentId: agentId,
            ledger: RoleNoticeLedgerPort(oauth: oauth)
        )
        messages.appendMessage(StoredHumanMessage(
            id: UUID().uuidString.lowercased(),
            channelId: dmId,
            senderId: actorUserId,
            content: "@\(actorName) changed @\(agentName)'s server role from \(from) to \(to).",
            messageType: "system",
            senderType: "user",
            actionKind: "agent.server_role_changed"
        ), ledger: MessageLedgerPort(oauth: oauth))
    }
}
