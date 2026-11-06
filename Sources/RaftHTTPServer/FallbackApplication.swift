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
    public var publicSearchServiceKeySource: (any PublicSearchServiceKeyProviding)?
    public var publicSearchServiceBucket: (any PublicSearchBucketStoring)?
    public var publicSearchServiceLimits: PublicSearchServiceLimits
    public var releaseNotes: [ReleaseNoteRecord]
    public var messageContext: MessageContextCatalog
    public var publicVisits: PublicVisitDirectory?
    public var publicAttachmentBudget: PublicAttachmentBudget
    public var publicTranslationBudget: PublicAttachmentBudget
    public var emailAccounts: EmailLoginDirectory
    public var realtime: RealtimeHub?
    /// Public share artifacts address themselves through one canonical page host
    /// and (optionally) a CDN host. Tests inject them; the process derives them
    /// from the deployment environment.
    public var serverBaseURL: String?
    public var shareBaseURL: String?
    public var cdnBaseURL: String?

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
        publicSearchServiceKeySource: (any PublicSearchServiceKeyProviding)? = nil,
        publicSearchServiceBucket: (any PublicSearchBucketStoring)? = nil,
        publicSearchServiceLimits: PublicSearchServiceLimits = PublicSearchServiceLimits(),
        releaseNotes: [ReleaseNoteRecord] = [],
        messageContext: MessageContextCatalog = MessageContextCatalog(),
        publicVisits: PublicVisitDirectory? = nil,
        publicAttachmentBudget: PublicAttachmentBudget = PublicAttachmentBudget(),
        publicTranslationBudget: PublicAttachmentBudget = PublicAttachmentBudget(),
        emailAccounts: EmailLoginDirectory = EmailLoginDirectory(),
        realtime: RealtimeHub? = nil,
        serverBaseURL: String? = nil,
        shareBaseURL: String? = nil,
        cdnBaseURL: String? = nil
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
        self.publicSearchServiceKeySource = publicSearchServiceKeySource
        self.publicSearchServiceBucket = publicSearchServiceBucket
        self.publicSearchServiceLimits = publicSearchServiceLimits
        self.releaseNotes = releaseNotes
        self.messageContext = messageContext
        self.publicVisits = publicVisits
        self.publicAttachmentBudget = publicAttachmentBudget
        self.publicTranslationBudget = publicTranslationBudget
        self.emailAccounts = emailAccounts
        self.realtime = realtime
        self.serverBaseURL = serverBaseURL
        self.shareBaseURL = shareBaseURL
        self.cdnBaseURL = cdnBaseURL
    }

    /// Channel-messaging domain: task creation plus the realtime frames the
    /// channel and task routes publish. The sinks and the not-yet-migrated
    /// channel/task policy calls are wired here, so the service file owns the
    /// orchestration without a directory or transport dependency.
    public var channelMessaging: ChannelMessagingService {
        let accounts = emailAccounts
        let hub = realtime
        return ChannelMessagingService(
            dependencies: ChannelMessagingDependencies(
                sessionUserId: { accounts.sessionUserId(authorization: $0) },
                memberRole: { serverId, userId in
                    accounts.oauth.memberRole(serverId: serverId, userId: userId)
                },
                taskChannelAccess: { serverId, channelId, userId in
                    DirectoryTaskCatalog(directory: accounts).channelTaskAccess(serverId: serverId, channelId: channelId, userId: userId)
                },
                isChannelArchived: { accounts.oauth.channelArchivedAt(id: $0) != nil },
                addTasks: { channelId, titles, descriptions, creatorId in
                    DirectoryTaskCatalog(directory: accounts).addTasks(
                        channelId: channelId,
                        titles: titles,
                        descriptions: descriptions,
                        creatorId: creatorId
                    )
                }
            ),
            sink: ChannelRealtimeSink(
                emit: { room, event, payload in
                    accounts.realtimeRelay.emit(room, event, payload)
                },
                emitToUser: { userId, event, payload in
                    hub?.emit(room: "user:\(userId)", event: event, payloadJSON: payload)
                },
                joinUserSessions: { userId, room in
                    hub?.joinUserSessions(userId: userId, room: room)
                }
            )
        )
    }
}

/// Canonical public bases for share artifacts. One page host (`SHARE_BASE_URL`,
/// falling back to `<server>/share`) and one optional image host
/// (`CDN_BASE_URL`, which addresses the stored object key directly).
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

private struct AttachmentUploadForm: Content {
    var channelId: String
    var files: [File]?
    var file: File?
}

private struct MultipartPart {
    var name: String?
    var filename: String?
    var mimeType: String?
    var data: Data
}

/// Splits a multipart body into named parts. Attachment uploads and share
/// artifacts differ only in which parts they require, so they share this parser.
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

