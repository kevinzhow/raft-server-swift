/// Pinned packages/shared/src/serverPermissions.ts:13-119. Presentation facts
/// are action-specific and do not replace channel or principal authorization.
enum ServerRoleCapabilities {
    private static let keys = [
        "viewChannel", "createChannels", "editChannelMetadata", "archiveChannels", "deleteChannels",
        "changeChannelVisibility", "manageGuestAccess", "federateChannels", "viewChannelMembers",
        "joinPublicChannels", "addChannelMembers", "removeChannelMembers", "changeChannelMemberRoles",
        "viewMembers", "inviteMembers", "removeMembers", "changeMemberRoles", "viewServerProfile",
        "viewServerSettings", "editServerSettings", "manageIntegrations", "manageExternalAuth",
        "rotateServerSecrets", "viewAgents", "createAgents", "editAgents", "controlAgentRuntime",
        "resetAgentWorkspace", "deleteAgents", "migrateAgents", "issueAgentCredentials", "viewMachines",
        "registerMachines", "editMachines", "controlComputers", "removeMachines", "rotateMachineKeys",
        "assignTasks", "deleteAnyTask", "viewBilling", "manageBilling",
    ]
    private static let member: Set<String> = [
        "viewServerProfile", "viewChannel", "createChannels", "viewChannelMembers", "joinPublicChannels",
        "addChannelMembers", "viewMembers", "viewAgents", "controlAgentRuntime", "viewMachines", "assignTasks",
    ]

    static func allows(_ key: String, role: String?) -> Bool {
        role == "owner" || (role == "admin" && key != "manageBilling")
            || (role == "member" && member.contains(key))
    }

    static func json(role: String?) -> OrderedJSON {
        .object(keys.map { OrderedJSONField($0, allows($0, role: role)) })
    }
}
