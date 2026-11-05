import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// Anonymous public server read routes from `routes/publicServer.ts`:
/// the public card, one channel's messages, one attachment, and one thread's
/// messages. Every handler is byte-for-byte the registration that used to live
/// in `configure`; the two query helpers were file-private there and are kept
/// file-private here so this feature is self-contained.
struct PublicFeature: RouteCollection {
    let services: FallbackServices

    init(services: FallbackServices) {
        self.services = services
    }

    func boot(routes: any RoutesBuilder) async throws {
    register(routes: routes)
    }

func register(routes: any RoutesBuilder) {
        let server = routes.grouped("api", "public", "servers", ":slug")
        server.get { request -> Response in
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
        server.get("channels", ":channelId", "messages") { request -> Response in
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
        server.get("attachments", ":attachmentId") { request -> Response in
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
        server.get("threads", ":threadChannelId", "messages") { request -> Response in
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
    }
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