private func parseAttachmentMultipart(data: Data, boundary: String) -> (channelId: String, files: [(filename: String, mimeType: String?, sizeBytes: Int, data: Data)])? {
    var channelId: String?
    var files: [(filename: String, mimeType: String?, sizeBytes: Int, data: Data)] = []
    for part in multipartParts(data: data, boundary: boundary) {
        if part.name == "channelId" {
            channelId = String(decoding: part.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let filename = part.filename, !filename.isEmpty {
            files.append((filename: filename, mimeType: part.mimeType, sizeBytes: part.data.count, data: part.data))
        }
    }
    guard let channelId, !channelId.isEmpty else { return nil }
    return (channelId, files)
}

/// Share creation needs the image even when `channelId` is missing, so the two
/// required fields are reported separately.
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

public func configure(_ app: Application, services: FallbackServices) {
    let internalSurface = InternalSurfaceBox()
    InternalAgentApiFeature(services: services).register(routes: app)
    InternalAdminFeature(services: services, internalSurface: internalSurface).register(routes: app)
    IntegrationsFeature(services: services).register(routes: app)
    AgentsFeature(services: services).register(routes: app)
    ComputersFeature(services: services).register(routes: app)
    RemindersFeature(services: services).register(routes: app)
    NotificationsFeature(services: services).register(routes: app)
    ServersFeature(services: services).register(routes: app)
    ChannelsFeature(services: services).register(routes: app)
    MessagingFeature(services: services).register(routes: app)
    OAuthFeature(services: services).register(routes: app)
    FeedbackFeature(services: services).register(routes: app)
    TranslationFeature(services: services).register(routes: app)
    PublicFeature(services: services).register(routes: app)
    AuthFeature(services: services).register(routes: app)
    KnowledgeFeature(services: services).register(routes: app)
    let readReceipts = services.emailAccounts.managedMCPToolExecution
    readReceipts.installReadUpdateObserver { serverId, channelId, agentId, maxReadSeq in
        readReceipts.emitAgentScopeRead(
            serverId: serverId,
            channelId: channelId,
            agentId: agentId,
            maxReadSeq: maxReadSeq
        )
    }
    // The claimed `/internal/computer/` prefix fails closed for paths the
    // surface registry does not know, instead of leaking a routing 404.
    for method in [HTTPRequest.Method.get, .post, .put, .patch, .delete] {
        app.on(method, "internal", "computer", "**") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentsLifecycle.unregisteredInternalComputerSurface(
                    authorization: request.headers[.authorization]
                )
            }
        }
    }
    // The claimed agent principal prefixes fail closed the same way. A route
    // that exists without a policy entry must not look like an unmounted 404.
    for method in [HTTPRequest.Method.get, .post, .put, .patch, .delete] {
        app.on(method, "internal", "agent-api", "**") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentsLifecycle.unregisteredInternalAgentSurface(
                    authorization: request.headers[.authorization]
                )
            }
        }
        app.on(method, "internal", "agent", "**") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentsLifecycle.unregisteredInternalAgentSurface(
                    authorization: request.headers[.authorization]
                )
            }
        }
    }


    // The resumable control manifest is the one JSON surface allowed past the
    // 100 KB global parser: 512 KB manifest plus envelope headroom.
    var middleware = Middlewares()
    internalSurface.set(InternalSurfacePolicy.snapshot(routes: app.routes.all))
    middleware.use(JSONErrorBoundaryMiddleware())
    middleware.use(ExperimentalSurfaceGate(directory: services.emailAccounts))
    middleware.use(RequestBodyLimitMiddleware(accounts: services.emailAccounts))
    middleware.use(CorsMiddleware(origins: services.corsOrigins))
    middleware.use(PublicSearchMiddleware(
        indexEnabled: services.publicSearchIndexEnabled,
        catalog: services.publicSearch,
        directory: services.publicServerDirectory,
        serviceKeySource: services.publicSearchServiceKeySource,
        serviceBucket: services.publicSearchServiceBucket,
        serviceLimits: services.publicSearchServiceLimits
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
    var serviceKeySource: (any PublicSearchServiceKeyProviding)?
    var serviceBucket: (any PublicSearchBucketStoring)?
    var serviceLimits: PublicSearchServiceLimits

    private func serviceRefusal(_ status: Int, _ code: String) -> Response {
        RaftHTTPServer.respond(
            status: UInt(status),
            headers: .exact(["Content-Type": "application/json", "Cache-Control": "no-store"]),
            rawJSON: OrderedJSON.object([
                OrderedJSONField("code", code),
                OrderedJSONField("error", "Public search service access refused"),
            ]).render()
        )
    }

    private func serviceLimited(_ retryAfter: Int) -> Response {
        RaftHTTPServer.respond(
            status: 429,
            headers: .exact([
                "Content-Type": "application/json", "Cache-Control": "no-store", "Retry-After": String(retryAfter),
            ]),
            rawJSON: OrderedJSON.object([
                OrderedJSONField("code", "service_rate_limited"),
                OrderedJSONField("error", "Public search service rate limit exceeded"),
            ]).render()
        )
    }

    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        guard PublicSearch.isSearchPath(request.url.path) else {
            return try await next.respond(to: request)
        }
        var releaseServiceSlot: (() -> Void)?
        defer { releaseServiceSlot?() }
        let credential = PublicSearchServiceAccess.classify(
            authorization: request.headers[HTTPField.Name("Authorization")!],
            keySource: serviceKeySource
        )
        if let refusal = PublicSearchServiceAccess.refusal(credential) {
            return serviceRefusal(refusal.status, refusal.code)
        }
        if case .service = credential {
            guard serviceLimits.ratePerMinute > 0, serviceLimits.maxInFlight > 0 else {
                return serviceRefusal(503, "service_unavailable")
            }
            guard let serviceBucket else { return serviceRefusal(503, "service_unavailable") }
            switch serviceBucket.consume(limit: serviceLimits.ratePerMinute) {
            case .allowed: break
            case .rateLimited(let retryAfter): return serviceLimited(retryAfter)
            case .unavailable: return serviceRefusal(503, "service_unavailable")
            }
            if let gating = serviceBucket as? any PublicSearchInFlightGating {
                guard gating.acquire(max: serviceLimits.maxInFlight) else { return serviceLimited(1) }
                releaseServiceSlot = { gating.release() }
            }
        }
        let method = request.method.rawValue
        if request.method != .get && request.method != .head {
            return try await RaftHTTPServer.respond { () throws -> NoContentResponse in
                throw PublicSearch.methodNotAllowed(method: method)
            }
        }
        let enabled = directory?.searchIndexEnabled ?? indexEnabled
        let current = directory?.projectedCatalog() ?? catalog
        do {
            if let payload = try PublicSearch.route(
                method: method,
                path: request.url.path,
                cursor: desktopQuery(request.url.query, "cursor"),
                indexEnabled: enabled,
                catalog: current
            ) {
                let response = try await RaftHTTPServer.respond(headers: .standard(extra: ["Cache-Control": "no-store"])) { payload }
                return publicSearchResponse(response, isHead: payload.isHead)
            }
        } catch let error as PublicSearchError {
            let response = try await RaftHTTPServer.respond { () throws -> NoContentResponse in throw error }
            return publicSearchResponse(response, isHead: error.isHead)
        }
        var response = try await next.respond(to: request)
        response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
        return response
    }
}

