import Foundation
import HTTPTypes
import RaftHTTP
import RaftRealtime
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
    public var realtime: RealtimeHub?

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
        emailAccounts: EmailLoginDirectory = EmailLoginDirectory(),
        realtime: RealtimeHub? = nil
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
        self.realtime = realtime
    }
}

private struct AttachmentUploadForm: Content {
    var channelId: String
    var files: [File]?
    var file: File?
}

private func parseAttachmentMultipart(data: Data, boundary: String) -> (channelId: String, files: [(filename: String, mimeType: String?, sizeBytes: Int, data: Data)])? {
    let separator = Data("\r\n--\(boundary)".utf8)
    var chunks: [Data] = []
    var splitCursor = data.startIndex
    while let range = data.range(of: separator, in: splitCursor..<data.endIndex) {
        chunks.append(data[splitCursor..<range.lowerBound])
        splitCursor = range.upperBound
    }
    chunks.append(data[splitCursor..<data.endIndex])
    let firstPrefix = Data("--\(boundary)\r\n".utf8)
    if var first = chunks.first, first.starts(with: firstPrefix) {
        first = first.dropFirst(firstPrefix.count)
        chunks[0] = first
    }
    var channelId: String?
    var files: [(filename: String, mimeType: String?, sizeBytes: Int, data: Data)] = []
    for chunk in chunks {
        var part = chunk
        if part.starts(with: Data("\r\n".utf8)) { part = part.dropFirst(2) }
        if part.starts(with: Data("--".utf8)) { continue }
        guard let headerEnd = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
        let headerData = part[part.startIndex..<headerEnd.lowerBound]
        let body = part[headerEnd.upperBound..<part.endIndex]
        let headers = String(decoding: headerData, as: UTF8.self)
        var name: String?
        var filename: String?
        var mimeType: String?
        for line in headers.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-disposition:") {
                for component in line.components(separatedBy: ";") {
                    let trimmed = component.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("name=") {
                        name = trimmed.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    } else if trimmed.hasPrefix("filename=") {
                        filename = trimmed.dropFirst(9).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    }
                }
            } else if lower.hasPrefix("content-type:") {
                mimeType = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }
        if name == "channelId" {
            channelId = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let filename, !filename.isEmpty {
            files.append((filename: filename, mimeType: mimeType, sizeBytes: body.count, data: Data(body)))
        }
    }
    guard let channelId, !channelId.isEmpty else { return nil }
    return (channelId, files)
}

