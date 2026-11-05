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
        let app = routes
        app.post("api", "channels", ":channelId", "archive") { request -> Response in
            routeResponse(services.emailAccounts.setChannelArchivedRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                archived: true
            ))
        }

        app.post("api", "channels", ":channelId", "unarchive") { request -> Response in
            routeResponse(services.emailAccounts.setChannelArchivedRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                archived: false
            ))
        }

        app.post("api", "channels", ":channelId", "join") { request -> Response in
            routeResponse(services.emailAccounts.joinChannel(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        app.post("api", "channels", "inbox", "done") { request -> Response in
            routeResponse(services.emailAccounts.channelInboxDone(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                body: request.body.string ?? "{}"
            ))
        }

        app.post("api", "channels", "inbox", "read-all") { request -> Response in
            routeResponse(services.emailAccounts.inboxReadAll(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }

        app.get("api", "channels", "inbox", "done") { request -> Response in
            routeResponse(services.emailAccounts.doneInbox(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                query: request.url.query
            ))
        }

        app.post("api", "channels", "inbox", "undone") { request -> Response in
            routeResponse(services.emailAccounts.inboxUndone(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                body: request.body.string ?? "{}"
            ))
        }

        app.post("api", "channels", "threads", "undone") { request -> Response in
            routeResponse(services.emailAccounts.threadInboxUndone(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                body: request.body.string ?? "{}"
            ))
        }

        app.post("api", "channels", "threads", "done") { request -> Response in
            routeResponse(services.emailAccounts.threadInboxDone(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                body: request.body.string ?? "{}"
            ))
        }

        app.get("api", "channels", "inbox", "unfollowed") { request -> Response in
            var response = routeResponse(services.emailAccounts.unfollowedInbox(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                limit: desktopQuery(request.url.query, "limit"),
                query: desktopQuery(request.url.query, "q")
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
            return response
        }

        app.get("api", "channels", "inbox") { request -> Response in
            var response = routeResponse(services.emailAccounts.channelInbox(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                filter: desktopQuery(request.url.query, "filter"),
                query: request.url.query
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
            return response
        }

        app.delete("api", "channels", ":channelId") { request -> Response in
            routeResponse(services.emailAccounts.deleteChannel(
                channelId: request.parameters.get("channelId") ?? "",
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }

        app.delete("api", "channels", "threads", ":threadId", "followers", "agents", ":agentId") { request -> Response in
            routeResponse(services.emailAccounts.removeThreadFollower(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                threadId: request.parameters.get("threadId") ?? "",
                agentId: request.parameters.get("agentId") ?? ""
            ))
        }

        app.post("api", "channels", "threads", ":threadId", "followers", "agents", ":agentId", "restore") { request -> Response in
            routeResponse(services.emailAccounts.restoreThreadFollower(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                threadId: request.parameters.get("threadId") ?? "",
                agentId: request.parameters.get("agentId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }

        app.get("api", "channels", "threads", "followers") { request -> Response in
            routeResponse(services.emailAccounts.threadFollowerRoster(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                threadChannelIds: desktopQuery(request.url.query, "threadChannelIds")
            ))
        }

        app.post("api", "channels", "threads", "follow") { request -> Response in
            let body = request.body.string ?? "{}"
            let reply = services.emailAccounts.setThreadFollow(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: body,
                follow: true
            )
            publishThreadFollowers(reply, body: body, services: services)
            return routeResponse(reply)
        }

        app.post("api", "channels", "threads", "unfollow") { request -> Response in
            let body = request.body.string ?? "{}"
            let reply = services.emailAccounts.setThreadFollow(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: body,
                follow: false
            )
            publishThreadFollowers(reply, body: body, services: services)
            return routeResponse(reply)
        }

        app.get("api", "channels", "threads", "followed") { request -> Response in
            routeResponse(services.emailAccounts.followedThreads(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                limit: desktopQuery(request.url.query, "limit"),
                cursor: desktopQuery(request.url.query, "cursor"),
                unreadOnly: desktopQuery(request.url.query, "unreadOnly")
            ))
        }

        app.get("api", "channels", ":channelId", "threads", ":messageId") { request -> Response in
            routeResponse(services.emailAccounts.threadInfo(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                messageId: request.parameters.get("messageId") ?? ""
            ))
        }

        app.get("api", "channels", ":channelId", "threads") { request -> Response in
            routeResponse(services.emailAccounts.channelThreadSummaries(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                channelId: request.parameters.get("channelId") ?? "",
                parentMessageIds: desktopQuery(request.url.query, "parentMessageIds")
            ))
        }

        app.get("api", "channels", "activity", "snapshot") { _ -> Response in
            routeResponse(services.emailAccounts.activityContractRejection())
        }

        app.get("api", "channels", "activity", "difference") { _ -> Response in
            routeResponse(services.emailAccounts.activityContractRejection())
        }

        app.post("api", "channels", "saved", "check") { request -> Response in
            routeResponse(services.emailAccounts.checkSavedMessages(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? "{}"
            ))
        }

        app.post("api", "channels", "saved") { request -> Response in
            routeResponse(services.emailAccounts.saveChannelMessage(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.get("api", "channels", "saved") { request -> Response in
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

        app.post("api", "channels", "system", "all", "hide") { request -> Response in
            routeResponse(services.emailAccounts.setAllChannelVisibility(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                visible: false
            ))
        }

        app.post("api", "channels", "system", "all", "restore") { request -> Response in
            routeResponse(services.emailAccounts.setAllChannelVisibility(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                visible: true
            ))
        }

        app.post("api", "channels", "dm") { request -> Response in
            routeResponse(services.emailAccounts.createDirectChannelRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.get("api", "channels", "dm") { request -> Response in
            routeResponse(services.emailAccounts.listDirectChannels(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }

        app.get("api", "channels", ":channelId") { request -> Response in
            routeResponse(services.emailAccounts.getChannelRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        app.post("api", "channels", ":channelId", "resume-all-agents") { request async -> Response in
            routeResponse(await services.emailAccounts.resumeAllAgents(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }

        app.post("api", "channels", ":channelId", "read") { request -> Response in
            routeResponse(services.emailAccounts.updateChannelReadState(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.post("api", "channels", ":channelId", "read-all") { request -> Response in
            routeResponse(services.emailAccounts.markChannelReadAll(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }

        app.post("api", "channels", ":channelId", "unread") { request -> Response in
            routeResponse(services.emailAccounts.markChannelUnread(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        app.get("api", "channels", "unread") { request -> Response in
            routeResponse(services.emailAccounts.channelUnread(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                summary: desktopQuery(request.url.query, "summary") == "1"
            ))
        }

        app.get("api", "channels", ":channelId", "message-display-settings") { request -> Response in
            routeResponse(services.emailAccounts.channelDisplaySettings(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        app.post("api", "channels", ":channelId", "conversation-read-all") { request -> Response in
            routeResponse(services.emailAccounts.conversationReadAll(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        app.patch("api", "channels", ":channelId", "message-display-settings") { request -> Response in
            routeResponse(services.emailAccounts.patchChannelDisplaySettings(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.post("api", "channels", ":channelId", "leave") { request -> Response in
            routeResponse(services.emailAccounts.leaveChannel(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        app.post("api", "channels", ":channelId", "members", "batch") { request -> Response in
            routeResponse(services.emailAccounts.addChannelMembersBatch(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }

        app.post("api", "channels", "joint-invites", ":inviteId", "accept") { request -> Response in
            routeResponse(services.emailAccounts.acceptJointChannelInvite(
                authorization: request.headers[.authorization],
                inviteId: request.parameters.get("inviteId") ?? ""
            ))
        }

        app.post("api", "channels", ":channelId", "threads") { request -> Response in
            routeResponse(services.emailAccounts.createThreadFromChannel(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }

        app.post("api", "channels", ":channelId", "members") { request -> Response in
            routeResponse(services.emailAccounts.addChannelMember(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.patch("api", "channels", ":channelId", "members", "user", ":memberId", "role") { request -> Response in
            routeResponse(services.emailAccounts.updateChannelHumanRole(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                memberId: request.parameters.get("memberId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }

        app.delete("api", "channels", ":channelId", "members", "user", ":memberId") { request -> Response in
            routeResponse(services.emailAccounts.removeChannelHuman(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                memberId: request.parameters.get("memberId") ?? ""
            ))
        }

        app.delete("api", "channels", ":channelId", "members", "agent", ":agentId") { request -> Response in
            routeResponse(services.emailAccounts.removeChannelMember(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                agentId: request.parameters.get("agentId") ?? ""
            ))
        }

        app.get("api", "channels", ":channelId", "files") { request -> Response in
            routeResponse(services.emailAccounts.channelFiles(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                limit: desktopQuery(request.url.query, "limit"),
                cursor: desktopQuery(request.url.query, "cursor")
            ))
        }

        app.get("api", "channels", ":channelId", "agents") { request -> Response in
            routeResponse(services.emailAccounts.channelAgentsRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        app.get("api", "channels", ":channelId", "members") { request -> Response in
            routeResponse(services.emailAccounts.channelMembers(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        app.get("api", "channels", ":channelId", "notification-settings") { request -> Response in
            routeResponse(services.emailAccounts.channelNotificationSettings(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }

        app.patch("api", "channels", ":channelId", "notification-settings") { request -> Response in
            routeResponse(services.emailAccounts.patchChannelNotificationSettings(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.patch("api", "channels", ":channelId") { request -> Response in
            routeResponse(services.emailAccounts.patchChannelRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.post("api", "channels") { request -> Response in
            let reply = services.emailAccounts.createChannelRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? ""
            )
            publishCreatedChannel(reply, services: services, authorization: request.headers[.authorization])
            return routeResponse(reply)
        }

        app.get("api", "channels") { request -> Response in
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
          let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
          let threadId = object["threadChannelId"] as? String,
          !threadId.isEmpty
    else { return }
    emit("channel:\(threadId)", "thread:followers-updated", "{\"threadChannelId\":\(jsonChannelString(threadId))}")
}

private func jsonChannelString(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value])
    let array = String(decoding: data, as: UTF8.self)
    return String(array.dropFirst().dropLast())
}

private func publishCreatedChannel(_ reply: HTTPReply, services: FallbackServices, authorization: String?) {
    guard reply.status == 200,
          let hub = services.realtime,
          let userId = services.emailAccounts.sessionUserId(authorization: authorization),
          let object = (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8))) as? [String: Any],
          let id = object["id"] as? String,
          let name = object["name"] as? String
    else { return }
    let channel: [String: Any] = [
        "id": id,
        "name": name,
        "description": object["description"] ?? NSNull(),
        "joined": true,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: ["channel": channel]),
          let payload = String(data: data, encoding: .utf8)
    else { return }
    services.realtime?.joinUserSessions(userId: userId, room: "channel:\(id)")
    hub.emit(room: "user:\(userId)", event: "channel:updated", payloadJSON: payload)
}

private func desktopQuery(_ query: String?, _ name: String) -> String? {
    guard let query, !query.isEmpty else { return nil }
    for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.first == name else { continue }
        let raw = parts.count > 1 ? parts[1] : ""
        return raw.removingPercentEncoding ?? raw
    }
    return nil
}