/// HEAD keeps the GET entity length even though Vapor resets it when the body
/// changes. Service credential refusals above keep their own legacy behavior.
private func publicSearchResponse(_ response: Response, isHead: Bool) -> Response {
    guard isHead else { return response }
    var response = response
    let length = response.headers[.contentLength]
    response.body = .init(string: "")
    response.headers[.contentLength] = length
    return response
}

private struct ExperimentalSurfaceGate: Middleware {
    let directory: EmailLoginDirectory

    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        let path = request.url.path
        let isExperimental = path.hasPrefix("/internal/agent-api") || path.hasPrefix("/internal/computer")
        if isExperimental, DirectoryRuntimePolicy(directory: directory).experimentalSurfacesDisabled {
            return RaftHTTPServer.respond(
                status: 503,
                headers: .exact(["Content-Type": "application/json", "Sec-Slock-Api-Version": "1"]),
                rawJSON: OrderedJSON.object([
                    OrderedJSONField("code", "experimental_surface_disabled"),
                    OrderedJSONField("error", "Experimental internal surface is disabled"),
                    OrderedJSONField("retry_after", .null),
                ]).render()
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
    respond(status: UInt(status), rawJSON: OrderedJSON.object([OrderedJSONField("error", error)]).render())
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

/// Reader for one percent-decoded query parameter. Shared by the route
/// features so the projection is identical on every mounted surface.
func desktopQuery(_ query: String?, _ name: String) -> String? {
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

extension Request {
    /// Reads the request body asynchronously without requiring a global buffering
    /// middleware, working identically under `app.testing` and live NIO streams.
    func bodyText(default fallback: String = "") async throws -> String {
        if let buffered = body.string {
            return buffered
        }
        guard let data = try await body.collect() else {
            return fallback
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Shared `HTTPReply` → Vapor `Response` adapter. Copies the reply headers,
/// maps the status through `httpStatus`, and restores the HEAD Content-Length
/// the `Response` initializer would drop.
func vaporResponse(_ reply: HTTPReply) -> Response {
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

/// A 200 HTML preview: streamed so the response carries no stored Content-Length.
private func vaporStreamingResponse(_ reply: HTTPReply) -> Response {
    var headers = HTTPFields()
    for (name, value) in reply.headers {
        guard let field = HTTPField.Name(name) else { continue }
        if field == .contentLength { continue }
        headers[field] = value
    }
    var response = Response(status: httpStatus(reply.status), headers: headers)
    let body = reply.body
    response.body = Response.Body { writer in
        try await writer.write(body)
    }
    return response
}

private let robotsTagName = HTTPField.Name("X-Robots-Tag")!

/// One `Int` → `HTTPResponse.Status` mapping for every `HTTPReply` adapter
/// in the module.
func httpStatus(_ code: Int) -> HTTPResponse.Status {
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
