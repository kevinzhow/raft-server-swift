import Foundation
import HTTPTypes
import RaftHTTP
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
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    /// Synchronous mount for `configure`, whose call sites are not `async`.
    public func register(routes: any RoutesBuilder) {
        let channels = routes.grouped("api", "channels")
        let threads = ThreadsService(
            directory: services.emailAccounts,
            publishFollowersUpdated: { payload in
                services.channelMessaging.publishThreadFollowers(payload)
            }
        )
        let inbox = ReactionsRealtimeService(directory: services.emailAccounts)
        let servedInbox = services.emailAccounts.inboxAndWake
        channels.post(":channelId", "archive") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.channelMembership.setChannelArchived(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    archived: true
                )
            }
        }

        channels.post(":channelId", "unarchive") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.channelMembership.setChannelArchived(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    archived: false
                )
            }
        }

        channels.post(":channelId", "join") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.channelMembership.joinChannel(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? ""
                )
            }
        }

        channels.post("inbox", "done") { request async throws -> Response in
            routeResponse(inbox.channelInboxDone(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                body: try await request.bodyText(default: "{}")
            ))
        }

        channels.post("inbox", "read-all") { request -> Response in
            routeResponse(inbox.inboxReadAll(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }

        channels.get("inbox", "done") { request async throws -> Response in
            try await respond {
                try servedInbox.doneInbox(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                    query: request.url.query
                )
            }
        }

        channels.post("inbox", "undone") { request async throws -> Response in
            routeResponse(inbox.inboxUndone(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                body: try await request.bodyText(default: "{}")
            ))
        }

        channels.post("threads", "undone") { request async throws -> Response in
            routeResponse(inbox.threadInboxUndone(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                body: try await request.bodyText(default: "{}")
            ))
        }

        channels.post("threads", "done") { request async throws -> Response in
            routeResponse(inbox.threadInboxDone(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                body: try await request.bodyText(default: "{}")
            ))
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

        channels.get("inbox") { request -> Response in
            var response = routeResponse(services.emailAccounts.channelInbox(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                filter: desktopQuery(request.url.query, "filter"),
                query: request.url.query
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
            return response
        }

        channels.delete(":channelId") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.searchMentions.deleteChannel(
                    channelId: request.parameters.get("channelId") ?? "",
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }

        channels.delete("threads", ":threadId", "followers", "agents", ":agentId") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.messageSend.removeThreadFollower(
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
            let restore = (try? JSONDecoder().decode(
                RestoreThreadFollowerRequest.self,
                from: Data(try await request.bodyText(default: "{}").utf8)
            )) ?? RestoreThreadFollowerRequest()
            return try await respond {
                try services.emailAccounts.messageSend.restoreThreadFollower(
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
            routeResponse(services.emailAccounts.checkSavedMessages(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: try await request.bodyText(default: "{}")
            ))
        }

        channels.post("saved") { request async throws -> Response in
            routeResponse(services.emailAccounts.saveChannelMessage(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: try await request.bodyText()
            ))
        }

        channels.get("saved") { request -> Response in
            routeResponse(services.emailAccounts.listSavedMessages(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                query: desktopQuery(request.url.query, "q"),
                channelId: desktopQuery(request.url.query, "channelId"),
                sort: desktopQuery(request.url.query, "sort"),
                limit: Int(desktopQuery(request.url.query, "limit") ?? "") ?? 50,
                offset: Int(desktopQuery(request.url.query, "offset") ?? "") ?? 0
            ))
        }

        channels.post("system", "all", "hide") { request -> Response in
            routeResponse(services.emailAccounts.setAllChannelVisibility(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                visible: false
            ))
        }

        channels.post("system", "all", "restore") { request -> Response in
            routeResponse(services.emailAccounts.setAllChannelVisibility(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                visible: true
            ))
        }

        channels.post("dm") { request async throws -> Response in
            // The peer is named by `agentId` or `userId`; both absent keeps the
            // directory's `Invalid DM peer` 400, so the raw path stays for every
            // body that does not decode.
            if let body = try? await request.content.decode(ChannelCreateRequestDTO.self) {
                return routeResponse(services.emailAccounts.createDirectChannelRoute(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body.encodedBody()
                ))
            }
            return routeResponse(services.emailAccounts.createDirectChannelRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: try await request.bodyText()
            ))
        }

        channels.get("dm") { request -> Response in
            routeResponse(services.emailAccounts.listDirectChannels(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }

        channels.get(":channelId") { request -> Response in
            routeResponse(services.emailAccounts.getChannelRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        channels.post(":channelId", "resume-all-agents") { request async throws -> Response in
            routeResponse(await services.emailAccounts.resumeAllAgents(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: try await request.bodyText(default: "{}")
            ))
        }

        channels.post(":channelId", "read") { request async throws -> Response in
            routeResponse(services.emailAccounts.updateChannelReadState(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: try await request.bodyText()
            ))
        }

        channels.post(":channelId", "read-all") { request async throws -> Response in
            routeResponse(services.emailAccounts.markChannelReadAll(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: try await request.bodyText(default: "{}")
            ))
        }

        channels.post(":channelId", "unread") { request -> Response in
            routeResponse(services.emailAccounts.markChannelUnread(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        channels.get("unread") { request -> Response in
            routeResponse(services.emailAccounts.channelUnread(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                summary: desktopQuery(request.url.query, "summary") == "1"
            ))
        }

        channels.get(":channelId", "message-display-settings") { request -> Response in
            routeResponse(services.emailAccounts.channelDisplaySettings(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        channels.post(":channelId", "conversation-read-all") { request -> Response in
            routeResponse(services.emailAccounts.conversationReadAll(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        channels.patch(":channelId", "message-display-settings") { request async throws -> Response in
            routeResponse(services.emailAccounts.patchChannelDisplaySettings(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: try await request.bodyText()
            ))
        }

        channels.post(":channelId", "leave") { request -> Response in
            let authorization = request.headers[.authorization]
            let serverId = request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            let channelId = request.parameters.get("channelId") ?? ""
            let reply = services.emailAccounts.leaveChannel(
                authorization: authorization,
                serverId: serverId,
                channelId: channelId
            )
            if reply.status == 200,
               let hub = services.realtime,
               let userId = services.emailAccounts.sessionUserId(authorization: authorization) {
                hub.leaveUserRooms(
                    userId: userId,
                    serverId: serverId,
                    rooms: services.emailAccounts.socketMembership.channelRoomIds(channelId: channelId).rooms
                )
            }
            return routeResponse(reply)
        }

        channels.post(":channelId", "members", "batch") { request async throws -> Response in
            routeResponse(services.emailAccounts.addChannelMembersBatch(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: try await request.bodyText(default: "{}")
            ))
        }

        channels.post("joint-invites", ":inviteId", "accept") { request -> Response in
            routeResponse(services.emailAccounts.acceptJointChannelInvite(
                authorization: request.headers[.authorization],
                inviteId: request.parameters.get("inviteId") ?? ""
            ))
        }

        channels.post(":channelId", "threads") { request async throws -> Response in
            routeResponse(services.emailAccounts.createThreadFromChannel(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: try await request.bodyText(default: "{}")
            ))
        }

        channels.post(":channelId", "members") { request async throws -> Response in
            routeResponse(services.emailAccounts.addChannelMember(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: try await request.bodyText()
            ))
        }

        channels.patch(":channelId", "members", "user", ":memberId", "role") { request async throws -> Response in
            routeResponse(services.emailAccounts.updateChannelHumanRole(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                memberId: request.parameters.get("memberId") ?? "",
                body: try await request.bodyText(default: "{}")
            ))
        }

        channels.delete(":channelId", "members", "user", ":memberId") { request -> Response in
            let serverId = request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            let channelId = request.parameters.get("channelId") ?? ""
            let memberId = request.parameters.get("memberId") ?? ""
            let reply = services.emailAccounts.removeChannelHuman(
                authorization: request.headers[.authorization],
                serverId: serverId,
                channelId: channelId,
                memberId: memberId
            )
            if reply.status == 200, let hub = services.realtime {
                hub.leaveUserRooms(
                    userId: memberId,
                    serverId: serverId,
                    rooms: services.emailAccounts.socketMembership.channelRoomIds(channelId: channelId).rooms
                )
            }
            return routeResponse(reply)
        }

        channels.delete(":channelId", "members", "agent", ":agentId") { request -> Response in
            routeResponse(services.emailAccounts.removeChannelMember(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                agentId: request.parameters.get("agentId") ?? ""
            ))
        }

        channels.get(":channelId", "files") { request -> Response in
            routeResponse(services.emailAccounts.channelFiles(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                limit: desktopQuery(request.url.query, "limit"),
                cursor: desktopQuery(request.url.query, "cursor")
            ))
        }

        channels.get(":channelId", "agents") { request -> Response in
            routeResponse(services.emailAccounts.channelAgentsRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        channels.get(":channelId", "members") { request -> Response in
            routeResponse(services.emailAccounts.channelMembers(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        channels.get(":channelId", "notification-settings") { request -> Response in
            routeResponse(services.emailAccounts.channelNotificationSettings(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        channels.patch(":channelId", "notification-settings") { request async throws -> Response in
            routeResponse(services.emailAccounts.patchChannelNotificationSettings(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: try await request.bodyText()
            ))
        }

        channels.patch(":channelId") { request async throws -> Response in
            routeResponse(services.emailAccounts.patchChannelRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: try await request.bodyText()
            ))
        }

        channels.post { request async throws -> Response in
            let reply = services.emailAccounts.createChannelRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: try await request.bodyText()
            )
            services.channelMessaging.publishCreatedChannel(
                status: reply.status,
                replyBody: reply.body,
                authorization: request.headers[.authorization]
            )
            return routeResponse(reply)
        }

        channels.get { request -> Response in
            routeResponse(services.emailAccounts.listChannels(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                archived: desktopQuery(request.url.query, "archived")
            ))
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
    if let typed = try? await request.content.decode(ThreadFollowMutationDTO.self) {
        return typed
    }
    guard let raw = try? await request.bodyText(),
          let data = raw.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
        return nil
    }
    return ThreadFollowMutationDTO(
        threadChannelId: object["threadChannelId"] as? String,
        parentMessageId: object["parentMessageId"] as? String
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
    body: "{\"error\":\"invalid contract\"}"
)
