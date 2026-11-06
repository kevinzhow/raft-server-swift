import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// The remaining small route families that are not large enough for their own
/// feature collection: announcements, avatars, downloads, email unsubscribe,
/// feature flags, notifications, product events, public visits, push, release
/// notes, share artifacts, the Slack bridge, v2 messages, version and
/// `share/:file` (39 routes).
///
/// Agents, computers and reminders moved to `AgentsFeature`,
/// `ComputersFeature` and `RemindersFeature`. Every registration keeps the
/// original method, path, header projection and `routeResponse` mapping; only
/// the builder is grouped by prefix.
public struct NotificationsFeature: RouteCollection, Sendable {
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        let app = routes
        let announcements = app.grouped("api", "announcements")
        let avatars = app.grouped("api", "avatars")
        let desktopDownload = app.grouped("api", "desktop-download")
        let email = app.grouped("api", "email")
        let externalAvatars = app.grouped("api", "external-avatars")
        let featureFlags = app.grouped("api", "feature-flags")
        let notifications = app.grouped("api", "notifications")
        let productEvents = app.grouped("api", "product-events")
        let publicVisits = app.grouped("api", "public-visits")
        let publicSurface = app.grouped("api", "public")
        let push = app.grouped("api", "push")
        let releaseNotes = app.grouped("api", "release-notes")
        let shareArtifacts = app.grouped("api", "share-artifacts")
        let slackBridge = app.grouped("api", "slack-bridge")
        let v2 = app.grouped("api", "v2")