public func configure(_ app: Application, services: FallbackServices) {
    services.emailAccounts.onAgentReadUpdated = { serverId, channelId, agentId, maxReadSeq in
        services.emailAccounts.emitAgentScopeRead(
            serverId: serverId,
            channelId: channelId,
            agentId: agentId,
            maxReadSeq: maxReadSeq
        )
    }
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
    app.get("api", "mcp", "servers") { request -> Response in
        routeResponse(services.emailAccounts.listManagedMCPServers(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
        ))
    }
    app.post("api", "mcp", "servers") { request -> Response in
        routeResponse(services.emailAccounts.createManagedMCPServer(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "mcp", "servers", "test-configuration") { request -> Response in
        routeResponse(services.emailAccounts.testManagedMCPConfiguration(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.patch("api", "mcp", "servers", ":id") { request -> Response in
        routeResponse(services.emailAccounts.patchManagedMCPServer(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            serverIdPath: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.delete("api", "mcp", "servers", ":id") { request -> Response in
        routeResponse(services.emailAccounts.deleteManagedMCPServer(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            serverIdPath: request.parameters.get("id") ?? ""
        ))
    }
    app.get("api", "mcp", "oauth", "callback") { _ -> Response in
        routeResponse(services.emailAccounts.managedMCPOAuthCallback())
    }
    app.get("api", "mcp", "oauth", "client-metadata") { _ -> Response in
        routeResponse(services.emailAccounts.managedMCPOAuthClientMetadata())
    }
    app.get("api", "mcp", "agents", ":agentId") { request -> Response in
        routeResponse(services.emailAccounts.managedMCPAgentCatalog(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("agentId") ?? ""
        ))
    }
    app.put("api", "mcp", "agents", ":agentId", "assignments") { request -> Response in
        routeResponse(services.emailAccounts.setManagedMCPAssignments(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("agentId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.put("api", "mcp", "agents", ":agentId", "assignments", ":mcpServerId") { request -> Response in
        routeResponse(services.emailAccounts.setSingleManagedMCPAssignment(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("agentId") ?? "",
            mcpServerId: request.parameters.get("mcpServerId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "integrations", "clients") { request -> Response in
        routeResponse(services.emailAccounts.integrationSettingsClients(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
        ))
    }
    app.get("api", "integrations", "marketplace") { request -> Response in
        routeResponse(services.emailAccounts.integrationMarketplace(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
        ))
    }
    app.post("api", "integrations", "clients", ":clientId", "app-notifications", "permissions", "review") { request -> Response in
        routeResponse(services.emailAccounts.reviewAppNotificationPermissions(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            clientId: request.parameters.get("clientId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "integrations", "agents", ":agentId") { request -> Response in
        routeResponse(IntegrationRoutes.integrationAgent(agentId: request.parameters.get("agentId") ?? ""))
    }
    app.get("api", "integrations", "clients", ":clientId", "agent-jwt") { request -> Response in
        routeResponse(services.emailAccounts.legacyAppAgentJWTSettings(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            clientRecordId: request.parameters.get("clientId") ?? ""
        ))
    }
    app.put("api", "integrations", "clients", ":clientId", "agent-jwt") { _ -> Response in
        routeResponse(services.emailAccounts.refuseLegacyAppAgentJWTWrite())
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
        if desktopQuery(request.url.query, "previewToken") != nil {
            return routeResponse(HTTPReply(status: 401, headers: [:], body: "{\"error\":\"Unauthorized\"}"))
        }
        let queryToken = desktopQuery(request.url.query, "token")
        let authorization = request.headers[.authorization] ?? queryToken.map { "Bearer \($0)" }
        return routeResponse(services.emailAccounts.attachmentDownloadURL(
            attachmentId: request.parameters.get("id") ?? "",
            authorization: authorization,
            serverId: desktopQuery(request.url.query, "serverId") ?? request.headers[HTTPField.Name("X-Server-Id")!],
            disposition: desktopQuery(request.url.query, "disposition"),
            download: desktopQuery(request.url.query, "download"),
            propagateQueryToken: queryToken
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
    app.get("api", "messages", "channel", ":channelId") { request -> Response in
        routeResponse(services.emailAccounts.listChannelMessages(
            channelId: request.parameters.get("channelId") ?? "",
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!],
            limit: desktopQuery(request.url.query, "limit"),
            before: desktopQuery(request.url.query, "before"),
            after: desktopQuery(request.url.query, "after")
        ))
    }
    app.get("api", "external-avatars", ":file") { request -> Response in
        routeResponse(services.emailAccounts.externalAvatar(file: request.parameters.get("file") ?? ""))
    }
    app.get("api", "announcements", "images", ":imageId") { request -> Response in
        routeResponse(services.emailAccounts.announcementImage(id: request.parameters.get("imageId") ?? ""))
    }
    app.get("api", "announcements", "active") { request -> Response in
        routeResponse(services.emailAccounts.activeAnnouncements(
            authorization: request.headers[.authorization],
            after: desktopQuery(request.url.query, "after")
        ))
    }
    app.post("api", "announcements", ":announcementId", "dismiss") { request -> Response in
        routeResponse(services.emailAccounts.dismissAnnouncement(
            authorization: request.headers[.authorization],
            announcementId: request.parameters.get("announcementId") ?? ""
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
    app.post("internal", "agent", ":agentId", "send") { request -> Response in
        routeResponse(services.emailAccounts.agentSend(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("agentId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("internal", "agent", ":agentId", "runtime-profile", "migration-done") { request -> Response in
        routeResponse(services.emailAccounts.runtimeProfileMigrationDone(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("agentId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("internal", "agent-api") { request -> Response in
        routeResponse(services.emailAccounts.agentApiIdentity(
            authorization: request.headers[.authorization]
        ))
    }
    app.get("internal", "agent-api", "profile") { request -> Response in
        routeResponse(services.emailAccounts.agentProfileShow(
            authorization: request.headers[.authorization],
            target: desktopQuery(request.url.query, "target")
        ))
    }
    app.post("internal", "agent-api", "profile") { request -> Response in
        routeResponse(services.emailAccounts.updateAgentProfile(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.post("internal", "agent", ":agentId", "channels", ":channelId", "join") { request -> Response in
        routeResponse(services.emailAccounts.agentChannelMembershipFromMachine(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("agentId") ?? "",
            channelId: request.parameters.get("channelId") ?? "",
            join: true
        ))
    }
    app.post("internal", "agent", ":agentId", "channels", ":channelId", "leave") { request -> Response in
        routeResponse(services.emailAccounts.agentChannelMembershipFromMachine(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("agentId") ?? "",
            channelId: request.parameters.get("channelId") ?? "",
            join: false
        ))
    }
    app.post("internal", "agent-api", "channels", ":channelId", "leave") { request -> Response in
        routeResponse(services.emailAccounts.agentLeaveChannel(
            authorization: request.headers[.authorization],
            channelId: request.parameters.get("channelId") ?? ""
        ))
    }
    app.patch("internal", "agent-api", "server") { request -> Response in
        routeResponse(services.emailAccounts.agentUpdateServer(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}"
        ))
    }
    app.patch("internal", "agent-api", "channels", ":channelId") { request -> Response in
        routeResponse(services.emailAccounts.agentUpdateChannel(
            authorization: request.headers[.authorization],
            channelId: request.parameters.get("channelId") ?? "",
            body: request.body.string ?? "{}"
        ))
    }
    app.post("internal", "agent-api", "channels", ":channelId", "members") { request -> Response in
        routeResponse(services.emailAccounts.agentChannelMemberWrite(
            authorization: request.headers[.authorization],
            channelId: request.parameters.get("channelId") ?? "",
            body: request.body.string ?? "{}",
            remove: false
        ))
    }
    app.delete("internal", "agent-api", "channels", ":channelId", "members") { request -> Response in
        routeResponse(services.emailAccounts.agentChannelMemberWrite(
            authorization: request.headers[.authorization],
            channelId: request.parameters.get("channelId") ?? "",
            body: request.body.string ?? "{}",
            remove: true
        ))
    }
    app.get("internal", "agent", ":agentId", "channel-members") { request -> Response in
        routeResponse(services.emailAccounts.agentChannelMembers(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("agentId") ?? "",
            channelRef: desktopQuery(request.url.query, "channel")
        ))
    }
    app.get("internal", "agent-api", "server") { request -> Response in
        routeResponse(services.emailAccounts.agentServerInfo(
            authorization: request.headers[.authorization]
        ))
    }
    app.post("internal", "agent-api", "resolve-channel") { request -> Response in
        routeResponse(services.emailAccounts.agentResolveChannel(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}"
        ))
    }
    app.post("internal", "agent-api", "channels") { request -> Response in
        routeResponse(services.emailAccounts.agentCreateChannel(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}"
        ))
    }
    app.get("internal", "agent-api", "attachment-upload-capabilities") { request -> Response in
        routeResponse(services.emailAccounts.agentAttachmentUploadCapabilities(
            authorization: request.headers[.authorization]
        ))
    }
    app.get("internal", "agent-api", "history") { request -> Response in
        routeResponse(services.emailAccounts.agentHistory(
            authorization: request.headers[.authorization],
            channelRef: desktopQuery(request.url.query, "channel"),
            before: desktopQuery(request.url.query, "before"),
            after: desktopQuery(request.url.query, "after"),
            around: desktopQuery(request.url.query, "around"),
            limit: desktopQuery(request.url.query, "limit")
        ))
    }
    app.get("internal", "agent", ":agentId", "history") { request -> Response in
        routeResponse(services.emailAccounts.agentHistory(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("agentId"),
            channelRef: desktopQuery(request.url.query, "channel"),
            before: desktopQuery(request.url.query, "before"),
            after: desktopQuery(request.url.query, "after"),
            around: desktopQuery(request.url.query, "around"),
            limit: desktopQuery(request.url.query, "limit")
        ))
    }
    app.get("internal", "agent-api", "inbox", "conversations") { request -> Response in
        routeResponse(services.emailAccounts.agentInboxConversations(
            authorization: request.headers[.authorization],
            limit: desktopQuery(request.url.query, "limit"),
            beforeSeq: desktopQuery(request.url.query, "before_seq"),
            view: desktopQuery(request.url.query, "view")
        ))
    }
    app.post("api", "attachments", ":id", "comments") { request -> Response in
        routeResponse(services.emailAccounts.createAttachmentComment(
            authorization: request.headers[.authorization],
            attachmentId: request.parameters.get("id") ?? "",
            body: request.body.string ?? "{}"
        ))
    }
    app.get("internal", "agent-api", "attachments", ":attachmentId", "comments") { request -> Response in
        routeResponse(services.emailAccounts.agentAttachmentCommentsList(
            authorization: request.headers[.authorization],
            attachmentId: request.parameters.get("attachmentId") ?? ""
        ))
    }
    app.post("internal", "agent-api", "attachments", ":attachmentId", "comments") { request -> Response in
        routeResponse(services.emailAccounts.agentAttachmentCommentCreate(
            authorization: request.headers[.authorization],
            attachmentId: request.parameters.get("attachmentId") ?? ""
        ))
    }
    app.get("internal", "agent-api", "attachments", ":attachmentId") { request -> Response in
        routeResponse(services.emailAccounts.agentAttachmentDownload(
            authorization: request.headers[.authorization],
            attachmentId: request.parameters.get("attachmentId") ?? ""
        ))
    }
    app.get("internal", "agent-api", "attachments", ":attachmentId", "url") { request -> Response in
        routeResponse(services.emailAccounts.agentAttachmentDownloadURL(
            authorization: request.headers[.authorization],
            attachmentId: request.parameters.get("attachmentId") ?? ""
        ))
    }
    app.get("internal", "agent-api", "integrations") { request -> Response in
        routeResponse(services.emailAccounts.agentIntegrationList(
            authorization: request.headers[.authorization]
        ))
    }
    app.get("internal", "agent-api", "integrations", "marketplace") { request -> Response in
        routeResponse(services.emailAccounts.agentIntegrationMarketplace(
            authorization: request.headers[.authorization],
            query: desktopQuery(request.url.query, "query"),
            limit: desktopQuery(request.url.query, "limit")
        ))
    }
    app.post("internal", "agent-api", "integrations", "login") { request -> Response in
        routeResponse(services.emailAccounts.agentIntegrationLogin(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}"
        ))
    }
    app.post("internal", "agent-api", "integrations", "token") { request -> Response in
        routeResponse(services.emailAccounts.agentIntegrationToken(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.get("internal", "agent-api", "context") { request -> Response in
        routeResponse(services.emailAccounts.agentContext(
            authorization: request.headers[.authorization]
        ))
    }
    app.get("internal", "agent-api", "apps", ":appId", "config") { request -> Response in
        routeResponse(services.emailAccounts.agentAppConfig(
            authorization: request.headers[.authorization],
            appId: request.parameters.get("appId") ?? ""
        ))
    }
    app.patch("internal", "agent-api", "apps", ":appId", "config") { request -> Response in
        routeResponse(services.emailAccounts.patchAgentAppConfig(
            authorization: request.headers[.authorization],
            appId: request.parameters.get("appId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("internal", "agent-api", "send") { request -> Response in
        routeResponse(services.emailAccounts.agentSendMessage(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "",
            v2: false
        ))
    }
    app.post("internal", "agent-api", "v2", "send") { request -> Response in
        routeResponse(services.emailAccounts.agentSendMessage(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "",
            v2: true
        ))
    }
    app.get("internal", "agent-api", "tasks") { request -> Response in
        routeResponse(services.emailAccounts.agentTasksList(
            authorization: request.headers[.authorization],
            legacyAgentId: nil,
            channelRef: desktopQuery(request.url.query, "channel")
        ))
    }
    app.post("internal", "agent-api", "tasks") { request -> Response in
        routeResponse(services.emailAccounts.agentTasksCreate(
            authorization: request.headers[.authorization],
            legacyAgentId: nil,
            body: request.body.string ?? ""
        ))
    }
    app.post("internal", "agent", ":agentId", "tasks") { request -> Response in
        routeResponse(services.emailAccounts.agentTasksCreate(
            authorization: request.headers[.authorization],
            legacyAgentId: request.parameters.get("agentId"),
            body: request.body.string ?? ""
        ))
    }
    app.post("internal", "agent", ":agentId", "tasks", "claim") { request -> Response in
        routeResponse(services.emailAccounts.agentTaskClaim(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}",
            legacyAgentId: request.parameters.get("agentId")
        ))
    }
    app.post("internal", "agent", ":agentId", "tasks", "update-status") { request -> Response in
        routeResponse(services.emailAccounts.agentTaskUpdateStatus(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}",
            legacyAgentId: request.parameters.get("agentId")
        ))
    }
    app.post("internal", "agent", ":agentId", "tasks", "delete") { request -> Response in
        routeResponse(services.emailAccounts.agentTaskDelete(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}",
            legacyAgentId: request.parameters.get("agentId")
        ))
    }
    app.post("internal", "agent", ":agentId", "tasks", "convert") { request -> Response in
        routeResponse(services.emailAccounts.agentTaskConvert(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}",
            legacyAgentId: request.parameters.get("agentId")
        ))
    }
    app.post("internal", "agent-api", "tasks", "assign") { request -> Response in
        routeResponse(services.emailAccounts.agentTaskAssign(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}"
        ))
    }
    app.post("internal", "agent-api", "tasks", "claim") { request -> Response in
        routeResponse(services.emailAccounts.agentTaskClaim(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}"
        ))
    }
    app.post("internal", "agent-api", "tasks", "update-status") { request -> Response in
        routeResponse(services.emailAccounts.agentTaskUpdateStatus(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}"
        ))
    }
    app.post("internal", "agent-api", "tasks", "delete") { request -> Response in
        routeResponse(services.emailAccounts.agentTaskDelete(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}"
        ))
    }
    app.post("internal", "agent-api", "tasks", "convert") { request -> Response in
        routeResponse(services.emailAccounts.agentTaskConvert(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}"
        ))
    }
    app.post("internal", "agent-api", "channels", ":channelId", "join") { request -> Response in
        routeResponse(services.emailAccounts.agentJoinChannel(
            authorization: request.headers[.authorization],
            channelId: request.parameters.get("channelId") ?? ""
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
    app.post("internal", "agent-api", "activity") { request -> Response in
        routeResponse(services.emailAccounts.agentActivityIngest(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}"
        ))
    }
    app.get("internal", "agent-api", "threads") { request -> Response in
        routeResponse(services.emailAccounts.agentThreadList(
            authorization: request.headers[.authorization]
        ))
    }
    app.post("internal", "agent-api", "threads", "unfollow") { request -> Response in
        routeResponse(services.emailAccounts.agentThreadUnfollow(
            authorization: request.headers[.authorization],
            body: request.body.string ?? "{}"
        ))
    }
    app.get("internal", "agent-api", "messages", ":messageId", "mention-deliveries") { request -> Response in
        routeResponse(services.emailAccounts.agentMentionDeliveries(
            authorization: request.headers[.authorization],
            messageRef: request.parameters.get("messageId") ?? ""
        ))
    }
    app.get("internal", "agent-api", "messages", ":messageId", "resolve") { request -> Response in
        routeResponse(services.emailAccounts.agentMessageResolve(
            authorization: request.headers[.authorization],
            messageRef: request.parameters.get("messageId") ?? ""
        ))
    }
    app.get("internal", "agent-api", "search") { request -> Response in
        routeResponse(services.emailAccounts.agentApiSearch(
            authorization: request.headers[.authorization],
            query: desktopQuery(request.url.query, "q"),
            channelRef: desktopQuery(request.url.query, "channel"),
            senderRef: desktopQuery(request.url.query, "sender"),
            sort: desktopQuery(request.url.query, "sort"),
            limit: desktopQuery(request.url.query, "limit")
        ))
    }
    app.get("internal", "agent-api", "mentions") { request -> Response in
        routeResponse(services.emailAccounts.agentMentionInbox(
            authorization: request.headers[.authorization],
            limit: desktopQuery(request.url.query, "limit")
        ))
    }
    app.post("internal", "agent-api", "prepare-action") { request -> Response in
        routeResponse(services.emailAccounts.prepareActionCard(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "actions", ":messageId", "execute") { request -> Response in
        routeResponse(services.emailAccounts.executeActionCard(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            messageId: request.parameters.get("messageId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("internal", "agent-api", "mcp", "tools") { request -> Response in
        routeResponse(services.emailAccounts.managedMCPToolSnapshot(
            authorization: request.headers[.authorization]
        ))
    }
    app.post("internal", "agent-api", "mcp", "call") { request -> Response in
        routeResponse(services.emailAccounts.callManagedMCPTool(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.post("internal", "agent-api", "feedback-locators") { request -> Response in
        routeResponse(services.emailAccounts.ingestFeedbackLocator(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.get("internal", "agent-api", "feedback-locators") { request -> Response in
        routeResponse(services.emailAccounts.listFeedbackLocators(
            authorization: request.headers[.authorization],
            reportId: desktopQuery(request.url.query, "report_id"),
            runtime: desktopQuery(request.url.query, "runtime"),
            nativeStatus: desktopQuery(request.url.query, "native_status"),
            nativeLookupMethod: desktopQuery(request.url.query, "native_lookup_method"),
            servedExactSha256: desktopQuery(request.url.query, "served_exact_sha256"),
            routeBasis: desktopQuery(request.url.query, "route_basis"),
            limit: desktopQuery(request.url.query, "limit")
        ))
    }
    app.get("internal", "agent-api", "wake-hints") { request -> Response in
        routeResponse(services.emailAccounts.agentWakeHints(
            authorization: request.headers[.authorization],
            since: desktopQuery(request.url.query, "since")
        ))
    }
    app.get("internal", "agent-api", "wake-hints", "stream") { request -> Response in
        let heartbeatEnv = services.emailAccounts.wakeStreamHeartbeatMs
        if services.nodeEnv == "test", heartbeatEnv == nil {
            return routeResponse(services.emailAccounts.agentWakeHintsStream(
                authorization: request.headers[.authorization],
                since: desktopQuery(request.url.query, "since")
            ))
        }
        switch services.emailAccounts.beginAgentWakeHintsStream(
            authorization: request.headers[.authorization],
            since: desktopQuery(request.url.query, "since")
        ) {
        case .refused(let reply):
            return routeResponse(reply)
        case .start(let token, let firstFrame):
            let rawHeartbeat = heartbeatEnv
            let heartbeatMs = min(60_000, max(50, rawHeartbeat ?? 15_000))
            let boundedTicks = services.nodeEnv == "test" ? 3 : Int.max
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            headers[.cacheControl] = "no-cache, no-transform"
            headers[HTTPField.Name("X-Accel-Buffering")!] = "no"
            var response = Response(status: .ok, headers: headers)
            response.body = Response.Body { writer in
                try await writer.write(firstFrame)
                var ticks = 0
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: UInt64(heartbeatMs) * 1_000_000)
                    services.emailAccounts.refreshAgentWakeStreamCredential(token: token)
                    try await writer.write(": heartbeat\n\n")
                    ticks += 1
                    if ticks >= boundedTicks { return }
                }
            }
            return response
        }
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
    app.get("api", "messages", "sync") { request -> Response in
        routeResponse(services.emailAccounts.syncChannelMessages(
            channelId: desktopQuery(request.url.query, "channel_id"),
            sinceSeq: desktopQuery(request.url.query, "since_seq"),
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!],
            limit: desktopQuery(request.url.query, "limit")
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
    app.post("api", "share-artifacts", "message-selection") { request -> Response in
        let baseURL = ProcessInfo.processInfo.environment["SHARE_BASE_URL"]
            ?? "http://\(request.headers[HTTPField.Name("Host")!] ?? "localhost")"
        return routeResponse(services.emailAccounts.createShareArtifact(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            body: request.body.string ?? "",
            baseURL: baseURL
        ))
    }
    app.get("share", ":file") { request -> Response in
        let baseURL = ProcessInfo.processInfo.environment["SHARE_BASE_URL"]
            ?? "http://\(request.headers[HTTPField.Name("Host")!] ?? "localhost")"
        let file = request.parameters.get("file") ?? ""
        if file.hasSuffix(".png") {
            let id = String(file.dropLast(4))
            if services.emailAccounts.shareArtifactExists(id: id) {
                var headers = HTTPFields()
                headers[.contentType] = "image/png"
                headers[.cacheControl] = "public, immutable, max-age=31536000"
                return Response(status: .ok, headers: headers, body: .init(data: EmailLoginDirectory.sharePNGData))
            }
        } else if let reply = services.emailAccounts.shareArtifactPage(id: file, baseURL: baseURL) {
            return routeResponse(reply)
        }
        return Response(status: .notFound, body: .init(string: "{\"error\":\"Not found\"}"))
    }
    app.post("api", "servers", "join-community") { request -> Response in
        guard let directory = services.publicVisits else {
            return routeResponse(PublicVisits.authRequired(authorization: request.headers[.authorization]))
        }
        let slug = (try? JSONSerialization.jsonObject(with: Data((request.body.string ?? "").utf8))) as? [String: Any]
        guard let userId = services.emailAccounts.authenticatedUserId(authorization: request.headers[.authorization]) else {
            return routeResponse(PublicVisits.authRequired(authorization: request.headers[.authorization]))
        }
        return routeResponse(directory.joinCommunity(
            userId: userId,
            slug: slug?["slug"] as? String
        ))
    }
    app.get("api", "servers", "unread-summary") { request -> Response in
        routeResponse(services.emailAccounts.serversUnreadSummary(
            authorization: request.headers[.authorization]
        ))
    }
    app.post("api", "servers") { request -> Response in
        routeResponse(services.emailAccounts.createServer(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "servers") { request -> Response in
        if let ordered = services.emailAccounts.orderedServerList(authorization: request.headers[.authorization]) {
            return routeResponse(ordered)
        }
        guard let directory = services.publicVisits else {
            return routeResponse(PublicVisits.authRequired(authorization: request.headers[.authorization]))
        }
        return routeResponse(directory.serverList(authorization: request.headers[.authorization]))
    }
    app.get("api", "channels", "activity", "snapshot") { _ -> Response in
        routeResponse(services.emailAccounts.activityContractRejection())
    }
    app.get("api", "channels", "activity", "difference") { _ -> Response in
        routeResponse(services.emailAccounts.activityContractRejection())
    }
    app.post("api", "slack-bridge", "oauth", "start") { _ -> Response in
        routeResponse(services.emailAccounts.slackBridgeUnavailable())
    }
    app.get("api", "slack-bridge", "oauth", "callback") { _ -> Response in
        routeResponse(services.emailAccounts.slackBridgeUnavailable())
    }
    app.get("api", "slack-bridge", "provisioning") { _ -> Response in
        routeResponse(services.emailAccounts.slackBridgeUnavailable())
    }
    app.post("api", "slack-bridge", "events") { _ -> Response in
        routeResponse(services.emailAccounts.slackBridgeUnavailable())
    }
    app.get("api", "servers", "order") { request -> Response in
        routeResponse(services.emailAccounts.serverOrder(authorization: request.headers[.authorization]))
    }
    app.patch("api", "servers", "order") { request -> Response in
        routeResponse(services.emailAccounts.patchServerOrder(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "agents") { request -> Response in
        routeResponse(services.emailAccounts.listServerAgents(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
        ))
    }
    app.post("api", "agents") { request -> Response in
        routeResponse(services.emailAccounts.createAgentRoute(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "agents", ":id", "runtime-options") { request -> Response in
        routeResponse(services.emailAccounts.agentRuntimeOptions(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? ""
        ))
    }
    app.post("api", "agent", "login") { request -> Response in
        routeResponse(services.emailAccounts.agentLogin(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "agents", ":id", "bootstrap-tokens") { request -> Response in
        routeResponse(services.emailAccounts.createAgentBootstrapToken(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.patch("api", "agents", ":id", "creator") { request -> Response in
        routeResponse(services.emailAccounts.patchAgentCreator(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "agents", ":id") { request -> Response in
        routeResponse(services.emailAccounts.getAgentRoute(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("id") ?? ""
        ))
    }
    app.post("api", "agents", ":id", "avatar") { request -> Response in
        routeResponse(services.emailAccounts.uploadAgentAvatar(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("id") ?? "",
            byteCount: request.body.string?.utf8.count ?? 0
        ))
    }
    app.get("api", "agents", ":id", "external-status") { request -> Response in
        routeResponse(services.emailAccounts.externalAgentStatus(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("id") ?? ""
        ))
    }
    app.get("api", "agents", "manageable") { request -> Response in
        routeResponse(services.emailAccounts.manageableAgentList(
            authorization: request.headers[.authorization]
        ))
    }
    app.patch("api", "agents", ":id") { request -> Response in
        routeResponse(services.emailAccounts.patchAgent(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "agents", ":id", "workspace-files") { request -> Response in
        routeResponse(services.emailAccounts.agentWorkspaceFiles(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? ""
        ))
    }
    app.get("api", "agents", ":id", "workspace-files", "read") { request -> Response in
        routeResponse(services.emailAccounts.agentWorkspaceFiles(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? ""
        ))
    }
    app.get("api", "agents", ":id", "activity") { request -> Response in
        routeResponse(services.emailAccounts.agentPrivateSurface(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            surface: "activity"
        ))
    }
    app.get("api", "agents", ":id", "activity-log") { request -> Response in
        routeResponse(services.emailAccounts.agentPrivateSurface(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            surface: "activity-log"
        ))
    }
    app.get("api", "agents", ":id", "activity-summaries") { request -> Response in
        routeResponse(services.emailAccounts.agentPrivateSurface(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            surface: "activity-summaries"
        ))
    }
    app.get("api", "agents", ":id", "skills") { request -> Response in
        routeResponse(services.emailAccounts.agentPrivateSurface(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            surface: "skills"
        ))
    }
    app.post("api", "agents", ":id", "migration", "cancel") { request -> Response in
        routeResponse(services.emailAccounts.agentMigrationCancel(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            body: request.body.string ?? "{}"
        ))
    }
    app.post("api", "agents", ":id", "migration", "confirm-hosted") { request -> Response in
        routeResponse(services.emailAccounts.confirmHostedMigration(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.put("internal", "agent-api", "push-webhook") { request -> Response in
        routeResponse(services.emailAccounts.putAgentPushWebhook(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "agents", ":id", "external-diagnostics") { request -> Response in
        routeResponse(services.emailAccounts.externalAgentDiagnostics(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? ""
        ))
    }
    app.put("api", "agents", ":id", "assistant-owner") { request -> Response in
        routeResponse(services.emailAccounts.agentAssistantOwner(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            method: "PUT"
        ))
    }
    app.delete("api", "agents", ":id", "assistant-owner") { request -> Response in
        routeResponse(services.emailAccounts.agentAssistantOwner(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            method: "DELETE"
        ))
    }
    app.get("api", "agents", ":id", "migration") { request -> Response in
        routeResponse(services.emailAccounts.agentMigrationStatus(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? ""
        ))
    }
    app.get("api", "agents", ":id", "agent-dms") { request -> Response in
        routeResponse(services.emailAccounts.agentDirectMessages(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? ""
        ))
    }
    app.get("api", "agents", ":id", "scopes") { request -> Response in
        routeResponse(services.emailAccounts.agentScopesRoute(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            method: "GET",
            body: ""
        ))
    }
    app.put("api", "agents", ":id", "scopes") { request -> Response in
        routeResponse(services.emailAccounts.agentScopesRoute(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            method: "PUT",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "agents", ":id", "channels") { request -> Response in
        routeResponse(services.emailAccounts.agentChannels(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? ""
        ))
    }
    app.post("api", "agents", ":id", "archive", "workspace") { request -> Response in
        routeResponse(services.emailAccounts.agentArchiveWorkspaceAction(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "agents", "archived") { request -> Response in
        routeResponse(services.emailAccounts.listArchivedAgents(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
        ))
    }
    app.get("api", "agents", ":id", "archive") { request -> Response in
        routeResponse(services.emailAccounts.agentArchiveView(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("id") ?? ""
        ))
    }
    app.delete("api", "agents", ":id") { request -> Response in
        routeResponse(services.emailAccounts.deleteAgentRoute(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "agents", ":id", "assign-machine") { request -> Response in
        routeResponse(services.emailAccounts.assignAgentMachine(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "agents", ":id", "start") { request -> Response in
        routeResponse(services.emailAccounts.agentRuntimeAction(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("id") ?? "",
            action: "start",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "agents", ":id", "stop") { request -> Response in
        routeResponse(services.emailAccounts.agentRuntimeAction(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("id") ?? "",
            action: "stop",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "agents", ":id", "reset") { request -> Response in
        routeResponse(services.emailAccounts.agentRuntimeAction(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("id") ?? "",
            action: "reset",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "agents", ":id", "migrate") { request -> Response in
        routeResponse(services.emailAccounts.agentRuntimeAction(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("id") ?? "",
            action: "migrate",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "agents", ":id", "hosted-runtime") { request -> Response in
        var response = routeResponse(services.emailAccounts.agentHostedRuntime(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? ""
        ))
        response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
        return response
    }
    app.get("api", "agents", ":id", "hosted-runtime", "model") { request -> Response in
        var response = routeResponse(services.emailAccounts.agentHostedModel(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? ""
        ))
        response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
        return response
    }
    app.put("api", "agents", ":id", "hosted-runtime", "model") { request -> Response in
        var response = routeResponse(services.emailAccounts.setAgentHostedModel(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
        response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
        return response
    }
    app.get("api", "agents", ":id", "connections", ":provider") { request -> Response in
        connectionResponse(services.emailAccounts.agentConnectionStatus(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            provider: request.parameters.get("provider") ?? ""
        ))
    }
    app.post("api", "agents", ":id", "connections", ":provider") { request -> Response in
        connectionResponse(services.emailAccounts.startAgentConnection(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            provider: request.parameters.get("provider") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "agents", ":id", "connections", ":provider", "confirm") { request -> Response in
        connectionResponse(services.emailAccounts.confirmAgentConnection(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            provider: request.parameters.get("provider") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.put("api", "agents", ":id", "connections", ":provider") { request -> Response in
        connectionResponse(services.emailAccounts.assignAgentConnection(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            provider: request.parameters.get("provider") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.delete("api", "agents", ":id", "connections", ":provider", "connectors", ":connectorId") { request -> Response in
        connectionResponse(services.emailAccounts.disconnectAgentConnector(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            provider: request.parameters.get("provider") ?? "",
            connectorId: request.parameters.get("connectorId") ?? ""
        ))
    }
    app.delete("api", "agents", ":id", "connections", ":provider") { request -> Response in
        connectionResponse(services.emailAccounts.disconnectAgentConnection(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            provider: request.parameters.get("provider") ?? ""
        ))
    }
    app.post("api", "agents", ":id", "hosted-runtime", "retry") { request -> Response in
        routeResponse(services.emailAccounts.retryAgentProvisioning(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "agents", ":id", "hosted-runtime", "usage") { request -> Response in
        var response = routeResponse(services.emailAccounts.agentHostedUsage(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            query: request.url.query
        ))
        response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
        return response
    }
    app.get("api", "agents", ":id", "runtime-form") { request -> Response in
        var response = routeResponse(services.emailAccounts.agentRuntimeForm(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? "",
            language: request.headers[HTTPField.Name("Accept-Language")!]
        ))
        applyRuntimeFormLanguage(&response, language: request.headers[HTTPField.Name("Accept-Language")!])
        return response
    }
    app.get("api", "agents", ":id", "onboarding-identity-adoption") { request -> Response in
        routeResponse(services.emailAccounts.onboardingIdentityAdoption(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? ""
        ))
    }
    app.post("api", "agents", ":id", "onboarding-identity-adoption") { request -> Response in
        routeResponse(services.emailAccounts.adoptOnboardingIdentity(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            agentId: request.parameters.get("id") ?? ""
        ))
    }
    app.post("api", "agents", ":id", "credentials") { request -> Response in
        var response = routeResponse(services.emailAccounts.issueAgentCredential(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
        response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
        return response
    }
    app.delete("api", "agents", ":id", "credentials", ":credentialId") { request -> Response in
        routeResponse(services.emailAccounts.revokeAgentCredential(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("id") ?? "",
            credentialId: request.parameters.get("credentialId") ?? ""
        ))
    }
    app.get("api", "agents", ":id", "credentials") { request -> Response in
        var response = routeResponse(services.emailAccounts.listAgentCredentials(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("id") ?? ""
        ))
        response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
        return response
    }
    app.get("api", "reminders") { request -> Response in
        routeResponse(services.emailAccounts.listReminders(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            ownerAgentId: desktopQuery(request.url.query, "ownerAgentId")
        ))
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
    app.post("api", "attachments", "upload") { request async throws -> Response in
        guard let contentType = request.headers[.contentType],
              let boundary = contentType.components(separatedBy: "boundary=").dropFirst().first?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
              !boundary.isEmpty
        else {
            return routeResponse(HTTPReply(status: 400, headers: [:], body: "{\"error\":\"Invalid multipart upload\"}"))
        }
        let buffer = try await request.body.collect(max: .specified(ByteCount(value: 300 * 1024 * 1024)))
        guard let buffer, let parsed = parseAttachmentMultipart(data: buffer, boundary: boundary) else {
            return routeResponse(HTTPReply(status: 400, headers: [:], body: "{\"error\":\"Invalid multipart upload\"}"))
        }
        return routeResponse(services.emailAccounts.uploadAttachments(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            channelId: parsed.channelId,
            files: parsed.files.map { (filename: $0.filename, mimeType: $0.mimeType, sizeBytes: $0.sizeBytes) }
        ))
    }
    app.post("internal", "agent", ":agentId", "upload") { request async throws -> Response in
        guard let contentType = request.headers[.contentType],
              let boundary = contentType.components(separatedBy: "boundary=").dropFirst().first?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
              !boundary.isEmpty
        else {
            return routeResponse(HTTPReply(status: 400, headers: [:], body: "{\"error\":\"Invalid multipart upload\"}"))
        }
        let buffer = try await request.body.collect(max: .specified(ByteCount(value: 300 * 1024 * 1024)))
        guard let buffer,
              let parsed = parseAttachmentMultipart(data: buffer, boundary: boundary),
              let file = parsed.files.first
        else {
            return routeResponse(HTTPReply(status: 400, headers: [:], body: "{\"error\":\"Invalid multipart upload\"}"))
        }
        return routeResponse(services.emailAccounts.uploadAgentAttachment(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("agentId") ?? "",
            channelId: parsed.channelId,
            filename: file.filename,
            mimeType: file.mimeType,
            sizeBytes: file.sizeBytes
        ))
    }
    app.post("internal", "agent-api", "upload") { request async throws -> Response in
        guard let contentType = request.headers[.contentType],
              let boundary = contentType.components(separatedBy: "boundary=").dropFirst().first?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
              !boundary.isEmpty
        else {
            return routeResponse(HTTPReply(status: 400, headers: [:], body: "{\"error\":\"Invalid multipart upload\"}"))
        }
        let buffer = try await request.body.collect(max: .specified(ByteCount(value: 300 * 1024 * 1024)))
        guard let buffer,
              let parsed = parseAttachmentMultipart(data: buffer, boundary: boundary),
              let file = parsed.files.first
        else {
            return routeResponse(HTTPReply(status: 400, headers: [:], body: "{\"error\":\"Invalid multipart upload\"}"))
        }
        return routeResponse(services.emailAccounts.uploadAgentAttachmentIdless(
            authorization: request.headers[.authorization],
            channelId: parsed.channelId,
            filename: file.filename,
            mimeType: file.mimeType,
            sizeBytes: file.sizeBytes,
            bytes: file.data
        ))
    }
    app.post("api", "attachments", "upload-sessions") { request -> Response in
        routeResponse(services.emailAccounts.attachmentUploadSessionCreate(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
        ))
    }
    app.get("api", "attachments", "upload-sessions", ":uploadId") { request -> Response in
        routeResponse(services.emailAccounts.attachmentUploadSessionMissing(
            authorization: request.headers[.authorization],
            uploadId: request.parameters.get("uploadId") ?? ""
        ))
    }
    app.delete("api", "attachments", "upload-sessions", ":uploadId") { request -> Response in
        routeResponse(services.emailAccounts.attachmentUploadSessionMissing(
            authorization: request.headers[.authorization],
            uploadId: request.parameters.get("uploadId") ?? ""
        ))
    }
    app.post("api", "attachments", "upload-sessions", ":uploadId", "complete") { request -> Response in
        routeResponse(services.emailAccounts.attachmentUploadSessionMissing(
            authorization: request.headers[.authorization],
            uploadId: request.parameters.get("uploadId") ?? ""
        ))
    }
    app.get("api", "attachments", "upload-capabilities") { request -> Response in
        routeResponse(services.emailAccounts.attachmentUploadCapabilities(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
        ))
    }
    app.get("api", "attachments", ":id") { request -> Response in
        if desktopQuery(request.url.query, "previewToken") != nil {
            return routeResponse(HTTPReply(status: 401, headers: [:], body: "{\"error\":\"Unauthorized\"}"))
        }
        if request.headers[.authorization] == nil, desktopQuery(request.url.query, "token") != nil {
            return routeResponse(services.emailAccounts.attachmentQueryTokenStream(
                attachmentId: request.parameters.get("id") ?? "",
                token: desktopQuery(request.url.query, "token") ?? "",
                serverId: desktopQuery(request.url.query, "serverId")
            ))
        }
        return routeResponse(services.emailAccounts.readAttachment(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!],
            attachmentId: request.parameters.get("id") ?? "",
            kind: "metadata"
        ))
    }
    app.get("api", "attachments", ":id", "html-preview") { request -> Response in
        routeResponse(services.emailAccounts.attachmentHTMLPreview(
            attachmentId: request.parameters.get("id") ?? "",
            serverId: desktopQuery(request.url.query, "serverId") ?? request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            previewToken: desktopQuery(request.url.query, "previewToken"),
            bearerQuery: desktopQuery(request.url.query, "token")
        ))
    }
    app.get("api", "attachments", ":id", "html-preview-url") { request -> Response in
        if desktopQuery(request.url.query, "previewToken") != nil {
            return routeResponse(HTTPReply(status: 401, headers: [:], body: "{\"error\":\"Unauthorized\"}"))
        }
        return routeResponse(services.emailAccounts.readAttachment(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!],
            attachmentId: request.parameters.get("id") ?? "",
            kind: "html-preview-url"
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
    app.get("api", "tasks", "server", "snapshot-metrics") { request -> Response in
        routeResponse(services.emailAccounts.taskSnapshotMetrics(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            rawQuery: request.url.query
        ))
    }
    app.get("api", "tasks", "server", "period-metrics") { request -> Response in
        routeResponse(services.emailAccounts.taskPeriodMetrics(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            rawQuery: request.url.query
        ))
    }
    app.get("api", "tasks", "channel", ":channelId") { request -> Response in
        routeResponse(services.emailAccounts.listChannelTasks(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            channelId: request.parameters.get("channelId") ?? "",
            rawQuery: request.url.query
        ))
    }
    app.get("api", "tasks", "channel", ":channelId", "number", ":taskNumber") { request -> Response in
        routeResponse(services.emailAccounts.getChannelTaskByNumber(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            channelId: request.parameters.get("channelId") ?? "",
            taskNumber: Int(request.parameters.get("taskNumber") ?? "") ?? 0
        ))
    }
    app.post("api", "tasks", "channel", ":channelId") { request -> Response in
        let channelId = request.parameters.get("channelId") ?? ""
        let body = request.body.string ?? ""
        let reply = services.emailAccounts.createChannelTasks(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            channelId: channelId,
            body: body
        )
        publishTaskCreated(reply, channelId: channelId, body: body, services: services)
        return routeResponse(reply)
    }
    app.delete("api", "tasks", ":taskId") { request -> Response in
        routeResponse(services.emailAccounts.deleteTask(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            taskId: request.parameters.get("taskId") ?? ""
        ))
    }
    app.patch("api", "tasks", ":taskId", "assignee") { request -> Response in
        routeResponse(services.emailAccounts.assignTask(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            taskId: request.parameters.get("taskId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.patch("api", "tasks", ":taskId", "unclaim") { request -> Response in
        routeResponse(services.emailAccounts.unclaimTask(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            taskId: request.parameters.get("taskId") ?? ""
        ))
    }
    app.patch("api", "tasks", ":taskId", "claim") { request -> Response in
        let reply = services.emailAccounts.claimTask(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            taskId: request.parameters.get("taskId") ?? ""
        )
        publishTaskUpdated(reply, services: services)
        return routeResponse(reply)
    }
    app.patch("api", "tasks", ":taskId", "status") { request -> Response in
        routeResponse(services.emailAccounts.updateTaskStatus(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            taskId: request.parameters.get("taskId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "tasks", "convert-message") { request -> Response in
        routeResponse(services.emailAccounts.convertMessageToTask(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "tasks", "server") { request -> Response in
        routeResponse(services.emailAccounts.listServerTasks(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            rawQuery: request.url.query
        ))
    }
    app.post("api", "servers", ":id", "machines", ":machineId", "agents", ":agentId", "feedback", ":reportId", "transcript") { request -> Response in
        routeResponse(services.emailAccounts.submitTranscriptFeedback(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            agentId: request.parameters.get("agentId") ?? "",
            reportId: request.parameters.get("reportId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "servers", ":id", "machines", ":machineId", "computer-lifecycle-operations") { request -> Response in
        routeResponse(services.emailAccounts.computerLifecycleOperation(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "servers", ":id", "machines", ":machineId", "agents", ":agentId", "diagnostic", "mention-delivery", ":messageId") { request -> Response in
        routeResponse(services.emailAccounts.mentionDeliveryDiagnostic(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            agentId: request.parameters.get("agentId") ?? "",
            messageId: request.parameters.get("messageId") ?? ""
        ))
    }
    app.get("api", "servers", ":id", "machines", ":machineId", "agents", ":agentId", "diagnostic", "session-transcript") { request -> Response in
        routeResponse(services.emailAccounts.agentSessionTranscript(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            agentId: request.parameters.get("agentId") ?? ""
        ))
    }
    app.post("api", "servers", ":id", "machines", ":machineId", "agents", ":agentId", "diagnostic", "mention-delivery", ":messageId", "redrive") { request -> Response in
        routeResponse(services.emailAccounts.redriveMentionDelivery(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            agentId: request.parameters.get("agentId") ?? "",
            messageId: request.parameters.get("messageId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "servers", ":id", "scope-attestation") { request -> Response in
        routeResponse(services.emailAccounts.serverScopeAttestation(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "message-translations:batch") { request -> Response in
        routeResponse(services.emailAccounts.batchTranslateMessages(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            body: request.body.string ?? "{}"
        ))
    }
    app.get("api", "servers", ":id", "translation-settings") { request -> Response in
        routeResponse(services.emailAccounts.serverTranslationSettings(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.patch("api", "servers", ":id", "translation-settings") { request -> Response in
        routeResponse(services.emailAccounts.patchServerTranslationSettings(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "servers", ":id", "labs") { request -> Response in
        routeResponse(services.emailAccounts.getServerLabs(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            headerServerId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
        ))
    }
    app.patch("api", "servers", ":id", "labs", "access") { request -> Response in
        routeResponse(services.emailAccounts.patchServerLabsAccess(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            headerServerId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.put("api", "servers", ":id", "labs", ":labKey") { request -> Response in
        routeResponse(services.emailAccounts.putServerLabEnrollment(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            headerServerId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            labKey: request.parameters.get("labKey") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "servers", ":id", "agreement") { request -> Response in
        routeResponse(services.emailAccounts.getServerAgreement(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.put("api", "servers", ":id", "agreement") { request -> Response in
        routeResponse(services.emailAccounts.putServerAgreement(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "servers", ":id", "avatar") { request -> Response in
        routeResponse(services.emailAccounts.uploadServerAvatar(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.post("api", "servers", ":id", "join-links") { request -> Response in
        routeResponse(services.emailAccounts.createJoinLink(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "servers", ":id", "join-links") { request -> Response in
        routeResponse(services.emailAccounts.listJoinLinks(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.delete("api", "servers", ":id", "join-links", ":linkId") { request -> Response in
        routeResponse(services.emailAccounts.revokeJoinLink(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            linkId: request.parameters.get("linkId") ?? ""
        ))
    }
    app.get("api", "auth", "invite-info") { request -> Response in
        routeResponse(services.emailAccounts.inviteInfo(token: desktopQuery(request.url.query, "token")))
    }
    app.get("api", "servers", ":id", "invites") { request -> Response in
        routeResponse(services.emailAccounts.listServerInvites(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.post("api", "servers", ":id", "invites") { request -> Response in
        routeResponse(services.emailAccounts.createServerInvite(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "servers", ":id", "setup-reset") { request -> Response in
        routeResponse(services.emailAccounts.serverSetupReset(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.post("api", "servers", ":id", "setup-handoff") { request -> Response in
        routeResponse(services.emailAccounts.serverSetupHandoff(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.delete("api", "servers", ":id", "invites", ":inviteId") { request -> Response in
        routeResponse(services.emailAccounts.revokeServerInvite(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            inviteId: request.parameters.get("inviteId") ?? ""
        ))
    }
    app.post("api", "servers", ":id", "leave") { request -> Response in
        let serverId = request.parameters.get("id") ?? ""
        let authorization = request.headers[.authorization]
        let userId = services.emailAccounts.sessionUserId(authorization: authorization)
        let reply = services.emailAccounts.leaveServer(
            authorization: authorization,
            serverId: serverId
        )
        if reply.status == 200, let userId {
            services.realtime?.removeServerMembership(serverId: serverId, userId: userId)
        }
        return routeResponse(reply)
    }
    app.get("api", "servers", ":id", "setup-projection") { request -> Response in
        routeResponse(services.emailAccounts.serverSetupProjection(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.post("api", "servers", ":id", "setup-transition") { request -> Response in
        routeResponse(services.emailAccounts.serverSetupTransition(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.patch("api", "servers", ":id", "members", ":memberId") { request -> Response in
        routeResponse(services.emailAccounts.patchServerMemberRole(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            memberId: request.parameters.get("memberId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.delete("api", "servers", ":id", "members", ":memberId") { request -> Response in
        let serverId = request.parameters.get("id") ?? ""
        let memberId = request.parameters.get("memberId") ?? ""
        let reply = services.emailAccounts.removeServerMember(
            authorization: request.headers[.authorization],
            serverId: serverId,
            memberId: memberId
        )
        if reply.status == 200 {
            services.realtime?.removeServerMembership(serverId: serverId, userId: memberId)
        }
        return routeResponse(reply)
    }
    app.delete("api", "servers", ":id") { request -> Response in
        routeResponse(services.emailAccounts.deleteServerRoute(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.patch("api", "servers", ":id", "sidebar-order") { request -> Response in
        let id = request.parameters.get("id") ?? ""
        if let reply = ServerScope.membersGuard(
            serverId: id,
            headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
        ) {
            return routeResponse(reply)
        }
        return routeResponse(services.emailAccounts.patchSidebarOrder(
            authorization: request.headers[.authorization],
            serverId: id,
            body: request.body.string ?? "{}"
        ))
    }
    app.get("api", "servers", ":id", "sidebar-order") { request -> Response in
        let id = request.parameters.get("id") ?? ""
        if let reply = ServerScope.membersGuard(
            serverId: id,
            headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
        ) {
            return routeResponse(reply)
        }
        return routeResponse(services.emailAccounts.sidebarOrder(
            authorization: request.headers[.authorization],
            serverId: id
        ))
    }
    app.get("api", "servers", ":id", "model-label-catalog") { request -> Response in
        routeResponse(services.emailAccounts.modelLabelCatalog(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.get("api", "servers", ":id", "product-analytics-settings") { request -> Response in
        routeResponse(services.emailAccounts.serverProductAnalyticsSettings(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.patch("api", "servers", ":id", "product-analytics-settings") { request -> Response in
        routeResponse(services.emailAccounts.patchServerProductAnalyticsSettings(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "servers", ":id", "settings") { request -> Response in
        routeResponse(services.emailAccounts.serverSettings(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.get("api", "servers", ":id", "notification-settings") { request -> Response in
        routeResponse(services.emailAccounts.memberNotificationSettings(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.patch("api", "servers", ":id", "notification-settings") { request -> Response in
        routeResponse(services.emailAccounts.patchServerNotificationSettings(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "servers", ":id", "onboarding-settings") { request -> Response in
        routeResponse(services.emailAccounts.serverOnboardingSettings(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.patch("api", "servers", ":id", "onboarding-settings") { request -> Response in
        routeResponse(services.emailAccounts.patchServerOnboardingSettings(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "servers", ":id", "machines", ":machineId", "computer", ":action") { request -> Response in
        routeResponse(services.emailAccounts.computerAction(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            action: request.parameters.get("action") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "computer", "attach") { request -> Response in
        routeResponse(services.emailAccounts.attachComputer(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("internal", "computer", "runners", ":agentId", "credentials") { request -> Response in
        routeResponse(services.emailAccounts.computerMintRunnerCredential(
            authorization: request.headers[.authorization],
            agentId: request.parameters.get("agentId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("internal", "computer", "runners") { request -> Response in
        routeResponse(services.emailAccounts.computerRunners(authorization: request.headers[.authorization]))
    }
    app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "resumable", "control") { request -> Response in
        routeResponse(services.emailAccounts.putMigrationControlManifest(
            authorization: request.headers[.authorization],
            migrationRef: request.parameters.get("migrationId") ?? "",
            body: request.body.string ?? "{}"
        ))
    }
    app.get("internal", "computer", "agent-migrations", "by-id", ":migrationId", "resumable", "control") { request -> Response in
        routeResponse(services.emailAccounts.getMigrationControlManifest(
            authorization: request.headers[.authorization],
            migrationRef: request.parameters.get("migrationId") ?? ""
        ))
    }
    app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "resumable", "chunks", ":chunkIndex", "receipt") { request -> Response in
        routeResponse(services.emailAccounts.putMigrationChunkReceipt(
            authorization: request.headers[.authorization],
            migrationRef: request.parameters.get("migrationId") ?? "",
            chunkIndex: Int(request.parameters.get("chunkIndex") ?? "") ?? -1,
            body: request.body.string ?? "{}"
        ))
    }
    app.get("internal", "computer", "agent-migrations", "by-id", ":migrationId", "resumable", "chunks") { request -> Response in
        routeResponse(services.emailAccounts.migrationChunkStatus(
            authorization: request.headers[.authorization],
            migrationRef: request.parameters.get("migrationId") ?? ""
        ))
    }
    app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "resumable", "upload-complete") { request -> Response in
        routeResponse(services.emailAccounts.completeMigrationUpload(
            authorization: request.headers[.authorization],
            migrationRef: request.parameters.get("migrationId") ?? ""
        ))
    }
    app.get("internal", "computer", "agent-migrations", "by-id", ":migrationId") { request -> Response in
        routeResponse(services.emailAccounts.getMigrationTargetView(
            authorization: request.headers[.authorization],
            migrationRef: request.parameters.get("migrationId") ?? ""
        ))
    }
    app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "start-transfer") { request -> Response in
        routeResponse(services.emailAccounts.startMigrationTransfer(
            authorization: request.headers[.authorization],
            migrationRef: request.parameters.get("migrationId") ?? "",
            body: request.body.string ?? "{}"
        ))
    }
    app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "flip-machine") { request -> Response in
        routeResponse(services.emailAccounts.flipMigrationMachine(
            authorization: request.headers[.authorization],
            migrationRef: request.parameters.get("migrationId") ?? "",
            body: request.body.string ?? "{}"
        ))
    }
    app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "arrived") { request -> Response in
        routeResponse(services.emailAccounts.completeMigrationArrival(
            authorization: request.headers[.authorization],
            migrationRef: request.parameters.get("migrationId") ?? "",
            body: request.body.string ?? "{}"
        ))
    }
    app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "transport-lost") { request -> Response in
        routeResponse(services.emailAccounts.markMigrationTransportLostFromComputer(
            authorization: request.headers[.authorization],
            migrationRef: request.parameters.get("migrationId") ?? "",
            body: request.body.string ?? "{}"
        ))
    }
    app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "cancel-ack") { request -> Response in
        routeResponse(services.emailAccounts.acknowledgeMigrationCancellation(
            authorization: request.headers[.authorization],
            migrationRef: request.parameters.get("migrationId") ?? "",
            body: request.body.string ?? "{}"
        ))
    }
    app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "resumable", "source-quiesced") { request -> Response in
        routeResponse(services.emailAccounts.recordMigrationSourceQuiesced(
            authorization: request.headers[.authorization],
            migrationRef: request.parameters.get("migrationId") ?? "",
            body: request.body.string ?? "{}"
        ))
    }
    app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "resumable", "source-progress") { request -> Response in
        routeResponse(services.emailAccounts.recordMigrationSourceProgress(
            authorization: request.headers[.authorization],
            migrationRef: request.parameters.get("migrationId") ?? "",
            body: request.body.string ?? "{}"
        ))
    }
    app.get("api", "servers", ":id", "usage") { request -> Response in
        routeResponse(services.emailAccounts.serverUsage(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.get("api", "servers", ":id", "machines", ":machineId", "workspaces") { request -> Response in
        routeResponse(services.emailAccounts.machineWorkspaces(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? ""
        ))
    }
    app.post("api", "servers", ":id", "machines", ":machineId", "runtimes", "rescan") { request -> Response in
        routeResponse(services.emailAccounts.machineRuntimeRescan(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? ""
        ))
    }
    app.get("api", "servers", ":id", "machines", ":machineId", "runtime-options") { request -> Response in        routeResponse(services.emailAccounts.machineRuntimeOptions(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            includeRuntimeFormV2: request.headers[HTTPField.Name("X-Raft-Runtime-Form-V2")!] == "1"
        ))
    }
    app.get("api", "servers", ":id", "machines", ":machineId", "runtime-models", ":runtime") { request -> Response in
        routeResponse(services.emailAccounts.machineRuntimeModels(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            runtime: request.parameters.get("runtime") ?? ""
        ))
    }
    app.get("api", "servers", ":id", "machines", ":machineId", "runtime-form-definitions", ":runtimeId") { request -> Response in
        var response = routeResponse(services.emailAccounts.runtimeFormDefinition(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            runtimeId: request.parameters.get("runtimeId") ?? "",
            protocolVersion: 1,
            schemaVersion: desktopQuery(request.url.query, "schemaVersion"),
            language: request.headers[HTTPField.Name("Accept-Language")!]
        ))
        applyRuntimeFormLanguage(&response, language: request.headers[HTTPField.Name("Accept-Language")!])
        return response
    }
    app.get("api", "servers", ":id", "machines", ":machineId", "runtime-forms", "v2", ":runtimeId") { request -> Response in
        var response = routeResponse(services.emailAccounts.runtimeFormDefinition(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            runtimeId: request.parameters.get("runtimeId") ?? "",
            protocolVersion: 2,
            schemaVersion: nil,
            language: request.headers[HTTPField.Name("Accept-Language")!]
        ))
        applyRuntimeFormLanguage(&response, language: request.headers[HTTPField.Name("Accept-Language")!])
        return response
    }
    app.get("api", "servers", ":id", "machines", ":machineId", "runtime-form-definitions", ":runtimeId", "option-sources", ":sourceId") { request -> Response in
        var response = routeResponse(services.emailAccounts.runtimeFormOptionSource(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            runtimeId: request.parameters.get("runtimeId") ?? "",
            sourceId: request.parameters.get("sourceId") ?? "",
            protocolVersion: 1,
            schemaVersion: desktopQuery(request.url.query, "schemaVersion"),
            language: request.headers[HTTPField.Name("Accept-Language")!]
        ))
        applyRuntimeFormLanguage(&response, language: request.headers[HTTPField.Name("Accept-Language")!])
        return response
    }
    app.get("api", "servers", ":id", "machines", ":machineId", "runtime-forms", "v2", ":runtimeId", "option-sources", ":sourceId") { request -> Response in
        var response = routeResponse(services.emailAccounts.runtimeFormOptionSource(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            runtimeId: request.parameters.get("runtimeId") ?? "",
            sourceId: request.parameters.get("sourceId") ?? "",
            protocolVersion: 2,
            schemaVersion: nil,
            language: request.headers[HTTPField.Name("Accept-Language")!],
            refresh: desktopQuery(request.url.query, "refresh") == "1"
        ))
        applyRuntimeFormLanguage(&response, language: request.headers[HTTPField.Name("Accept-Language")!])
        return response
    }
    app.get("api", "servers", ":id", "machines", ":machineId", "runtime-account-usage", ":provider") { request -> Response in
        var response = routeResponse(services.emailAccounts.machineRuntimeAccountUsage(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            provider: request.parameters.get("provider") ?? ""
        ))
        response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
        return response
    }
    app.post("api", "servers", ":id", "machines", ":machineId", "runtime-account-usage", ":provider", "refresh") { request -> Response in
        routeResponse(services.emailAccounts.refreshMachineRuntimeAccountUsage(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            provider: request.parameters.get("provider") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.delete("api", "servers", ":id", "machines", ":machineId", "workspaces", ":directoryName") { request -> Response in
        routeResponse(services.emailAccounts.deleteMachineWorkspace(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            directoryName: request.parameters.get("directoryName") ?? ""
        ))
    }
    app.get("api", "servers", ":id", "system-notifications") { request -> Response in
        var response = routeResponse(services.emailAccounts.serverSystemNotifications(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
        response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
        return response
    }
    app.get("api", "servers", ":id", "system-notifications-v2") { request -> Response in
        var response = routeResponse(services.emailAccounts.listSystemAttention(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
        response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
        return response
    }
    app.post("api", "servers", ":id", "system-notifications-v2", ":incidentId", "seen") { request -> Response in
        routeResponse(services.emailAccounts.markSystemAttentionSeen(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            incidentId: request.parameters.get("incidentId") ?? ""
        ))
    }
    app.post("api", "servers", ":id", "system-notifications-v2", ":incidentId", "dismiss") { request -> Response in
        routeResponse(services.emailAccounts.dismissSystemAttention(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            incidentId: request.parameters.get("incidentId") ?? ""
        ))
    }
    app.post("api", "servers", ":id", "machines") { request -> Response in
        routeResponse(services.emailAccounts.registerServerMachine(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "servers", ":id", "machines") { request -> Response in
        routeResponse(services.emailAccounts.listServerMachines(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.post("api", "servers", ":id", "machines", ":machineId", "rotate-key") { request -> Response in
        routeResponse(services.emailAccounts.rotateServerMachineKey(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? ""
        ))
    }
    app.delete("api", "servers", ":id", "machines", ":machineId") { request -> Response in
        routeResponse(services.emailAccounts.deleteServerMachine(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? ""
        ))
    }
    app.patch("api", "servers", ":id", "machines", ":machineId") { request -> Response in
        routeResponse(services.emailAccounts.patchServerMachine(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            machineId: request.parameters.get("machineId") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.patch("api", "servers", ":id") { request -> Response in
        routeResponse(services.emailAccounts.patchServerProfile(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "servers", ":id") { request -> Response in
        routeResponse(services.emailAccounts.serverDetails(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.get("api", "servers", ":id", "members", ":memberId", "profile") { request -> Response in
        let id = request.parameters.get("id") ?? ""
        let memberId = request.parameters.get("memberId") ?? ""
        if let reply = ServerScope.membersGuard(
            serverId: id,
            headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
        ) {
            return routeResponse(reply)
        }
        if !ServerScope.isUUID(memberId) {
            return routeResponse(ServerScope.memberProfile(
                serverId: id,
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!],
                memberId: memberId
            ))
        }
        return routeResponse(services.emailAccounts.memberProfile(
            authorization: request.headers[.authorization],
            serverId: id,
            memberId: memberId
        ))
    }
    app.get("api", "servers", ":id", "apps") { request -> Response in
        routeResponse(services.emailAccounts.serverApps(
            authorization: request.headers[.authorization],
            serverId: request.parameters.get("id") ?? ""
        ))
    }
    app.get("api", "servers", ":id", "member-graph") { request -> Response in
        let id = request.parameters.get("id") ?? ""
        if let reply = ServerScope.membersGuard(
            serverId: id,
            headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
        ) {
            return routeResponse(reply)
        }
        return routeResponse(services.emailAccounts.serverMemberGraph(
            authorization: request.headers[.authorization],
            serverId: id
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
        return routeResponse(services.emailAccounts.serverMembersList(
            authorization: request.headers[.authorization],
            serverId: id
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
    app.get("api", "provider-connections") { request -> Response in
        routeResponse(services.emailAccounts.listProviderConnections(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
        ))
    }
    app.post("api", "provider-connections", ":id", "test") { request -> Response in
        routeResponse(services.emailAccounts.retiredProviderProbe(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
        ))
    }
    app.get("api", "provider-connections", ":id", "models") { request -> Response in
        routeResponse(services.emailAccounts.retiredProviderProbe(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
        ))
    }
    app.post("api", "push", "registrations") { request -> Response in
        routeResponse(services.emailAccounts.registerPushDevice(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "push", "subscribe") { request -> Response in
        routeResponse(services.emailAccounts.recordWebPushSubscription(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "push", "family-revoke") { request -> Response in
        let body = request.body.string ?? ""
        let reply = services.emailAccounts.revokePushFamily(body: body)
        if reply.status == 204 {
            publishFamilyRevoke(body: body, services: services)
        }
        return routeResponse(reply)
    }
    app.get("api", "push", "delivery-status") { request -> Response in
        routeResponse(services.emailAccounts.pushDeliveryStatus(
            authorization: request.headers[.authorization],
            installationId: desktopQuery(request.url.query, "installationId")
        ))
    }
    app.delete("api", "push", "registrations", ":installationId") { request -> Response in
        routeResponse(services.emailAccounts.unbindPushInstallation(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            installationId: request.parameters.get("installationId") ?? ""
        ))
    }
    app.get("api", "provider-connections", ":id", "agents") { request -> Response in
        routeResponse(services.emailAccounts.listAssignedProviderAgents(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            connectionId: request.parameters.get("id") ?? ""
        ))
    }
    app.delete("api", "provider-connections", ":id", "agents", ":agentId") { request -> Response in
        routeResponse(services.emailAccounts.detachProviderAgent(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            connectionId: request.parameters.get("id") ?? "",
            agentId: request.parameters.get("agentId") ?? ""
        ))
    }
    app.delete("api", "provider-connections", ":id") { request -> Response in
        routeResponse(services.emailAccounts.deleteProviderConnection(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            connectionId: request.parameters.get("id") ?? ""
        ))
    }
    app.patch("api", "provider-connections", ":id") { request -> Response in
        routeResponse(services.emailAccounts.patchProviderConnection(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            connectionId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "provider-connections", ":id", "credentials", "rotate") { request -> Response in
        routeResponse(services.emailAccounts.rotateProviderConnectionCredential(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            connectionId: request.parameters.get("id") ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "provider-connections") { request -> Response in
        routeResponse(services.emailAccounts.createProviderConnection(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "product-feedback") { request -> Response in
        routeResponse(services.emailAccounts.submitProductFeedback(
            authorization: request.headers[.authorization],
            contentType: request.headers[.contentType] ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "product-events", "config") { request -> Response in
        routeResponse(services.emailAccounts.clientEventsConfig(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
        ))
    }
    app.post("api", "product-events", "batch") { request -> Response in
        routeResponse(services.emailAccounts.clientEventsBatch(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            userAgent: request.headers[HTTPField.Name("User-Agent")!] ?? "",
            country: request.headers[HTTPField.Name("CloudFront-Viewer-Country")!] ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "product-events", "onboarding-wizard") { request -> Response in
        routeResponse(services.emailAccounts.recordOnboardingWizard(
            authorization: request.headers[.authorization],
            serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
            body: request.body.string ?? ""
        ))
    }
    app.get("api", "oauth", "agents") { request -> Response in
        routeResponse(services.emailAccounts.oauth.agentDirectory(
            authorization: request.headers[.authorization],
            baseURL: services.emailAccounts.serverURL
        ))
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
    app.get(".well-known", "openid-configuration") { _ -> Response in
        routeResponse(OAuthDiscovery.openIDConfiguration(serverURL: services.emailAccounts.serverURL))
    }
    app.get("api", "oauth", "jwks") { _ -> Response in
        routeResponse(services.emailAccounts.oauth.jwks())
    }
    app.get("api", "oauth", "authorize") { request -> Response in
        routeResponse(services.emailAccounts.oauth.browserAuthorize(
            query: request.url.query ?? "",
            appURL: services.emailAccounts.appURL
        ))
    }
    app.get("api", "oauth", ".well-known", "openid-configuration") { _ -> Response in
        routeResponse(OAuthDiscovery.openIDConfiguration(serverURL: services.emailAccounts.serverURL))
    }
    app.get("oidc", ":server", ".well-known", "openid-configuration") { request -> Response in
        let segment = request.parameters.get("server") ?? ""
        switch resolveOIDCScope(segment, oauth: services.emailAccounts.oauth) {
        case .failure(let response):
            return response
        case .resolved:
            return routeResponse(OAuthDiscovery.openIDConfiguration(
                serverURL: services.emailAccounts.serverURL,
                serverScope: segment
            ))
        }
    }
    app.get("oidc", ":server", "api", "oauth", ".well-known", "openid-configuration") { request -> Response in
        let segment = request.parameters.get("server") ?? ""
        switch resolveOIDCScope(segment, oauth: services.emailAccounts.oauth) {
        case .failure(let response):
            return response
        case .resolved:
            return routeResponse(OAuthDiscovery.openIDConfiguration(
                serverURL: services.emailAccounts.serverURL,
                serverScope: segment
            ))
        }
    }
    app.get("oidc", ":server", "api", "oauth", "agents") { request -> Response in
        switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
        case .failure(let response):
            return response
        case .resolved(let scope):
            return routeResponse(services.emailAccounts.oauth.agentDirectory(
                authorization: request.headers[.authorization],
                baseURL: services.emailAccounts.serverURL,
                scopeServerId: scope
            ))
        }
    }
    app.get("oidc", ":server", "api", "oauth", "jwks") { request -> Response in
        switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
        case .failure(let response):
            return response
        case .resolved:
            return routeResponse(services.emailAccounts.oauth.jwks())
        }
    }
    app.get("oidc", ":server", "api", "oauth", "userinfo") { request -> Response in
        switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
        case .failure(let response):
            return response
        case .resolved(let scope):
            return routeResponse(services.emailAccounts.oauth.userinfo(
                authorization: request.headers[.authorization],
                baseURL: services.emailAccounts.serverURL,
                scopeServerId: scope
            ))
        }
    }
    app.get("oidc", ":server", "api", "oauth", "serverinfo") { request -> Response in
        switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
        case .failure(let response):
            return response
        case .resolved(let scope):
            return routeResponse(services.emailAccounts.oauth.serverinfo(
                authorization: request.headers[.authorization],
                baseURL: services.emailAccounts.serverURL,
                scopeServerId: scope
            ))
        }
    }
    app.get("oidc", ":server", "api", "oauth", "authorize") { request -> Response in
        switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
        case .failure(let response):
            return response
        case .resolved:
            return routeResponse(services.emailAccounts.oauth.browserAuthorize(
                query: request.url.query ?? "",
                appURL: services.emailAccounts.appURL,
                serverScope: request.parameters.get("server")
            ))
        }
    }
    app.post("oidc", ":server", "api", "oauth", "token") { request -> Response in
        let segment = request.parameters.get("server") ?? ""
        switch resolveOIDCScope(segment, oauth: services.emailAccounts.oauth) {
        case .failure(let response):
            return response
        case .resolved(let scope):
            let origin = OAuthDiscovery.issuerOrigin(services.emailAccounts.serverURL) ?? ""
            return routeResponse(services.emailAccounts.oauth.exchangeToken(
                authorization: request.headers[.authorization],
                body: request.body.string ?? "",
                issuer: "\(origin)/oidc/\(segment)",
                scopeServerId: scope
            ))
        }
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
    app.get("api", "auth", "identities") { request -> Response in
        routeResponse(services.emailAccounts.authIdentities(
            authorization: request.headers[.authorization]
        ))
    }
    app.delete("api", "auth", "identities", ":provider") { request -> Response in
        routeResponse(services.emailAccounts.unlinkAuthIdentity(
            authorization: request.headers[.authorization],
            provider: request.parameters.get("provider") ?? ""
        ))
    }
    app.post("api", "auth", "reset-password") { request -> Response in
        routeResponse(services.emailAccounts.resetPassword(
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "auth", "login") { request -> Response in
        return routeResponse(services.emailAccounts.login(body: request.body.string ?? ""))
    }
    app.post("api", "auth", "app-login", "start") { request -> Response in
        routeResponse(services.emailAccounts.appLoginStart(body: request.body.string ?? "{}"))
    }
    app.get("api", "auth", "app-login", "requests", ":requestId") { request -> Response in
        routeResponse(services.emailAccounts.appLoginDescribe(
            authorization: request.headers[.authorization],
            requestId: request.parameters.get("requestId") ?? ""
        ))
    }
    app.post("api", "auth", "app-login", "requests", ":requestId", "approve") { request -> Response in
        routeResponse(services.emailAccounts.appLoginApprove(
            authorization: request.headers[.authorization],
            requestId: request.parameters.get("requestId") ?? ""
        ))
    }
    app.post("api", "auth", "app-login", "requests", ":requestId", "deny") { request -> Response in
        routeResponse(services.emailAccounts.appLoginDeny(
            authorization: request.headers[.authorization],
            requestId: request.parameters.get("requestId") ?? ""
        ))
    }
    app.post("api", "auth", "app-login", "complete") { request -> Response in
        routeResponse(services.emailAccounts.appLoginComplete(body: request.body.string ?? "{}"))
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
    app.post("api", "auth", "me", "complete-profile") { request -> Response in
        routeResponse(services.emailAccounts.completeProfile(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "auth", "me", "timezone-observation") { request -> Response in
        return routeResponse(services.emailAccounts.observeTimezone(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.patch("api", "auth", "me") { request -> Response in
        return routeResponse(services.emailAccounts.patch(
            authorization: request.headers[.authorization],
            body: request.body.string ?? ""
        ))
    }
    app.post("api", "auth", "accept-invite") { request -> Response in
        if let directory = services.publicServerDirectory {
            let reply = directory.acceptInvite(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            )
            if reply.status != 404 {
                return routeResponse(reply)
            }
        }
        return routeResponse(services.emailAccounts.acceptInvite(
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
    middleware.use(ExperimentalSurfaceGate(directory: services.emailAccounts))
    middleware.use(BufferedRequestBodyMiddleware())
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

private struct ExperimentalSurfaceGate: Middleware {
    let directory: EmailLoginDirectory

    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        let path = request.url.path
        let isExperimental = path.hasPrefix("/internal/agent-api") || path.hasPrefix("/internal/computer")
        if isExperimental, directory.experimentalSurfacesDisabled {
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("Sec-Slock-Api-Version")!] = "1"
            return Response(
                status: .serviceUnavailable,
                headers: headers,
                body: .init(string: "{\"error\":\"Experimental internal surface is disabled\",\"code\":\"experimental_surface_disabled\",\"retry_after\":null}")
            )
        }
        return try await next.respond(to: request)
    }
}

private func connectionResponse(_ reply: HTTPReply) -> Response {
    var response = routeResponse(reply)
    if reply.status == 200 {
        response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
    }
    return response
}

private func applyRuntimeFormLanguage(_ response: inout Response, language: String?) {
    let zh = language?.lowercased().hasPrefix("zh") == true
    response.headers[HTTPField.Name("Content-Language")!] = zh ? "zh-CN" : "en"
    response.headers[HTTPField.Name("Vary")!] = "Accept-Language"
}

private func publishTaskUpdated(_ reply: HTTPReply, services: FallbackServices) {
    guard reply.status == 200,
          let emit = services.emailAccounts.realtimeEmitter,
          let task = (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8))) as? [String: Any],
          let channelId = task["channelId"] as? String
    else { return }
    let taskJSON = String(decoding: reply.body.utf8, as: UTF8.self)
    emit("channel:\(channelId)", "task:updated", "{\"channelId\":\(jsonChannelString(channelId)),\"task\":\(taskJSON)}")
}

private func publishTaskCreated(
    _ reply: HTTPReply,
    channelId: String,
    body: String,
    services: FallbackServices
) {
    guard reply.status == 200,
          let emit = services.emailAccounts.realtimeEmitter,
          let response = (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8))) as? [String: Any],
          let ids = response["taskIds"] as? [String],
          let request = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
          let requested = request["tasks"] as? [[String: Any]]
    else { return }
    let titles = requested.compactMap { $0["title"] as? String }
    let tasks = zip(ids, titles).map { id, title in
        "{\"id\":\(jsonChannelString(id)),\"channelId\":\(jsonChannelString(channelId)),\"title\":\(jsonChannelString(title)),\"status\":\"todo\"}"
    }.joined(separator: ",")
    emit("channel:\(channelId)", "task:created", "{\"channelId\":\(jsonChannelString(channelId)),\"tasks\":[\(tasks)]}")
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

private func publishFamilyRevoke(body: String, services: FallbackServices) {
    guard let hub = services.realtime,
          let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
          let capability = object["capability"] as? String,
          let target = services.emailAccounts.familyRevokeTarget(capability: capability)
    else { return }
    hub.revokeFamily(userId: target.userId, familyId: target.familyId)
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

private enum OIDCScopeResolution {
    case resolved(String)
    case failure(Response)
}

private func resolveOIDCScope(_ segment: String, oauth: OAuthLedger) -> OIDCScopeResolution {
    guard segment.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,63}$/) != nil else {
        return .failure(pixelAvatarError(400, "invalid_server_scope"))
    }
    guard let scope = oauth.serverScopeId(segment) else {
        return .failure(pixelAvatarError(404, "Not found"))
    }
    return .resolved(scope)
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
