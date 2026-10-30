import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// Vapor mount for `AppFallback` and `GET /api/version`.
///
/// A registered route answers itself. Anything the router does not match comes
/// back as `RouteNotFound`, and this middleware turns that into the JSON 404.
/// Vapor's default error page never chooses the status or the body.
/// `/daemon/connect` stays on the SwiftNIO listener. This process does not
/// start the livez probe; the executable does that after `configure`.

public struct FallbackServices: Sendable {
    public var nodeEnv: String
    public var tracker: DbLivenessTracker
    public var pingDatabase: @Sendable () async throws -> Void
    public var serverVersion: String
    public var releaseEnvironment: [String: String]
    public var corsOrigins: [String]
    public var desktop: DesktopDownloadDeps
    public var mobile: MobileDownloadDeps
    public var featureFlags: [PublicFeatureFlag]
    public var publicSearchIndexEnabled: Bool
    public var publicSearch: PublicSearchCatalog
    public var publicServerDirectory: PublicServerDirectory?
    public var releaseNotes: [ReleaseNoteRecord]
    public var messageContext: MessageContextCatalog
    public var publicVisits: PublicVisitDirectory?
    public var publicAttachmentBudget: PublicAttachmentBudget
    public var publicTranslationBudget: PublicAttachmentBudget
    public var emailAccounts: EmailLoginDirectory

    public init(
        nodeEnv: String,
        tracker: DbLivenessTracker,
        pingDatabase: @escaping @Sendable () async throws -> Void,
        serverVersion: String = APIVersion.serverVersion,
        releaseEnvironment: [String: String] = [:],
        corsOrigins: [String] = WebCORS.origins(corsOrigin: nil, appURL: nil),
        desktop: DesktopDownloadDeps? = nil,
        mobile: MobileDownloadDeps? = nil,
        featureFlags: [PublicFeatureFlag] = [],
        publicSearchIndexEnabled: Bool = false,
        publicSearch: PublicSearchCatalog = PublicSearchCatalog(),
        publicServerDirectory: PublicServerDirectory? = nil,
        releaseNotes: [ReleaseNoteRecord] = [],
        messageContext: MessageContextCatalog = MessageContextCatalog(),
        publicVisits: PublicVisitDirectory? = nil,
        publicAttachmentBudget: PublicAttachmentBudget = PublicAttachmentBudget(),
        publicTranslationBudget: PublicAttachmentBudget = PublicAttachmentBudget(),
        emailAccounts: EmailLoginDirectory = EmailLoginDirectory()
    ) {
        self.nodeEnv = nodeEnv
        self.tracker = tracker
        self.pingDatabase = pingDatabase
        self.serverVersion = serverVersion
        self.releaseEnvironment = releaseEnvironment
        self.corsOrigins = corsOrigins
        self.desktop = desktop ?? .live(environment: releaseEnvironment)
        self.mobile = mobile ?? .live(environment: releaseEnvironment)
        self.featureFlags = featureFlags
        self.publicSearchIndexEnabled = publicSearchIndexEnabled
        self.publicSearch = publicSearch
        self.publicServerDirectory = publicServerDirectory
        self.releaseNotes = releaseNotes
        self.messageContext = messageContext
        self.publicVisits = publicVisits
        self.publicAttachmentBudget = publicAttachmentBudget
        self.publicTranslationBudget = publicTranslationBudget
        self.emailAccounts = emailAccounts
    }
}