        announcements.post(":announcementId", "dismiss") { request -> Response in
            routeResponse(services.emailAccounts.dismissAnnouncement(
                authorization: request.headers[.authorization],
                announcementId: request.parameters.get("announcementId") ?? "",
                query: request.url.query,
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        announcements.get("active") { request -> Response in
            routeResponse(services.emailAccounts.activeAnnouncements(
                authorization: request.headers[.authorization],
                after: desktopQuery(request.url.query, "after"),
                query: request.url.query
            ))
        }
        announcements.get("images", ":imageId") { request -> Response in
            routeResponse(services.emailAccounts.announcementImage(id: request.parameters.get("imageId") ?? ""))
        }
        avatars.get("pixel", ":file") { request -> Response in
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
        desktopDownload.get { request async in
            routeResponse(await DesktopDownload.downloadReply(
                target: desktopQuery(request.url.query, "target"),
                deps: services.desktop
            ))
        }
        desktopDownload.get("platforms") { _ async in
            routeResponse(await DesktopDownload.platformsReply(services.desktop))
        }
        email.get("mobile-app", "unsubscribe") { request -> Response in
            routeResponse(services.emailAccounts.mobileAppEmailUnsubscribePage(
                token: desktopQuery(request.url.query, "token")
            ))
        }
        email.post("mobile-app", "unsubscribe") { request -> Response in
            routeResponse(services.emailAccounts.mobileAppEmailUnsubscribeSubmit(
                token: desktopQuery(request.url.query, "token"),
                source: desktopQuery(request.url.query, "source"),
                body: request.body.string ?? ""
            ))
        }
        externalAvatars.get(":file") { request -> Response in
            routeResponse(services.emailAccounts.externalAvatar(file: request.parameters.get("file") ?? ""))
        }
        featureFlags.post("evaluate") { request -> Response in
            routeResponse(services.emailAccounts.evaluateFeatureFlags(
                body: request.body.string ?? "",
                authorization: request.headers[.authorization]
            ))
        }
        app.get("api", "mobile-download") { request async in
            routeResponse(await MobileDownload.reply(
                platform: desktopQuery(request.url.query, "platform"),
                userAgent: request.headers[.userAgent],
                deps: services.mobile
            ))
        }
        notifications.delete("credentials", "current") { request -> Response in
            routeResponse(services.emailAccounts.deleteCurrentNativeNotificationCredential(
                authorization: request.headers[.authorization]
            ))
        }
        notifications.post("credentials", "rotate") { request -> Response in
            routeResponse(services.emailAccounts.rotateNativeNotificationCredential(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        notifications.get("devices") { request -> Response in
            routeResponse(services.emailAccounts.listNativeNotificationDevices(
                authorization: request.headers[.authorization]
            ))
        }
        notifications.delete("devices", ":deviceId") { request -> Response in
            routeResponse(services.emailAccounts.revokeNativeNotificationDevice(
                authorization: request.headers[.authorization],
                deviceId: request.parameters.get("deviceId") ?? ""
            ))
        }
        notifications.post("enrollment-exchanges") { request -> Response in
            routeResponse(services.emailAccounts.exchangeNativeEnrollmentGrant(body: request.body.string ?? ""))
        }
        notifications.post("enrollment-grants") { request -> Response in
            routeResponse(services.emailAccounts.issueNativeEnrollmentGrant(
                body: request.body.string ?? "",
                authorization: request.headers[.authorization]
            ))
        }
        notifications.get("stream") { request -> Response in
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
        productEvents.post("batch") { request -> Response in
            routeResponse(services.emailAccounts.clientEventsBatch(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                userAgent: request.headers[HTTPField.Name("User-Agent")!] ?? "",
                country: request.headers[HTTPField.Name("CloudFront-Viewer-Country")!] ?? "",
                body: request.body.string ?? ""
            ))
        }
        productEvents.get("config") { request -> Response in
            routeResponse(services.emailAccounts.clientEventsConfig(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        productEvents.post("onboarding-wizard") { request -> Response in
            routeResponse(services.emailAccounts.recordOnboardingWizard(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? ""
            ))
        }
        publicVisits.post(":slug") { request -> Response in
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
        publicSurface.get("feature-flags") { request in
            routeResponse(PublicFeatureFlags.reply(
                keysQuery: desktopQuery(request.url.query, "keys"),
                platformQuery: desktopQuery(request.url.query, "platform"),
                flags: services.featureFlags
            ))
        }
        publicSurface.post("servers", ":slug", "join-as-guest") { request -> Response in
            guard let directory = services.publicVisits else {
                return routeResponse(PublicVisits.pageReply(found: false, mode: nil))
            }
            return routeResponse(directory.join(
                slug: request.parameters.get("slug") ?? "",
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        push.get("delivery-status") { request -> Response in
            routeResponse(services.emailAccounts.pushDeliveryStatus(
                authorization: request.headers[.authorization],
                installationId: desktopQuery(request.url.query, "installationId")
            ))
        }
        push.post("family-revoke") { request -> Response in
            let body = request.body.string ?? ""
            let reply = services.emailAccounts.revokePushFamily(body: body)
            if reply.status == 204 {
                publishFamilyRevoke(body: body, services: services)
            }
            return routeResponse(reply)
        }
        push.post("registrations") { request -> Response in
            routeResponse(services.emailAccounts.registerPushDevice(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? ""
            ))
        }
        push.delete("registrations", ":installationId") { request -> Response in
            routeResponse(services.emailAccounts.unbindPushInstallation(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                installationId: request.parameters.get("installationId") ?? ""
            ))
        }
        push.post("subscribe") { request -> Response in
            routeResponse(services.emailAccounts.recordWebPushSubscription(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        releaseNotes.get { request in
            routeResponse(ReleaseNotes.list(
                limit: desktopQuery(request.url.query, "limit"),
                cursor: desktopQuery(request.url.query, "cursor"),
                ifNoneMatch: request.headers[HTTPField.Name("If-None-Match")!],
                notes: services.releaseNotes
            ))
        }
        releaseNotes.get(":releaseId") { request in
            routeResponse(ReleaseNotes.detail(
                id: request.parameters.get("releaseId") ?? "",
                ifNoneMatch: request.headers[HTTPField.Name("If-None-Match")!],
                notes: services.releaseNotes
            ))
        }
        shareArtifacts.post("message-selection") { request async throws -> Response in
            let bases = shareArtifactBases(services, request)
            var parsed: (channelId: String?, image: (bytes: Data, sizeBytes: Int)?) = (nil, nil)
            if let contentType = request.headers[.contentType],
               let boundary = contentType.components(separatedBy: "boundary=").dropFirst().first?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
               !boundary.isEmpty,
               let buffer = try await request.body.collect(max: .specified(ByteCount(value: 11 * 1024 * 1024))) {
                parsed = parseShareArtifactMultipart(data: buffer, boundary: boundary)
            }
            return routeResponse(services.emailAccounts.createShareArtifact(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: parsed.channelId,
                image: parsed.image,
                serverBase: bases.server,
                shareBase: bases.share,
                cdnBase: bases.cdn
            ))
        }
        slackBridge.post("events") { _ -> Response in
            routeResponse(services.emailAccounts.slackBridgeUnavailable())
        }
        slackBridge.get("oauth", "callback") { _ -> Response in
            routeResponse(services.emailAccounts.slackBridgeUnavailable())
        }
        slackBridge.post("oauth", "start") { _ -> Response in
            routeResponse(services.emailAccounts.slackBridgeUnavailable())
        }
        slackBridge.get("provisioning") { _ -> Response in
            routeResponse(services.emailAccounts.slackBridgeUnavailable())
        }
        v2.post("messages") { request -> Response in
            routeResponse(services.emailAccounts.createHumanMessage(
                body: request.body.string ?? "",
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                contract: "v2"
            ))
        }
        app.get("api", "version") { request in
            vaporResponse(APIVersion.reply(
                method: request.method.rawValue,
                environment: services.releaseEnvironment,
                serverVersion: services.serverVersion
            ))
        }
        app.get("share", ":file") { request -> Response in
            let bases = shareArtifactBases(services, request)
            let file = request.parameters.get("file") ?? ""
            if file.hasSuffix(".png") {
                if let image = services.emailAccounts.shareArtifactImage(id: String(file.dropLast(4))) {
                    var headers = HTTPFields()
                    headers[.contentType] = "image/png"
                    headers[.cacheControl] = "public, immutable, max-age=31536000"
                    headers[HTTPField.Name("Content-Disposition")!] = "inline"
                    headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
                    headers[.contentLength] = String(image.bytes.count)
                    return Response(status: .ok, headers: headers, body: .init(data: image.bytes))
                }
            } else if let reply = services.emailAccounts.shareArtifactPage(
                id: file,
                serverBase: bases.server,
                shareBase: bases.share,
                cdnBase: bases.cdn
            ) {
                return routeResponse(reply)
            }
            return Response(status: .notFound, body: .init(string: "Not found"))
        }
    }
}

private func shareArtifactBases(_ services: FallbackServices, _ request: Request) -> (server: String, share: String, cdn: String?) {
    func stripTrailingSlash(_ value: String) -> String {
        value.hasSuffix("/") ? String(value.dropLast()) : value
    }
    func configured(_ key: String) -> String? {
        let raw = services.releaseEnvironment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }
    if let injectedServer = services.serverBaseURL {
        let server = stripTrailingSlash(injectedServer)
        return (
            server,
            stripTrailingSlash(services.shareBaseURL ?? configured("SHARE_BASE_URL") ?? "\(server)/share"),
            (services.cdnBaseURL ?? configured("CDN_BASE_URL")).map(stripTrailingSlash)
        )
    }
    let host = request.headers[HTTPField.Name("Host")!] ?? "localhost"
    let server = stripTrailingSlash(configured("SERVER_URL") ?? "http://\(host)")
    return (
        server,
        stripTrailingSlash(services.shareBaseURL ?? configured("SHARE_BASE_URL") ?? "\(server)/share"),
        (services.cdnBaseURL ?? configured("CDN_BASE_URL")).map(stripTrailingSlash)
    )
}

private struct MultipartPart {
    var name: String?
    var filename: String?
    var mimeType: String?
    var data: Data
}

private func multipartParts(data: Data, boundary: String) -> [MultipartPart] {
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
    var parts: [MultipartPart] = []
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
        parts.append(MultipartPart(name: name, filename: filename, mimeType: mimeType, data: Data(body)))
    }
    return parts
}

private func parseShareArtifactMultipart(data: Data, boundary: String) -> (channelId: String?, image: (bytes: Data, sizeBytes: Int)?) {
    var channelId: String?
    var image: (bytes: Data, sizeBytes: Int)?
    for part in multipartParts(data: data, boundary: boundary) {
        if part.name == "channelId" {
            let value = String(decoding: part.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            channelId = value.isEmpty ? nil : value
        } else if part.name == "image" {
            image = (bytes: part.data, sizeBytes: part.data.count)
        }
    }
    return (channelId, image)
}

private func publishFamilyRevoke(body: String, services: FallbackServices) {
    guard let hub = services.realtime,
          let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
          let capability = object["capability"] as? String,
          let target = services.emailAccounts.familyRevokeTarget(capability: capability)
    else { return }
    hub.revokeFamily(userId: target.userId, familyId: target.familyId)
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
