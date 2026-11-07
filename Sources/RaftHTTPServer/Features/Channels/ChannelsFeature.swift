import Foundation
import HTTPTypes
import RaftHTTP
import RaftRealtime
import Vapor

/// `/api/channels/...` route surface extracted from `FallbackApplication.configure`.
///
/// Every registration below is copied verbatim from the inline `configure`
/// block: same method, path, header projection, body handling and
/// `routeResponse` call. The owned surface is the `api/channels` family —
/// 53 method/path pairs, including channel CRUD, inbox and read state,
/// threads and followers, DM creation, saved messages, members and
/// notification settings.
///
/// This collection is not mounted by `FallbackApplication` yet; the composition
/// root decides when it is live. `boot` delegates to the same synchronous
/// `register(routes:)` used by `configure` for non-async mounts.
public struct ChannelsFeature: RouteCollection, Sendable {
    private let threads: ThreadsService
    private let reactions: ReactionsRealtimeService
    private let inbox: InboxAndWakeService
    private let assignments: ManagedMCPAssignmentsService
    private let readState: ManagedMCPToolExecutionService
    private let membership: ChannelMembershipService
    private let search: SearchMentionsService
    private let send: MessageSendService
    private let reminders: ManagedMCPAgentCatalogService
    private let oauth: ManagedMCPOAuthService
    private let lifecycle: ManagedMCPLifecycleService
    private let agentsLifecycle: AgentsLifecycleService
    private let socketMembership: SocketMembershipService
    private let channelRoutes: ManagedMCPChannelRoutesService
    private let channelMessaging: ChannelMessagingService
    private let realtime: RealtimeHub?

    public init(
        threads: ThreadsService,
        reactions: ReactionsRealtimeService,
        inbox: InboxAndWakeService,
        assignments: ManagedMCPAssignmentsService,
        readState: ManagedMCPToolExecutionService,
        membership: ChannelMembershipService,
        search: SearchMentionsService,
        send: MessageSendService,
        reminders: ManagedMCPAgentCatalogService,
        oauth: ManagedMCPOAuthService,
        lifecycle: ManagedMCPLifecycleService,
        agentsLifecycle: AgentsLifecycleService,
        socketMembership: SocketMembershipService,
        channelRoutes: ManagedMCPChannelRoutesService,
        channelMessaging: ChannelMessagingService,
        realtime: RealtimeHub?
    ) {
        self.threads = threads
        self.reactions = reactions
        self.inbox = inbox
        self.assignments = assignments
        self.readState = readState
        self.membership = membership
        self.search = search
        self.send = send
        self.reminders = reminders
        self.oauth = oauth
        self.lifecycle = lifecycle
        self.agentsLifecycle = agentsLifecycle
        self.socketMembership = socketMembership
        self.channelRoutes = channelRoutes
        self.channelMessaging = channelMessaging
        self.realtime = realtime
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    /// Synchronous mount for `configure`, whose call sites are not `async`.
    public func register(routes: any RoutesBuilder) {
        let channels = routes.grouped("api", "channels")
        channels.post(":channelId", "archive") { request async throws -> Response in
            try await respond {
                try membership.setChannelArchived(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    archived: true
                )
            }
        }

        channels.post(":channelId", "unarchive") { request async throws -> Response in
            try await respond {
                try membership.setChannelArchived(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    archived: false
                )
            }
        }

        channels.post(":channelId", "join") { request async throws -> Response in
            try await respond {
                try membership.joinChannel(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? ""
                )
            }
        }

        channels.post("inbox", "done") { request async throws -> Response in
            let body = await jsonRequestBody(InboxScopeRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try reactions.channelInboxDone(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                    body: body
                )
            }
        }

        channels.post("inbox", "read-all") { request async throws -> Response in
            try await respond {
                try reactions.inboxReadAll(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }

        channels.get("inbox", "done") { request async throws -> Response in
            try await respond {
                try inbox.doneInbox(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                    query: request.url.query
                )
            }
        }

        channels.post("inbox", "undone") { request async throws -> Response in
            let body = await jsonRequestBody(InboxScopeRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try reactions.inboxUndone(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                    body: body
                )
            }
        }

        channels.post("threads", "undone") { request async throws -> Response in
            let body = await jsonRequestBody(InboxScopeRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try reactions.threadInboxUndone(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                    body: body
                )
            }
        }

        channels.post("threads", "done") { request async throws -> Response in
            let body = await jsonRequestBody(InboxScopeRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try reactions.threadInboxDone(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                    body: body
                )
            }
        }

        channels.get("inbox", "unfollowed") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try threads.unfollowedInbox(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    limit: desktopQuery(request.url.query, "limit"),
                    query: desktopQuery(request.url.query, "q")
                )
            }
        }

        channels.get("inbox") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try reactions.channelInbox(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                    filter: desktopQuery(request.url.query, "filter"),
                    query: request.url.query
                )
            }
        }

