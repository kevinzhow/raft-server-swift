import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// Remaining small route families extracted from `FallbackApplication.configure`:
/// notifications, push, announcements, product events, release notes, downloads,
/// feature flags, public visits, share artifacts and files, avatars, reminders,
/// email, Slack bridge, computer, agents, v2 messages, version, and the leftover
/// `api/*` surface not owned by the earlier feature collections.
///
/// Every registration below is copied verbatim from the inline `configure` block:
/// same method, path, request projection and `routeResponse` call. `register` is
/// synchronous because the application mount is synchronous; `boot` adapts it to
/// `RouteCollection`. The three private helpers that cannot live in another file
/// (`desktopQuery`, the share-artifact base resolution and multipart parsing, the
/// release/download response adapters) are copied with their original bodies.
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
        app.post("api", "agent", "login") { request -> Response in
            routeResponse(services.emailAccounts.agentLogin(
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
        app.delete("api", "agents", ":id") { request -> Response in
            routeResponse(services.emailAccounts.deleteAgentRoute(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        app.get("api", "agents", ":id") { request -> Response in
            routeResponse(services.emailAccounts.getAgentRoute(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        app.patch("api", "agents", ":id") { request -> Response in
            routeResponse(services.emailAccounts.patchAgent(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
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
                surface: "activity-log",
                query: request.url.query
            ))
        }
        app.get("api", "agents", ":id", "activity-summaries") { request -> Response in
            routeResponse(services.emailAccounts.agentPrivateSurface(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                surface: "activity-summaries",
                query: request.url.query
            ))
        }
        app.get("api", "agents", ":id", "agent-dms") { request -> Response in
            routeResponse(services.emailAccounts.agentDirectMessages(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? ""
            ))
        }
        app.get("api", "agents", ":id", "archive") { request -> Response in
            routeResponse(services.emailAccounts.agentArchiveView(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
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
        app.post("api", "agents", ":id", "assign-machine") { request -> Response in
            routeResponse(services.emailAccounts.assignAgentMachine(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
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
        app.put("api", "agents", ":id", "assistant-owner") { request -> Response in
            routeResponse(services.emailAccounts.agentAssistantOwner(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                method: "PUT"
            ))
        }
        app.post("api", "agents", ":id", "avatar") { request -> Response in
            routeResponse(services.emailAccounts.uploadAgentAvatar(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                byteCount: request.body.string?.utf8.count ?? 0
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
        app.get("api", "agents", ":id", "channels") { request -> Response in
            routeResponse(services.emailAccounts.agentChannels(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? ""
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
        app.put("api", "agents", ":id", "connections", ":provider") { request -> Response in
            connectionResponse(services.emailAccounts.assignAgentConnection(
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
        app.delete("api", "agents", ":id", "connections", ":provider", "connectors", ":connectorId") { request -> Response in
            connectionResponse(services.emailAccounts.disconnectAgentConnector(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                provider: request.parameters.get("provider") ?? "",
                connectorId: request.parameters.get("connectorId") ?? ""
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
        app.get("api", "agents", ":id", "credentials") { request -> Response in
            var response = routeResponse(services.emailAccounts.listAgentCredentials(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? ""
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
            return response
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
        app.get("api", "agents", ":id", "external-diagnostics") { request -> Response in
            routeResponse(services.emailAccounts.externalAgentDiagnostics(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? ""
            ))
        }
        app.get("api", "agents", ":id", "external-status") { request -> Response in
            routeResponse(services.emailAccounts.externalAgentStatus(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? ""
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
        app.post("api", "agents", ":id", "migrate") { request -> Response in
            routeResponse(services.emailAccounts.agentRuntimeAction(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                action: "migrate",
                body: request.body.string ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        app.get("api", "agents", ":id", "migration") { request -> Response in
            routeResponse(services.emailAccounts.agentMigrationStatus(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? ""
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
        app.post("api", "agents", ":id", "reset") { request -> Response in
            routeResponse(services.emailAccounts.agentRuntimeAction(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                action: "reset",
                body: request.body.string ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
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
        app.get("api", "agents", ":id", "runtime-options") { request -> Response in
            routeResponse(services.emailAccounts.agentRuntimeOptions(
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
        app.get("api", "agents", ":id", "skills") { request -> Response in
            let hasReplayHeaders = request.headers[HTTPField.Name("X-Raft-Replica-Replay")!] != nil
                || request.headers[HTTPField.Name("X-Raft-Replica-Replay-Machine")!] != nil
                || request.headers[HTTPField.Name("X-Raft-Replica-Replay-Timestamp")!] != nil
                || request.headers[HTTPField.Name("X-Raft-Replica-Replay-Signature")!] != nil
            return routeResponse(services.emailAccounts.agentPrivateSurface(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                surface: "skills",
                hasReplayHeaders: hasReplayHeaders
            ))
        }
        app.post("api", "agents", ":id", "start") { request -> Response in
            routeResponse(services.emailAccounts.agentRuntimeAction(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                action: "start",
                body: request.body.string ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        app.post("api", "agents", ":id", "stop") { request -> Response in
            routeResponse(services.emailAccounts.agentRuntimeAction(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                action: "stop",
                body: request.body.string ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        app.get("api", "agents", ":id", "workspace-files") { request -> Response in
            routeResponse(services.emailAccounts.agentWorkspaceFiles(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                query: request.url.query
            ))
        }
        app.get("api", "agents", ":id", "workspace-files", "read") { request -> Response in
            routeResponse(services.emailAccounts.agentWorkspaceRead(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                query: request.url.query
            ))
        }
        app.get("api", "agents", "archived") { request -> Response in
            routeResponse(services.emailAccounts.listArchivedAgents(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        app.get("api", "agents", "manageable") { request -> Response in
            routeResponse(services.emailAccounts.manageableAgentList(
                authorization: request.headers[.authorization]
            ))
        }
        app.post("api", "announcements", ":announcementId", "dismiss") { request -> Response in
            routeResponse(services.emailAccounts.dismissAnnouncement(
                authorization: request.headers[.authorization],
                announcementId: request.parameters.get("announcementId") ?? "",
                query: request.url.query,
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        app.get("api", "announcements", "active") { request -> Response in
            routeResponse(services.emailAccounts.activeAnnouncements(
                authorization: request.headers[.authorization],
                after: desktopQuery(request.url.query, "after"),
                query: request.url.query
            ))
        }
        app.get("api", "announcements", "images", ":imageId") { request -> Response in
            routeResponse(services.emailAccounts.announcementImage(id: request.parameters.get("imageId") ?? ""))
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
        app.post("api", "computer", "adopt-legacy") { request -> Response in
            routeResponse(services.emailAccounts.adoptLegacyComputer(
                authorization: request.headers[.authorization],
                body: request.body.string ?? "{}"
            ))
        }
        app.post("api", "computer", "attach") { request -> Response in
            routeResponse(services.emailAccounts.attachComputer(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        app.get("api", "computer", "legacy-machines") { request -> Response in
            routeResponse(services.emailAccounts.legacyMachines(
                authorization: request.headers[.authorization],
                serverSlug: desktopQuery(request.url.query, "serverSlug"),
                includeAll: desktopQuery(request.url.query, "includeAll") == "1"
            ))
        }
        app.get("api", "desktop-download") { request async in
            routeResponse(await DesktopDownload.downloadReply(
                target: desktopQuery(request.url.query, "target"),
                deps: services.desktop
            ))
        }
        app.get("api", "desktop-download", "platforms") { _ async in
            routeResponse(await DesktopDownload.platformsReply(services.desktop))
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
        app.get("api", "external-avatars", ":file") { request -> Response in
            routeResponse(services.emailAccounts.externalAvatar(file: request.parameters.get("file") ?? ""))
        }
        app.post("api", "feature-flags", "evaluate") { request -> Response in
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
        app.delete("api", "notifications", "credentials", "current") { request -> Response in
            routeResponse(services.emailAccounts.deleteCurrentNativeNotificationCredential(
                authorization: request.headers[.authorization]
            ))
        }
        app.post("api", "notifications", "credentials", "rotate") { request -> Response in
            routeResponse(services.emailAccounts.rotateNativeNotificationCredential(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
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
        app.post("api", "notifications", "enrollment-exchanges") { request -> Response in
            routeResponse(services.emailAccounts.exchangeNativeEnrollmentGrant(body: request.body.string ?? ""))
        }
        app.post("api", "notifications", "enrollment-grants") { request -> Response in
            routeResponse(services.emailAccounts.issueNativeEnrollmentGrant(
                body: request.body.string ?? "",
                authorization: request.headers[.authorization]
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
        app.post("api", "product-events", "batch") { request -> Response in
            routeResponse(services.emailAccounts.clientEventsBatch(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                userAgent: request.headers[HTTPField.Name("User-Agent")!] ?? "",
                country: request.headers[HTTPField.Name("CloudFront-Viewer-Country")!] ?? "",
                body: request.body.string ?? ""
            ))
        }
        app.get("api", "product-events", "config") { request -> Response in
            routeResponse(services.emailAccounts.clientEventsConfig(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        app.post("api", "product-events", "onboarding-wizard") { request -> Response in
            routeResponse(services.emailAccounts.recordOnboardingWizard(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? ""
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
        app.get("api", "public", "feature-flags") { request in
            routeResponse(PublicFeatureFlags.reply(
                keysQuery: desktopQuery(request.url.query, "keys"),
                platformQuery: desktopQuery(request.url.query, "platform"),
                flags: services.featureFlags
            ))
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
        app.get("api", "push", "delivery-status") { request -> Response in
            routeResponse(services.emailAccounts.pushDeliveryStatus(
                authorization: request.headers[.authorization],
                installationId: desktopQuery(request.url.query, "installationId")
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
        app.post("api", "push", "registrations") { request -> Response in
            routeResponse(services.emailAccounts.registerPushDevice(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? ""
            ))
        }
        app.delete("api", "push", "registrations", ":installationId") { request -> Response in
            routeResponse(services.emailAccounts.unbindPushInstallation(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                installationId: request.parameters.get("installationId") ?? ""
            ))
        }
        app.post("api", "push", "subscribe") { request -> Response in
            routeResponse(services.emailAccounts.recordWebPushSubscription(
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
        app.get("api", "reminders") { request -> Response in
            routeResponse(services.emailAccounts.listReminders(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                ownerAgentId: desktopQuery(request.url.query, "ownerAgentId")
            ))
        }
        app.post("api", "share-artifacts", "message-selection") { request async throws -> Response in
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
        app.post("api", "slack-bridge", "events") { _ -> Response in
            routeResponse(services.emailAccounts.slackBridgeUnavailable())
        }
        app.get("api", "slack-bridge", "oauth", "callback") { _ -> Response in
            routeResponse(services.emailAccounts.slackBridgeUnavailable())
        }
        app.post("api", "slack-bridge", "oauth", "start") { _ -> Response in
            routeResponse(services.emailAccounts.slackBridgeUnavailable())
        }
        app.get("api", "slack-bridge", "provisioning") { _ -> Response in
            routeResponse(services.emailAccounts.slackBridgeUnavailable())
        }
        app.post("api", "v2", "messages") { request -> Response in
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