public func configure(_ app: Application, services: FallbackServices) {
    app.get("api", "desktop-download", "platforms") { _ async in
        routeResponse(await DesktopDownload.platformsReply(services.desktop))
    }
    app.get("api", "desktop-download") { request async in
        routeResponse(await DesktopDownload.downloadReply(
            target: desktopQuery(request.url.query, "target"),
            deps: services.desktop
        ))
    }
    app.get("api", "notifications", "stream") { request -> Response in
        let accounts = services.emailAccounts
        let authorization = request.headers[.authorization]
        switch accounts.beginNativeNotificationStream(
            authorization: authorization,
            lastEventId: request.headers[HTTPField.Name("Last-Event-ID")!]
        ) {
        case .closed(let reply):
            return routeResponse(reply)
        case .streaming(let userId, let cursor, let replay):
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            headers[.cacheControl] = "no-cache, no-store"
            var response = Response(status: .ok, headers: headers)
            let pollMs = min(5_000, max(250, accounts.nativeNotificationStreamPollMs))
            let invokeWriteHook = services.nodeEnv == "test"
            response.body = Response.Body { writer in
                var cursorSeq = cursor
                for item in replay {
                    try await writer.write(item.frame)
                    cursorSeq = item.seq
                }
                while !Task.isCancelled {
                    if !accounts.nativeNotificationCredentialIsLive(authorization: authorization) { return }
                    let batch = accounts.nativeNotificationFrames(userId: userId, after: cursorSeq)
                    for (index, item) in batch.enumerated() {
                        if invokeWriteHook {
                            await accounts.nativeNotificationLiveWriteHook?(index, batch.count)
                        }
                        if !accounts.nativeNotificationCredentialIsLive(authorization: authorization) { return }
                        try await writer.write(item.frame)
                        cursorSeq = item.seq
                    }
                    try await Task.sleep(nanoseconds: UInt64(pollMs) * 1_000_000)
                }
            }
            return response
        }
    }
    app.post("api", "notifications", "enrollment-grants") { request -> Response in
        routeResponse(services.emailAccounts.issueNativeEnrollmentGrant(
            body: request.body.string ?? "",
            authorization: request.headers[.authorization]
        ))
    }
    app.post("api", "notifications", "enrollment-exchanges") { request -> Response in
        routeResponse(services.emailAccounts.exchangeNativeEnrollmentGrant(body: request.body.string ?? ""))
    }
    app.get("api", "notifications", "devices") { request -> Response in
        routeResponse(services.emailAccounts.listNativeNotificationDevices(
            authorization: request.headers[.authorization]
        ))
    }
    app.delete("api", "notifications", "devices", ":deviceId") { request -> Response in
        routeResponse(services.emailAccounts.revokeNativeNotificationDevice(
            authorization: request.headers[.authorization],
            deviceId: request.parameters.get("deviceId") ?? ""
        ))
    }
    app.post("api", "notifications", "credentials", "rotate") { request -> Response in
        routeResponse(services.emailAccounts.rotateNativeNotificationCredential(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.delete("api", "notifications", "credentials", "current") { request -> Response in
        routeResponse(services.emailAccounts.deleteCurrentNativeNotificationCredential(
            authorization: request.headers[.authorization]
        ))
    }
    app.get("api", "email", "mobile-app", "unsubscribe") { request -> Response in
        routeResponse(services.emailAccounts.mobileAppEmailUnsubscribePage(
            token: desktopQuery(request.url.query, "token")
        ))
    }
    app.post("api", "email", "mobile-app", "unsubscribe") { request -> Response in
        routeResponse(services.emailAccounts.mobileAppEmailUnsubscribeSubmit(
            token: desktopQuery(request.url.query, "token"),
            source: desktopQuery(request.url.query, "source"),
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "mobile-download") { request async in
        routeResponse(await MobileDownload.reply(
            platform: desktopQuery(request.url.query, "platform"),
            userAgent: request.headers[.userAgent],
            deps: services.mobile
        ))
    }
    app.post("api", "feature-flags", "evaluate") { request -> Response in
        routeResponse(services.emailAccounts.evaluateFeatureFlags(
            body: request.body.string ?? "",
            authorization: request.headers[.authorization]
        ))
    }
    app.get("api", "public", "feature-flags") { request in
        routeResponse(PublicFeatureFlags.reply(
            keysQuery: desktopQuery(request.url.query, "keys"),
            platformQuery: desktopQuery(request.url.query, "platform"),
            flags: services.featureFlags
        ))
    }
    app.post("api", "public-visits", ":slug") { request -> Response in
        services.publicVisits?.record(
            slug: request.parameters.get("slug") ?? "",
            site: request.headers[HTTPField.Name("Sec-Fetch-Site")!],
            authorization: request.headers[.authorization],
            body: request.body.string ?? "",
            userAgent: request.headers[.userAgent],
            country: request.headers[HTTPField.Name("CloudFront-Viewer-Country")!]
        )
        return routeResponse(PublicVisits.reply())
    }
    app.post("api", "public", "servers", ":slug", "join-as-guest") { request -> Response in
        guard let directory = services.publicVisits else {
            return routeResponse(PublicVisits.pageReply(found: false, mode: nil))
        }
        return routeResponse(directory.join(
            slug: request.parameters.get("slug") ?? "",
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "public", "servers", ":slug") { request -> Response in
        let slug = request.parameters.get("slug") ?? ""
        let country = request.headers[HTTPField.Name("CloudFront-Viewer-Country")!]
        let region = request.headers[HTTPField.Name("CloudFront-Viewer-Country-Region")!]
        let gpc = request.headers[HTTPField.Name("Sec-GPC")!]
        if let directory = services.publicVisits {
            return routeResponse(directory.page(slug: slug, country: country, region: region, gpc: gpc))
        }
        if let directory = services.publicServerDirectory {
            return routeResponse(directory.publicCard(slug: slug))
        }
        return routeResponse(PublicVisits.pageReply(found: false, mode: nil))
    }
    app.get("api", "mcp", "agents", ":agentId") { request -> Response in
        routeResponse(IntegrationRoutes.mcpAgent(agentId: request.parameters.get("agentId") ?? ""))
    }
    app.get("api", "integrations", "agents", ":agentId") { request -> Response in
        routeResponse(IntegrationRoutes.integrationAgent(agentId: request.parameters.get("agentId") ?? ""))
    }
    app.get("api", "integrations", "clients", ":clientId", "app-notifications") { request -> Response in
        routeResponse(IntegrationRoutes.appNotifications(clientId: request.parameters.get("clientId") ?? ""))
    }
    app.get("api", "integrations", "clients", ":clientId", "share-link") { request -> Response in
        routeResponse(IntegrationRoutes.shareLink(clientId: request.parameters.get("clientId") ?? ""))
    }
    app.get("api", "integrations", "marketplace", ":clientId", "install", "app-notifications") { request -> Response in
        routeResponse(IntegrationRoutes.marketplaceAppNotifications(clientId: request.parameters.get("clientId") ?? ""))
    }
    app.get("api", "public", "servers", ":slug", "channels", ":channelId", "messages") { request -> Response in
        let channelId = request.parameters.get("channelId") ?? ""
        guard let window = publicMessageWindow(request.url.query) else {
            return routeResponse(PublicVisits.pageReply(found: false, mode: nil))
        }
        if let directory = services.publicVisits, ServerScope.isUUID(channelId) {
            return routeResponse(directory.channelMessages(
                slug: request.parameters.get("slug") ?? "",
                channelId: channelId,
                limit: window.limit,
                beforeMessageId: window.before
            ))
        }
        return routeResponse(PublicServerMessages.channel(channelId: channelId))
    }
    app.get("api", "public", "servers", ":slug", "attachments", ":attachmentId") { request -> Response in
        let attachmentId = request.parameters.get("attachmentId") ?? ""
        let client = request.remoteAddress?.host ?? "unknown"
        if !services.publicAttachmentBudget.allow(ip: client) {
            return routeResponse(PublicAttachments.tooMany())
        }
        guard let directory = services.publicVisits else {
            return routeResponse(PublicAttachments.missing(attachmentId: attachmentId))
        }
        return routeResponse(directory.publicAttachment(
            slug: request.parameters.get("slug") ?? "",
            attachmentId: attachmentId,
            forceDownload: desktopQuery(request.url.query, "download") == "1",
            inlineDisposition: desktopQuery(request.url.query, "disposition") == "inline",
            frameAncestors: services.corsOrigins
        ))
    }
    app.get("api", "public", "servers", ":slug", "threads", ":threadChannelId", "messages") { request -> Response in
        let threadId = request.parameters.get("threadChannelId") ?? ""
        guard let window = publicMessageWindow(request.url.query) else {
            return routeResponse(PublicVisits.pageReply(found: false, mode: nil))
        }
        if let directory = services.publicVisits, ServerScope.isUUID(threadId) {
            return routeResponse(directory.threadMessages(
                slug: request.parameters.get("slug") ?? "",
                threadId: threadId,
                limit: window.limit,
                beforeMessageId: window.before
            ))
        }
        return routeResponse(PublicServerMessages.thread(threadChannelId: threadId))
    }
    app.post("api", "messages", "mention-actions", "execute") { request -> Response in
        routeResponse(services.emailAccounts.executeMentionActions(
            body: request.body.string ?? "",
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!]
        ))
    }
    app.post("api", "v2", "messages") { request -> Response in
        routeResponse(services.emailAccounts.createHumanMessage(
            body: request.body.string ?? "",
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!],
            contract: "v2"
        ))
    }
    app.post("api", "messages") { request -> Response in
        // requireAuth runs before the body check. An invalid body writes nothing.
        routeResponse(services.emailAccounts.createHumanMessage(
            body: request.body.string ?? "",
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!]
        ))
    }
    app.get("api", "messages", "forward", "targets", "search") { request -> Response in
        routeResponse(services.emailAccounts.searchForwardTargets(
            query: desktopQuery(request.url.query, "q"),
            limit: desktopQuery(request.url.query, "limit"),
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!]
        ))
    }
    app.get("api", "messages", "forward", "enabled") { request -> Response in
        routeResponse(services.emailAccounts.messageForwardEnabled(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!]
        ))
    }
    app.get("api", "attachments", ":id", "url") { request -> Response in
        routeResponse(services.emailAccounts.attachmentDownloadURL(
            attachmentId: request.parameters.get("id") ?? "",
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!]
        ))
    }
    app.post("api", "messages", "forward") { request -> Response in
        routeResponse(services.emailAccounts.forwardHumanMessage(
            body: request.body.string ?? "",
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!]
        ))
    }
    app.get("api", "messages", ":messageId", "mention-deliveries") { request -> Response in
        routeResponse(services.emailAccounts.mentionDeliveries(
            messageId: request.parameters.get("messageId") ?? "",
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!]
        ))
    }
    app.get("api", "messages", ":messageId", "reactions", "actors") { request -> Response in
        routeResponse(services.emailAccounts.listReactionActors(
            messageId: request.parameters.get("messageId") ?? "",
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!],
            emoji: desktopQuery(request.url.query, "emoji"),
            limit: desktopQuery(request.url.query, "limit"),
            cursor: desktopQuery(request.url.query, "cursor")
        ))
    }
    app.get("api", "messages", ":messageId", "reactions", "viewer") { request -> Response in
        routeResponse(services.emailAccounts.reactionViewer(
            messageId: request.parameters.get("messageId") ?? "",
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!]
        ))
    }
    app.post("api", "messages", ":messageId", "reactions") { request -> Response in
        routeResponse(services.emailAccounts.addMessageReaction(
            messageId: request.parameters.get("messageId") ?? "",
            body: request.body.string ?? "",
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!]
        ))
    }
    app.delete("api", "messages", ":messageId", "reactions") { request -> Response in
        routeResponse(services.emailAccounts.removeMessageReaction(
            messageId: request.parameters.get("messageId") ?? "",
            body: request.body.string ?? "",
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!]
        ))
    }
    app.post("api", "channels", ":channelId", "join") { request -> Response in
        routeResponse(PublicVisits.authRequired(authorization: request.headers[.authorization]))
    }
    app.get("api", "messages", "channel", ":channelId") { request -> Response in
        routeResponse(services.emailAccounts.listChannelMessages(
            channelId: request.parameters.get("channelId") ?? "",
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!],
            limit: desktopQuery(request.url.query, "limit")
        ))
    }
    app.get("api", "channels", "inbox") { request -> Response in
        routeResponse(services.emailAccounts.channelInbox(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!],
            filter: desktopQuery(request.url.query, "filter")
        ))
    }
    app.post("internal", "agent-api", "messages", ":messageId", "reactions") { request -> Response in
        routeResponse(services.emailAccounts.mutateAgentApiMessageReaction(
            messageId: request.parameters.get("messageId") ?? "",
            body: request.body.string ?? "",
            authorization: request.headers[.authorization],
            remove: false
        ))
    }
    app.delete("internal", "agent-api", "messages", ":messageId", "reactions") { request -> Response in
        routeResponse(services.emailAccounts.mutateAgentApiMessageReaction(
            messageId: request.parameters.get("messageId") ?? "",
            body: request.body.string ?? "",
            authorization: request.headers[.authorization],
            remove: true
        ))
    }
    app.post("internal", "agent", ":agentId", "messages", ":messageId", "reactions") { request -> Response in
        routeResponse(services.emailAccounts.mutateAgentMessageReaction(
            agentId: request.parameters.get("agentId") ?? "",
            messageId: request.parameters.get("messageId") ?? "",
            body: request.body.string ?? "",
            authorization: request.headers[.authorization],
            remove: false
        ))
    }
    app.delete("internal", "agent", ":agentId", "messages", ":messageId", "reactions") { request -> Response in
        routeResponse(services.emailAccounts.mutateAgentMessageReaction(
            agentId: request.parameters.get("agentId") ?? "",
            messageId: request.parameters.get("messageId") ?? "",
            body: request.body.string ?? "",
            authorization: request.headers[.authorization],
            remove: true
        ))
    }
    app.get("internal", "agent-api", "mentions") { request -> Response in
        routeResponse(services.emailAccounts.agentMentionInbox(authorization: request.headers[.authorization]))
    }
    app.get("internal", "agent-api", "wake-hints") { request -> Response in
        routeResponse(services.emailAccounts.agentWakeHints(
            authorization: request.headers[.authorization],
            since: desktopQuery(request.url.query, "since")
        ))
    }
    app.get("internal", "agent-api", "wake-hints", "stream") { request -> Response in
        routeResponse(services.emailAccounts.agentWakeHintsStream(
            authorization: request.headers[.authorization],
            since: desktopQuery(request.url.query, "since")
        ))
    }
    app.get("internal", "agent-api", "events") { request -> Response in
        routeResponse(services.emailAccounts.agentThirdPartyEvents(authorization: request.headers[.authorization]))
    }
    app.post("internal", "agent-api", "third-party-events", "delivered") { request -> Response in
        routeResponse(services.emailAccounts.reportThirdPartyEventsDelivered(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.delete("api", "channels", ":channelId") { request -> Response in
        routeResponse(services.emailAccounts.deleteChannel(
            channelId: request.parameters.get("channelId") ?? "",
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!]
        ))
    }
    app.get("internal", "agent", ":agentId", "search") { request -> Response in
        routeResponse(services.emailAccounts.searchAgentMessages(
            agentId: request.parameters.get("agentId") ?? "",
            query: desktopQuery(request.url.query, "q"),
            limit: desktopQuery(request.url.query, "limit"),
            authorization: request.headers[.authorization]
        ))
    }
    app.get("api", "messages", "sync") { request -> Response in
        routeResponse(services.emailAccounts.syncChannelMessages(
            channelId: desktopQuery(request.url.query, "channel_id"),
            sinceSeq: desktopQuery(request.url.query, "since_seq"),
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!]
        ))
    }
    app.get("api", "messages", "search") { request -> Response in
        routeResponse(services.emailAccounts.searchHumanMessages(
            query: desktopQuery(request.url.query, "q"),
            sort: desktopQuery(request.url.query, "sort"),
            limit: desktopQuery(request.url.query, "limit"),
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!],
            channelId: desktopQuery(request.url.query, "channelId"),
            senderId: desktopQuery(request.url.query, "senderId"),
            senderType: desktopQuery(request.url.query, "senderType"),
            mentionTarget: desktopQuery(request.url.query, "mentionTarget")
        ))
    }
    app.get("api", "messages", "context", ":messageId") { request -> Response in
        let messageId = request.parameters.get("messageId") ?? ""
        let channelId = desktopQuery(request.url.query, "channelId")
        let authorization = request.headers[.authorization]
        let serverId = request.headers[HTTPField.Name("X-Server-Id")!]
        let reply = MessageContext.reply(
            messageId: messageId,
            channelId: channelId,
            catalog: services.messageContext,
            callerId: services.emailAccounts.sessionUserId(authorization: authorization),
            serverId: serverId
        )
        if reply.status == 404,
           let stored = services.emailAccounts.humanMessageContext(
               messageId: messageId,
               channelId: channelId,
               authorization: authorization,
               serverId: serverId,
               before: desktopQuery(request.url.query, "before"),
               after: desktopQuery(request.url.query, "after")
           ) {
            return routeResponse(stored)
        }
        return routeResponse(reply)
    }
    app.get("api", "servers") { request -> Response in
        guard let directory = services.publicVisits else {
            return routeResponse(PublicVisits.authRequired(authorization: request.headers[.authorization]))
        }
        return routeResponse(directory.serverList(authorization: request.headers[.authorization]))
    }
    app.get("api", "servers", ":id", "members", ":memberId", "profile") { request -> Response in
        routeResponse(ServerScope.memberProfile(
            serverId: request.parameters.get("id") ?? "",
            headerServerId: request.headers[HTTPField.Name("X-Server-Id")!],
            memberId: request.parameters.get("memberId") ?? ""
        ))
    }
    app.get("api", "servers", ":id", "members") { request -> Response in
        let id = request.parameters.get("id") ?? ""
        if let reply = ServerScope.membersGuard(
            serverId: id,
            headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
        ) {
            return routeResponse(reply)
        }
        let body = "{\"error\":\"Not a member of this server\"}"
        return routeResponse(HTTPReply(
            status: 403,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        ))
    }
    app.get("api", "servers", ":id", "public-visibility") { request -> Response in
        guard let directory = services.publicServerDirectory, let id = request.parameters.get("id") else {
            return routeResponse(HTTPReply(status: 404, headers: [:], body: "{\"error\":\"Not found\"}"))
        }
        return routeResponse(directory.readVisibility(serverId: id, authorization: request.headers[.authorization]))
    }
    app.post("api", "public", "servers", ":slug", "message-translations:batch") { request -> Response in
        let client = request.remoteAddress?.host ?? "unknown"
        if !services.publicTranslationBudget.allow(ip: client) {
            return routeResponse(PublicTranslations.tooMany())
        }
        let slug = request.parameters.get("slug") ?? ""
        return routeResponse(PublicTranslations.reply(
            body: request.body.string ?? "",
            gate: services.publicVisits?.translationGate(slug: slug)
        ))
    }
    app.post("api", "oauth", "authorize", "human") { request -> Response in
        routeResponse(services.emailAccounts.oauth.issueHumanAuthorization(
            session: services.emailAccounts.oauthSession(authorization: request.headers[.authorization]),
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "oauth", "installation-token") { request -> Response in
        routeResponse(services.emailAccounts.oauth.mintInstallationToken(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "oauth", "token") { request -> Response in
        routeResponse(services.emailAccounts.oauth.exchangeToken(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "",
            issuer: OAuthDiscovery.issuerOrigin(services.emailAccounts.serverURL) ?? ""
        ))
    }
    app.get("api", "oauth", "userinfo") { request -> Response in
        routeResponse(services.emailAccounts.oauth.userinfo(
            authorization: request.headers[.authorization],
            baseURL: services.emailAccounts.serverURL
        ))
    }
    app.get("api", "oauth", "agents") { request -> Response in
        routeResponse(services.emailAccounts.oauth.agentDirectory(authorization: request.headers[.authorization]))
    }
    app.get("api", "oauth", "serverinfo") { request -> Response in
        routeResponse(services.emailAccounts.oauth.serverinfo(
            authorization: request.headers[.authorization],
            baseURL: services.emailAccounts.serverURL
        ))
    }
    app.get("api", "app-installation", "server") { request -> Response in
        routeResponse(services.emailAccounts.oauth.appInstallationServer(authorization: request.headers[.authorization]))
    }
    app.get("api", "app-installation", "channels") { request -> Response in
        routeResponse(services.emailAccounts.oauth.appInstallationChannels(authorization: request.headers[.authorization]))
    }
    app.get("api", "avatars", "pixel", ":file") { request -> Response in
        let file = request.parameters.get("file") ?? ""
        guard file.hasSuffix(".svg") else {
            return pixelAvatarError(400, "Invalid pixel avatar key")
        }
        guard let key = PixelAvatars.decode(String(file.dropLast(4))) else {
            return pixelAvatarError(400, "Invalid pixel avatar key")
        }
        guard let svg = PixelAvatars.render(key: key) else {
            return pixelAvatarError(404, "Pixel avatar not found")
        }
        return routeResponse(HTTPReply(
            status: 200,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": "image/svg+xml; charset=utf-8",
                "Cache-Control": "public, max-age=31536000, immutable",
                "Content-Length": String(Data(svg.utf8).count),
            ],
            body: svg
        ))
    }
    app.post("api", "oauth", "installations", "lookup") { request -> Response in
        routeResponse(services.emailAccounts.oauth.installationLookup(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "oauth", "requests", "agent") { request -> Response in
        routeResponse(services.emailAccounts.oauth.requestAgentAccess(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "oauth", "agent-events") { request -> Response in
        routeResponse(services.emailAccounts.oauth.postAgentEvent(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "oauth", "clients", "lookup") { request -> Response in
        routeResponse(services.emailAccounts.oauth.clientLookup(
            session: services.emailAccounts.oauthSession(authorization: request.headers[.authorization]),
            clientId: desktopQuery(request.url.query, "client_id") ?? desktopQuery(request.url.query, "clientId") ?? "",
            serverId: desktopQuery(request.url.query, "server_id") ?? desktopQuery(request.url.query, "serverId") ?? "",
            scope: desktopQuery(request.url.query, "scope") ?? ""
        ))
    }
    app.get("api", "oauth", ".well-known", "openid-configuration") { _ -> Response in
        routeResponse(OAuthDiscovery.openIDConfiguration(serverURL: services.emailAccounts.serverURL))
    }
    app.post("api", "auth", "mobile", "oauth", "apple", "native", "start") { request -> Response in
        routeResponse(services.emailAccounts.startNativeApple(
            body: request.body.string ?? "",
            authorization: request.headers[.authorization]
        ))
    }
    app.post("api", "auth", "mobile", "oauth", "apple", "native", "authorize") { request async -> Response in
        let reply = await services.emailAccounts.authorizeNativeApple(
            body: request.body.string ?? "",
            authorization: request.headers[.authorization]
        )
        return routeResponse(reply)
    }
    app.post("api", "auth", "mobile", "oauth", "start") { request -> Response in
        return routeResponse(services.emailAccounts.startMobileOAuth(body: request.body.string ?? ""))
    }
    app.post("api", "auth", "mobile", "oauth", ":provider", "link", "start") { request -> Response in
        return routeResponse(services.emailAccounts.startMobileOAuthLink(
            provider: request.parameters.get("provider") ?? "",
            body: request.body.string ?? "",
            authorization: request.headers[.authorization]
        ))
    }
    app.post("api", "auth", "mobile", "oauth", ":provider", "link", "complete") { request -> Response in
        return routeResponse(services.emailAccounts.completeMobileOAuthLink(
            provider: request.parameters.get("provider") ?? "",
            body: request.body.string ?? "",
            authorization: request.headers[.authorization]
        ))
    }
    app.get("api", "auth", ":provider", "start") { request in
        routeResponse(services.emailAccounts.startWebOAuth(
            provider: request.parameters.get("provider") ?? "",
            returnTo: desktopQuery(request.url.query, "returnTo")
        ))
    }
    app.post("api", "auth", ":provider", "link", "start") { request -> Response in
        routeResponse(services.emailAccounts.startWebOAuthLink(
            provider: request.parameters.get("provider") ?? "",
            body: request.body.string ?? "",
            authorization: request.headers[.authorization]
        ))
    }
    app.post("api", "auth", ":provider", "callback") { request -> Response in
        routeResponse(services.emailAccounts.webOAuthCallback(
            provider: request.parameters.get("provider") ?? "",
            body: request.body.string ?? "",
            cookie: request.headers[.cookie]
        ))
    }
    app.get("api", "auth", ":provider", "callback") { request -> Response in
        return routeResponse(services.emailAccounts.mobileOAuthCallback(
            provider: request.parameters.get("provider") ?? "",
            code: desktopQuery(request.url.query, "code"),
            state: desktopQuery(request.url.query, "state"),
            providerError: desktopQuery(request.url.query, "error")
        ))
    }
    app.post("api", "auth", "mobile", "oauth", "complete") { request -> Response in
        return routeResponse(services.emailAccounts.completeMobileOAuth(body: request.body.string ?? ""))
    }
    app.post("api", "auth", ":provider", "complete") { request -> Response in
        return routeResponse(services.emailAccounts.completeSocial(
            provider: request.parameters.get("provider") ?? "",
            body: request.body.string ?? "",
            userAgent: request.headers[.userAgent],
            acceptLanguage: request.headers[.acceptLanguage],
            authorization: request.headers[.authorization]
        ))
    }
    app.post("api", "auth", "device", "authorize") { request -> Response in
        return routeResponse(services.emailAccounts.authorizeDevice(body: request.body.string ?? ""))
    }
    app.post("api", "auth", "device", "approve") { request -> Response in
        return routeResponse(services.emailAccounts.approveDevice(
            body: request.body.string ?? "",
            authorization: request.headers[.authorization]
        ))
    }
    app.post("api", "auth", "device", "token") { request -> Response in
        return routeResponse(services.emailAccounts.pollDeviceToken(body: request.body.string ?? ""))
    }
    app.post("api", "auth", "staging-self-account", "retire") { request -> Response in
        return routeResponse(services.emailAccounts.retireStagingSelfAccount(
            body: request.body.string ?? "",
            authorization: request.headers[.authorization]
        ))
    }
    app.post("api", "auth", "register") { request -> Response in
        return routeResponse(services.emailAccounts.register(
            body: request.body.string ?? "",
            userAgent: request.headers[.userAgent],
            acceptLanguage: request.headers[.acceptLanguage]
        ))
    }
    app.post("api", "auth", "refresh") { request -> Response in
        return routeResponse(services.emailAccounts.refresh(
            body: request.body.string ?? "",
            attemptHeader: request.headers[HTTPField.Name("X-Slock-Auth-Refresh-Attempt-Id")!],
            installationHeader: request.headers[HTTPField.Name("X-Slock-Auth-Installation-Id")!]
        ))
    }
    app.post("api", "auth", "logout") { request -> Response in
        return routeResponse(services.emailAccounts.logout(body: request.body.string ?? ""))
    }
    app.post("api", "auth", "login") { request -> Response in
        return routeResponse(services.emailAccounts.login(body: request.body.string ?? ""))
    }
    app.get("api", "auth", "providers") { request in
        routeResponse(services.emailAccounts.authProviders(platform: desktopQuery(request.url.query, "platform")))
    }
    app.get("api", "auth", "me") { request -> Response in
        return routeResponse(services.emailAccounts.me(authorization: request.headers[.authorization]))
    }
    app.on(.post, "api", "auth", "me", "avatar", maxBodySize: "6mb") { request async throws -> Response in
        let data = try await request.body.collect() ?? Data()
        return routeResponse(services.emailAccounts.uploadAvatar(
            authorization: request.headers[.authorization],
            contentType: request.headers[.contentType],
            body: data
        ))
    }
    app.patch("api", "auth", "me") { request -> Response in
        return routeResponse(services.emailAccounts.patch(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "auth", "accept-invite") { request -> Response in
        guard let directory = services.publicServerDirectory else {
            return routeResponse(HTTPReply(status: 404, headers: [:], body: "{\"error\":\"Not found\"}"))
        }
        return routeResponse(directory.acceptInvite(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.patch("api", "servers", ":id", "public-guest-join") { request -> Response in
        guard let directory = services.publicServerDirectory, let id = request.parameters.get("id") else {
            return routeResponse(HTTPReply(status: 404, headers: [:], body: "{\"error\":\"Not found\"}"))
        }
        return routeResponse(directory.patchGuestJoin(
            serverId: id,
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.patch("api", "servers", ":id", "public-visibility") { request -> Response in
        guard let directory = services.publicServerDirectory, let id = request.parameters.get("id") else {
            return routeResponse(HTTPReply(status: 404, headers: [:], body: "{\"error\":\"Not found\"}"))
        }
        return routeResponse(directory.patchVisibility(
            serverId: id,
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.patch("api", "servers", ":id", "public-search") { request -> Response in
        guard let directory = services.publicServerDirectory, let id = request.parameters.get("id") else {
            return routeResponse(HTTPReply(status: 404, headers: [:], body: "{\"error\":\"Not found\"}"))
        }
        return routeResponse(directory.patchSearch(
            serverId: id,
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "release-notes") { request in
        routeResponse(ReleaseNotes.list(
            limit: desktopQuery(request.url.query, "limit"),
            cursor: desktopQuery(request.url.query, "cursor"),
            ifNoneMatch: request.headers[HTTPField.Name("If-None-Match")!],
            notes: services.releaseNotes
        ))
    }
    app.get("api", "release-notes", ":releaseId") { request in
        routeResponse(ReleaseNotes.detail(
            id: request.parameters.get("releaseId") ?? "",
            ifNoneMatch: request.headers[HTTPField.Name("If-None-Match")!],
            notes: services.releaseNotes
        ))
    }
    app.get("api", "version") { request in
        vaporResponse(APIVersion.reply(
            method: request.method.rawValue,
            environment: services.releaseEnvironment,
            serverVersion: services.serverVersion
        ))
    }
    var middleware = Middlewares()
    middleware.use(CorsMiddleware(origins: services.corsOrigins))
    middleware.use(PublicSearchMiddleware(
        indexEnabled: services.publicSearchIndexEnabled,
        catalog: services.publicSearch,
        directory: services.publicServerDirectory
    ))
    middleware.use(FallbackMiddleware(services: services))
    app.middleware = middleware
}

private struct CorsMiddleware: Middleware {
    var origins: [String]

    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        let requestMethod = HTTPField.Name("Access-Control-Request-Method").flatMap { request.headers[$0] }
        if let reply = WebCORS.preflight(
            method: request.method.rawValue,
            origin: request.headers[.origin],
            requestMethod: requestMethod,
            allowed: origins
        ) {
            return vaporResponse(reply)
        }
        return try await next.respond(to: request)
    }
}

private struct PublicSearchMiddleware: Middleware {
    var indexEnabled: Bool
    var catalog: PublicSearchCatalog
    var directory: PublicServerDirectory?

    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        guard PublicSearch.isSearchPath(request.url.path) else {
            return try await next.respond(to: request)
        }
        let method = request.method.rawValue
        if request.method != .get && request.method != .head {
            return routeResponse(PublicSearch.methodNotAllowed(method: method))
        }
        let enabled = directory?.searchIndexEnabled ?? indexEnabled
        let current = directory?.projectedCatalog() ?? catalog
        if let reply = PublicSearch.route(
            method: method,
            path: request.url.path,
            cursor: desktopQuery(request.url.query, "cursor"),
            indexEnabled: enabled,
            catalog: current
        ) {
            return routeResponse(reply)
        }
        var response = try await next.respond(to: request)
        response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
        return response
    }
}

private struct FallbackMiddleware: Middleware {
    var services: FallbackServices

    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch is RouteNotFound {
            let reply = await AppFallback.respond(
                method: request.method.rawValue,
                target: requestTarget(request.url),
                nodeEnv: services.nodeEnv,
                tracker: services.tracker,
                pingDatabase: services.pingDatabase
            )
            return vaporResponse(reply)
        } catch {
            switch JsonServerError.global(error) {
            case .passthrough:
                throw error
            case .reply(let reply):
                return vaporResponse(reply)
            }
        }
    }
}

private func pixelAvatarError(_ status: Int, _ error: String) -> Response {
    let body = "{\"error\":\"\(error)\"}"
    return routeResponse(HTTPReply(
        status: status,
        headers: [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Content-Type": AppFallback.jsonContentType,
            "Content-Length": String(Data(body.utf8).count),
        ],
        body: body
    ))
}

private func publicMessageWindow(_ query: String?) -> (limit: Int, before: String?)? {
    let limit: Int
    if let raw = desktopQuery(query, "limit"), let value = Int(raw), value > 0 {
        limit = min(value, 50)
    } else {
        limit = 50
    }
    if let before = desktopQuery(query, "beforeMessageId") {
        guard ServerScope.isUUID(before) else { return nil }
        return (limit, before)
    }
    return (limit, nil)
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

private func requestTarget(_ url: URI) -> String {
    guard let query = url.query, !query.isEmpty else { return url.path }
    return "\(url.path)?\(query)"
}

public func routeResponse(_ reply: HTTPReply) -> Response {
    vaporResponse(reply)
}

private func vaporResponse(_ reply: HTTPReply) -> Response {
    var headers = HTTPFields()
    for (name, value) in reply.headers {
        guard let field = HTTPField.Name(name) else { continue }
        if field == .contentType {
            headers[.contentType] = value
        } else if field == .contentLength {
            continue
        } else {
            headers[field] = value
        }
    }
    var response = Response(status: httpStatus(reply.status), headers: headers, body: .init(string: reply.body))
    // The public initializer writes Content-Length from the body. HEAD keeps an
    // empty body and the length of the GET body, so put that length back.
    if let length = reply.value(for: "Content-Length") {
        response.headers[.contentLength] = length
    }
    return response
}

private let robotsTagName = HTTPField.Name("X-Robots-Tag")!

private func httpStatus(_ code: Int) -> HTTPResponse.Status {
    switch code {
    case 200: .ok
    case 201: .created
    case 400: .badRequest
    case 401: .unauthorized
    case 403: .forbidden
    case 204: .noContent
    case 302: .found
    case 304: .notModified
    case 404: .notFound
    case 405: .methodNotAllowed
    case 409: .conflict
    case 410: .gone
    case 422: .unprocessableContent
    case 429: .tooManyRequests
    case 500: .internalServerError
    case 502: .badGateway
    case 503: .serviceUnavailable
    default: HTTPResponse.Status(code: code, reasonPhrase: "")
    }
}