        channels.delete(":channelId") { request async throws -> Response in
            try await respond {
                try search.deleteChannel(
                    channelId: request.parameters.get("channelId") ?? "",
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }

        channels.delete("threads", ":threadId", "followers", "agents", ":agentId") { request async throws -> Response in
            try await respond {
                try send.removeThreadFollower(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    threadId: request.parameters.get("threadId") ?? "",
                    agentId: request.parameters.get("agentId") ?? ""
                )
            }
        }

        channels.post("threads", ":threadId", "followers", "agents", ":agentId", "restore") { request async throws -> Response in
            // The legacy handler parsed the raw body, so a missing or non-JSON
            // body is the empty token, not a 400.
            let restore = (try? await decodeJSONRequestBody(
                RestoreThreadFollowerRequest.self, request, decoding: .json, emptyDefault: "{}"
            )) ?? RestoreThreadFollowerRequest()
            return try await respond {
                try send.restoreThreadFollower(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    threadId: request.parameters.get("threadId") ?? "",
                    agentId: request.parameters.get("agentId") ?? "",
                    undoToken: restore.undoToken
                )
            }
        }

        channels.get("threads", "followers") { request async throws -> Response in
            try await respond {
                try threads.threadFollowerRoster(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    threadChannelIds: desktopQuery(request.url.query, "threadChannelIds")
                )
            }
        }

        channels.post("threads", "follow") { request async throws -> Response in
            let body = await threadFollowMutation(request)
            return try await respond {
                try threads.setThreadFollow(
                    body,
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    follow: true
                )
            }
        }

        channels.post("threads", "unfollow") { request async throws -> Response in
            let body = await threadFollowMutation(request)
            return try await respond {
                try threads.setThreadFollow(
                    body,
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    follow: false
                )
            }
        }

        channels.get("threads", "followed") { request async throws -> Response in
            try await respond {
                try threads.followedThreads(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    limit: desktopQuery(request.url.query, "limit"),
                    cursor: desktopQuery(request.url.query, "cursor"),
                    unreadOnly: desktopQuery(request.url.query, "unreadOnly")
                )
            }
        }

        channels.get(":channelId", "threads", ":messageId") { request async throws -> Response in
            try await respond {
                try threads.threadInfo(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    messageId: request.parameters.get("messageId") ?? ""
                )
            }
        }

        channels.get(":channelId", "threads") { request async throws -> Response in
            try await respond {
                try threads.channelThreadSummaries(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                    channelId: request.parameters.get("channelId") ?? "",
                    parentMessageIds: desktopQuery(request.url.query, "parentMessageIds")
                )
            }
        }

        channels.get("activity", "snapshot") { _ -> Response in
            routeResponse(activityContractRejection)
        }

        channels.get("activity", "difference") { _ -> Response in
            routeResponse(activityContractRejection)
        }

        channels.post("saved", "check") { request async throws -> Response in
            let body = await jsonRequestBody(SavedCheckRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try readState.checkSavedMessages(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
            }
        }

        channels.post("saved") { request async throws -> Response in
            let body = await jsonRequestBody(SaveChannelMessageRequest.self, request)
            return try await respond {
                try reminders.saveChannelMessage(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
            }
        }

        channels.get("saved") { request async throws -> Response in
            try await respond {
                try readState.listSavedMessages(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    query: desktopQuery(request.url.query, "q"),
                    channelId: desktopQuery(request.url.query, "channelId"),
                    sort: desktopQuery(request.url.query, "sort"),
                    limit: Int(desktopQuery(request.url.query, "limit") ?? "") ?? 50,
                    offset: Int(desktopQuery(request.url.query, "offset") ?? "") ?? 0
                )
            }
        }

        channels.post("system", "all", "hide") { request async throws -> Response in
            try await respond {
                try readState.setAllChannelVisibility(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    visible: false
                )
            }
        }

        channels.post("system", "all", "restore") { request async throws -> Response in
            try await respond {
                try readState.setAllChannelVisibility(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    visible: true
                )
            }
        }

        channels.post("dm") { request async throws -> Response in
            // The peer is named by `agentId` or `userId`; a body that is not a
            // JSON object (or names neither) is the published `Invalid DM peer`.
            let body = await jsonRequestBody(DirectChannelRequest.self, request)
            return try await respond {
                try readState.createDirectChannel(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
            }
        }

        channels.get("dm") { request async throws -> Response in
            try await respond {
                try readState.listDirectChannels(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        channels.get(":channelId") { request async throws -> Response in
            try await respond {
                try readState.channelDetail(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? ""
                )
            }
        }

        channels.post(":channelId", "resume-all-agents") { request async throws -> Response in
            // A blank body is an empty request; a body that is not a JSON object
            // stays `nil` for the published `Invalid resume request`.
            let resolved = try await decodeJSONRequestBody(
                ResumeAllAgentsRequest.self, request, emptyDefault: "{}", blankDefault: "{}"
            )
            return try await respond {
                try await readState.resumeAllAgents(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    body: resolved
                )
            }
        }

        channels.post(":channelId", "read") { request async throws -> Response in
            let body = await jsonRequestBody(ChannelReadRequest.self, request)
            return try await respond {
                try readState.updateChannelReadState(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body
                )
            }
        }

        channels.post(":channelId", "read-all") { request async throws -> Response in
            // A body that is not a JSON object carries no receiver.
            let body = await jsonRequestBody(ChannelReadAllRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try readState.markChannelReadAll(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body
                )
            }
        }

        channels.post(":channelId", "unread") { request async throws -> Response in
            try await respond {
                try oauth.markChannelUnread(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? ""
                )
            }
        }

        channels.get("unread") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try oauth.channelUnread(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    summary: desktopQuery(request.url.query, "summary") == "1"
                )
            }
        }

        channels.get(":channelId", "message-display-settings") { request async throws -> Response in
            try await respond {
                try readState.channelDisplaySettings(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? ""
                )
            }
        }

        channels.post(":channelId", "conversation-read-all") { request async throws -> Response in
            try await respond {
                try lifecycle.conversationReadAll(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? ""
                )
            }
        }

        channels.patch(":channelId", "message-display-settings") { request async throws -> Response in
            let body = await jsonRequestBody(ChannelDisplayPatchRequest.self, request)
            return try await respond {
                try readState.patchChannelDisplaySettings(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body
                )
            }
        }

        channels.post(":channelId", "leave") { request async throws -> Response in
            let authorization = request.headers[.authorization]
            let serverId = request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            let channelId = request.parameters.get("channelId") ?? ""
            let response = try await respond {
                try assignments.leaveChannel(
                    authorization: authorization,
                    serverId: serverId,
                    channelId: channelId
                )
            }
            if response.status == .ok,
               let hub = realtime,
               let userId = agentsLifecycle.sessionUserId(authorization: authorization) {
                hub.leaveUserRooms(
                    userId: userId,
                    serverId: serverId,
                    rooms: socketMembership.channelRoomIds(channelId: channelId).rooms
                )
            }
            return response
        }

        channels.post(":channelId", "members", "batch") { request async throws -> Response in
            let body = await jsonRequestBody(ChannelMembersBatchRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try assignments.addChannelMembersBatch(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body
                )
            }
        }

        channels.post("joint-invites", ":inviteId", "accept") { request async throws -> Response in
            try await respond {
                try lifecycle.acceptJointChannelInvite(
                    authorization: request.headers[.authorization],
                    inviteId: request.parameters.get("inviteId") ?? ""
                )
            }
        }

        channels.post(":channelId", "threads") { request async throws -> Response in
            let body = await jsonRequestBody(ChannelThreadRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try assignments.createThreadFromChannel(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body
                )
            }
        }

        channels.post(":channelId", "members") { request async throws -> Response in
            let body = await jsonRequestBody(ChannelMemberRequest.self, request)
            return try await respond {
                try assignments.addChannelMember(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body
                )
            }
        }

        channels.patch(":channelId", "members", "user", ":memberId", "role") { request async throws -> Response in
            let body = await jsonRequestBody(ChannelRoleRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try assignments.updateChannelHumanRole(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    memberId: request.parameters.get("memberId") ?? "",
                    body: body
                )
            }
        }

        channels.delete(":channelId", "members", "user", ":memberId") { request async throws -> Response in
            let serverId = request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            let channelId = request.parameters.get("channelId") ?? ""
            let memberId = request.parameters.get("memberId") ?? ""
            let response = try await respond {
                try assignments.removeChannelHuman(
                    authorization: request.headers[.authorization],
                    serverId: serverId,
                    channelId: channelId,
                    memberId: memberId
                )
            }
            if response.status == .ok, let hub = realtime {
                hub.leaveUserRooms(
                    userId: memberId,
                    serverId: serverId,
                    rooms: socketMembership.channelRoomIds(channelId: channelId).rooms
                )
            }
            return response
        }

        channels.delete(":channelId", "members", "agent", ":agentId") { request async throws -> Response in
            try await respond {
                try assignments.removeChannelMember(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    agentId: request.parameters.get("agentId") ?? ""
                )
            }
        }

        channels.get(":channelId", "files") { request async throws -> Response in
            try await respond {
                try agentsLifecycle.channelFiles(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    limit: desktopQuery(request.url.query, "limit"),
                    cursor: desktopQuery(request.url.query, "cursor")
                )
            }
        }

        channels.get(":channelId", "agents") { request async throws -> Response in
            try await respond {
                try assignments.channelAgents(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? ""
                )
            }
        }

        channels.get(":channelId", "members") { request async throws -> Response in
            try await respond {
                try assignments.channelMembers(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? ""
                )
            }
        }

        channels.get(":channelId", "notification-settings") { request async throws -> Response in
            try await respond {
                try oauth.channelNotificationSettings(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? ""
                )
            }
        }

        channels.patch(":channelId", "notification-settings") { request async throws -> Response in
            let body = await jsonRequestBody(LenientJSONObjectRequest.self, request)
            return try await respond {
                try oauth.patchChannelNotificationSettings(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body
                )
            }
        }

        channels.patch(":channelId") { request async throws -> Response in
            let body = await jsonRequestBody(LenientJSONObjectRequest.self, request)
            return try await respond {
                try channelRoutes.patchChannel(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body
                )
            }
        }

        channels.post { request async throws -> Response in
            let body = await jsonRequestBody(ManagedMCPChannelCreateRequest.self, request)
            return try await respond {
                let created = try channelRoutes.createChannel(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
                // Only a successful create reaches here; the room grant and the
                // `channel:updated` frame read the published reply body.
                channelMessaging.publishCreatedChannel(
                    status: 200,
                    replyBody: created.jsonBody.render(),
                    authorization: request.headers[.authorization]
                )
                return created
            }
        }

        channels.get { request async throws -> Response in
            try await respond {
                try lifecycle.listChannels(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    archived: desktopQuery(request.url.query, "archived")
                )
            }
        }
    }
}

/// `POST /api/channels/threads/follow|unfollow` accepted a JSON body with or
/// without a `Content-Type` header, so the typed decode runs first and a
/// header-less body falls back to the raw bytes. The raw pass keeps the legacy
/// per-field `as? String` acceptance: a body whose named thread is not a string
/// still falls through to the `parentMessageId` lookup instead of failing the
/// whole mutation, and a body that is not a JSON object stays `nil` for the
/// published `Thread not found`.
private func threadFollowMutation(_ request: Request) async -> ThreadFollowMutationDTO? {
    if let typed = await jsonRequestBody(ThreadFollowMutationDTO.self, request) { return typed }
    guard let object = try? await decodeJSONRequestBody(LegacyJSONObjectBody.self, request, decoding: .json, emptyDefault: "") else { return nil }
    return ThreadFollowMutationDTO(
        threadChannelId: object.string("threadChannelId"),
        parentMessageId: object.string("parentMessageId")
    )
}

/// The refusal both activity-sync routes answer with. The legacy reply
/// published `Content-Length: 26` for this body, so it stays a fixed reply
/// instead of passing through `respond`, which would derive the length from the
/// body and change the published header.
private let activityContractRejection = HTTPReply(
    status: 400,
    headers: [
        "Content-Type": AppFallback.jsonContentType,
        "X-Raft-Contract": "raft.activity-sync;revision=2",
        "Access-Control-Expose-Headers": "X-Raft-Contract",
        "Content-Length": "26",
    ],
    body: OrderedJSON.object([OrderedJSONField("error", "invalid contract")]).render()
)
