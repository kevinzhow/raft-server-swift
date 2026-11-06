import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// Anonymous public server reads. Typed outcomes retain the published cache
/// policy; attachments carry their own file or redirect headers.
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
        server.get { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) { () throws -> any JSONBodyConvertible in
                let slug = request.parameters.get("slug") ?? ""
                if let directory = services.publicVisits {
                    return try directory.page(
                        slug: slug,
                        country: request.headers[HTTPField.Name("CloudFront-Viewer-Country")!],
                        region: request.headers[HTTPField.Name("CloudFront-Viewer-Country-Region")!],
                        gpc: request.headers[HTTPField.Name("Sec-GPC")!]
                    )
                }
                if let directory = services.publicServerDirectory {
                    return try directory.publicCard(slug: slug)
                }
                return try PublicVisits.pageReply(found: false, mode: nil)
            }
        }
        server.get("channels", ":channelId", "messages") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) { () throws -> any JSONBodyConvertible in
                let channelId = request.parameters.get("channelId") ?? ""
                guard let window = publicMessageWindow(request.url.query) else {
                    return try PublicVisits.pageReply(found: false, mode: nil)
                }
                if let directory = services.publicVisits, ServerScope.isUUID(channelId) {
                    return try directory.channelMessages(
                        slug: request.parameters.get("slug") ?? "",
                        channelId: channelId,
                        limit: window.limit,
                        beforeMessageId: window.before
                    )
                }
                throw PublicServerMessages.channel(channelId: channelId)
            }
        }
        server.get("attachments", ":attachmentId") { request async throws -> Response in
            try await respond(status: { $0.status }, headers: { $0.headers }) {
                let attachmentId = request.parameters.get("attachmentId") ?? ""
                let client = request.remoteAddress?.host ?? "unknown"
                if !services.publicAttachmentBudget.allow(ip: client) {
                    throw PublicAttachments.tooMany()
                }
                guard let directory = services.publicVisits else {
                    throw PublicAttachments.missing(attachmentId: attachmentId)
                }
                return try directory.publicAttachment(
                    slug: request.parameters.get("slug") ?? "",
                    attachmentId: attachmentId,
                    forceDownload: desktopQuery(request.url.query, "download") == "1",
                    inlineDisposition: desktopQuery(request.url.query, "disposition") == "inline",
                    frameAncestors: services.corsOrigins
                )
            }
        }
        server.get("threads", ":threadChannelId", "messages") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) { () throws -> any JSONBodyConvertible in
                let threadId = request.parameters.get("threadChannelId") ?? ""
                guard let window = publicMessageWindow(request.url.query) else {
                    return try PublicVisits.pageReply(found: false, mode: nil)
                }
                if let directory = services.publicVisits, ServerScope.isUUID(threadId) {
                    return try directory.threadMessages(
                        slug: request.parameters.get("slug") ?? "",
                        threadId: threadId,
                        limit: window.limit,
                        beforeMessageId: window.before
                    )
                }
                throw PublicServerMessages.thread(threadChannelId: threadId)
            }
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
