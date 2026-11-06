import HTTPTypes
import RaftHTTP
import Vapor

/// `message-translations:batch` routes extracted from `FallbackApplication.configure`.
///
/// Two registrations:
/// - `POST /api/message-translations:batch` — member batch translation, read
///   from `X-Server-Id` and `ServerProfileAndOrderService.batchTranslateMessages`.
/// - `POST /api/public/servers/:slug/message-translations:batch` — anonymous
///   public batch. The per-IP `publicTranslationBudget` is spent before any
///   gate or lookup, so a malformed body is a 400 until the budget runs out.
///
/// The handlers are byte-for-byte the registrations that used to live in
/// `configure`; the integration slice replaces those inline registrations with
/// `app.register(collection: TranslationFeature(services: services))`.
struct TranslationFeature: RouteCollection {
    let services: FallbackServices

    init(services: FallbackServices) {
        self.services = services
    }

    func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    func register(routes: any RoutesBuilder) {
        let api = routes.grouped("api")
        let publicServer = routes.grouped("api", "public", "servers", ":slug")
        api.post("message-translations:batch") { request async throws -> Response in
            let body = await jsonRequestBody(MessageTranslationBatchRequest.self, request)
            return try await respond {
                try services.emailAccounts.serverProfileAndOrder.batchTranslateMessages(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
            }
        }
        publicServer.post("message-translations:batch") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) {
                let client = request.remoteAddress?.host ?? "unknown"
                if !services.publicTranslationBudget.allow(ip: client) {
                    throw PublicTranslations.tooMany()
                }
                let slug = request.parameters.get("slug") ?? ""
                return try PublicTranslations.reply(
                    body: try await request.bodyText(),
                    gate: services.publicVisits?.translationGate(slug: slug),
                    translator: services.publicVisits.map { visits in
                        { ids, target in visits.publicTranslationResults(slug: slug, targetLanguage: target, messageIds: ids) }
                    }
                )
            }
        }
    }
}
