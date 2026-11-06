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
        let threads = ThreadsService(directory: services.emailAccounts)
        let inbox = ReactionsRealtimeService(directory: services.emailAccounts)
        let servedInbox = InboxAndWakeService(directory: services.emailAccounts)
        channels.post(":channelId", "archive") { request -> Response in
            routeResponse(services.emailAccounts.setChannelArchivedRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                archived: true
            ))
        }

        channels.post(":channelId", "unarchive") { request -> Response in
            routeResponse(services.emailAccounts.setChannelArchivedRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                archived: false
            ))
        }

        channels.post(":channelId", "join") { request -> Response in
            routeResponse(services.emailAccounts.joinChannel(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
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

        channels.get("inbox", "done") { request -> Response in
            routeResponse(servedInbox.doneInbox(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                query: request.url.query
            ))
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

        channels.get("inbox", "unfollowed") { request -> Response in
            var response = routeResponse(threads.unfollowedInbox(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                limit: desktopQuery(request.url.query, "limit"),
                query: desktopQuery(request.url.query, "q")
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
            return response
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

        channels.delete(":channelId") { request -> Response in
            routeResponse(services.emailAccounts.deleteChannel(
                channelId: request.parameters.get("channelId") ?? "",
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }

        channels.delete("threads", ":threadId", "followers", "agents", ":agentId") { request -> Response in
            routeResponse(services.emailAccounts.removeThreadFollower(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                threadId: request.parameters.get("threadId") ?? "",
                agentId: request.parameters.get("agentId") ?? ""
            ))
        }

        channels.post("threads", ":threadId", "followers", "agents", ":agentId", "restore") { request async throws -> Response in
            routeResponse(services.emailAccounts.restoreThreadFollower(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                threadId: request.parameters.get("threadId") ?? "",
                agentId: request.parameters.get("agentId") ?? "",
                body: try await request.bodyText(default: "{}")
            ))
        }

        channels.get("threads", "followers") { request -> Response in
            routeResponse(threads.threadFollowerRoster(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                threadChannelIds: desktopQuery(request.url.query, "threadChannelIds")
            ))
        }

        channels.post("threads", "follow") { request async throws -> Response in
            // A decoded follow body is re-encoded for the directory's resolver
            // and for the follower event published from the same canonical
            // body; a body that does not decode keeps the raw path.
            if let mutation = try? await request.content.decode(ThreadFollowMutationDTO.self) {
                let body = mutation.encodedBody()
                let reply = threads.setThreadFollow(
                    mutation,
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    follow: true
                )
                publishThreadFollowers(reply, body: body, services: services)
                return routeResponse(reply)
            }
            let body = try await request.bodyText(default: "{}")
            let reply = services.emailAccounts.setThreadFollow(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: body,
                follow: true
            )
            publishThreadFollowers(reply, body: body, services: services)
            return routeResponse(reply)
        }

        channels.post("threads", "unfollow") { request async throws -> Response in
            if let mutation = try? await request.content.decode(ThreadFollowMutationDTO.self) {
                let body = mutation.encodedBody()
                let reply = threads.setThreadFollow(
                    mutation,
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    follow: false
                )
                publishThreadFollowers(reply, body: body, services: services)
                return routeResponse(reply)
            }
            let body = try await request.bodyText(default: "{}")
            let reply = services.emailAccounts.setThreadFollow(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: body,
                follow: false
            )
            publishThreadFollowers(reply, body: body, services: services)
            return routeResponse(reply)
        }

        channels.get("threads", "followed") { request -> Response in
            routeResponse(threads.followedThreads(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                limit: desktopQuery(request.url.query, "limit"),
                cursor: desktopQuery(request.url.query, "cursor"),
                unreadOnly: desktopQuery(request.url.query, "unreadOnly")
            ))
        }

        channels.get(":channelId", "threads", ":messageId") { request -> Response in
            routeResponse(threads.threadInfo(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                messageId: request.parameters.get("messageId") ?? ""
            ))
        }

        channels.get(":channelId", "threads") { request -> Response in
            routeResponse(threads.channelThreadSummaries(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                channelId: request.parameters.get("channelId") ?? "",
                parentMessageIds: desktopQuery(request.url.query, "parentMessageIds")
            ))
        }

        channels.get("activity", "snapshot") { _ -> Response in
            routeResponse(services.emailAccounts.activityContractRejection())
        }

        channels.get("activity", "difference") { _ -> Response in
            routeResponse(services.emailAccounts.activityContractRejection())
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
            publishCreatedChannel(reply, services: services, authorization: request.headers[.authorization])
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

private func publishThreadFollowers(_ reply: HTTPReply, body: String, services: FallbackServices) {
    guard reply.status == 200,
          let emit = services.emailAccounts.realtimeEmitter,
          let event = ChannelMessagingService.threadFollowersUpdatedEvent(fromBody: body)
    else { return }
    emit("channel:\(event.threadChannelId)", "thread:followers-updated", event.payloadJSON)
}

private func publishCreatedChannel(_ reply: HTTPReply, services: FallbackServices, authorization: String?) {
    guard reply.status == 200,
          let hub = services.realtime,
          let userId = services.emailAccounts.sessionUserId(authorization: authorization),
          let event = ChannelMessagingService.channelUpdatedEvent(fromReplyBody: reply.body)
    else { return }
    services.realtime?.joinUserSessions(userId: userId, room: "channel:\(event.channelId)")
    hub.emit(room: "user:\(userId)", event: "channel:updated", payloadJSON: event.payloadJSON)
}
