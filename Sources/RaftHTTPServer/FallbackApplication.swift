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
    NotificationsFeature(services: services).register(routes: app)
    ServersFeature(services: services).register(routes: app)
    ChannelsFeature(services: services).register(routes: app)
    MessagingFeature(services: services).register(routes: app)
    OAuthFeature(services: services).register(routes: app)
    FeedbackFeature(services: services).register(routes: app)
    TranslationFeature(services: services).register(routes: app)
    PublicFeature(services: services).register(routes: app)
    AuthFeature(services: services).register(routes: app)
    services.emailAccounts.onAgentReadUpdated = { serverId, channelId, agentId, maxReadSeq in
        services.emailAccounts.emitAgentScopeRead(
            serverId: serverId,
            channelId: channelId,
            agentId: agentId,
            maxReadSeq: maxReadSeq
        )
    }
    // The claimed `/internal/computer/` prefix fails closed for paths the
    // surface registry does not know, instead of leaking a routing 404.
    for method in [HTTPRequest.Method.get, .post, .put, .patch, .delete] {
        app.on(method, "internal", "computer", "**") { request -> Response in
            routeResponse(services.emailAccounts.unregisteredInternalComputerSurface(
                authorization: request.headers[.authorization]
            ))
        }
    }
    // The claimed agent principal prefixes fail closed the same way. A route
    // that exists without a policy entry must not look like an unmounted 404.
    for method in [HTTPRequest.Method.get, .post, .put, .patch, .delete] {
        app.on(method, "internal", "agent-api", "**") { request -> Response in
            routeResponse(services.emailAccounts.unregisteredInternalAgentSurface(
                authorization: request.headers[.authorization]
            ))
        }
        app.on(method, "internal", "agent", "**") { request -> Response in
            routeResponse(services.emailAccounts.unregisteredInternalAgentSurface(
                authorization: request.headers[.authorization]
            ))
        }
    }


    // The resumable control manifest is the one JSON surface allowed past the
    // 100 KB global parser: 512 KB manifest plus envelope headroom.
    var middleware = Middlewares()
    internalSurface.set(InternalSurfacePolicy.snapshot(routes: app.routes.all))
    middleware.use(JSONErrorBoundaryMiddleware())
    middleware.use(ExperimentalSurfaceGate(directory: services.emailAccounts))
    middleware.use(RequestBodyLimitMiddleware(accounts: services.emailAccounts))
    middleware.use(BufferedRequestBodyMiddleware())
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
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[HTTPField.Name("Cache-Control")!] = "no-store"
        return Response(status: httpStatus(status), headers: headers, body: .init(string: "{\"error\":\"Public search service access refused\",\"code\":\"\(code)\"}"))
    }

    private func serviceLimited(_ retryAfter: Int) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[HTTPField.Name("Cache-Control")!] = "no-store"
        headers[HTTPField.Name("Retry-After")!] = String(retryAfter)
        return Response(status: .tooManyRequests, headers: headers, body: .init(string: "{\"error\":\"Public search service rate limit exceeded\",\"code\":\"service_rate_limited\"}"))
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

private func jsonString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(text.dropFirst().dropLast())
}

private func reminderIdFromReply(_ reply: HTTPReply) -> String? {
    guard reply.status == 200, let data = reply.body.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let reminder = object["reminder"] as? [String: Any]
    else { return nil }
    return reminder["reminderId"] as? String ?? reminder["id"] as? String
}

private func publishReminderEvent(
    _ reply: HTTPReply, event: String, reminderId: String, agentId: String, services: FallbackServices
) {
    guard reply.status == 200, let hub = services.realtime,
          let agent = services.emailAccounts.oauth.agentRuntimeInfo(id: agentId)
    else { return }
    var recipients: Set<String> = []
    if let creator = agent.creatorUserId { recipients.insert(creator) }
    for member in services.emailAccounts.serverMemberRoles(serverId: agent.serverId)
    where member.role == "owner" || member.role == "admin" {
        recipients.insert(member.userId)
    }
    guard !recipients.isEmpty else { return }
    let payload = "{\"reminderId\":\(jsonString(reminderId)),\"ownerAgentId\":\(jsonString(agentId))}"
    for userId in recipients {
        hub.emit(room: "user:\(userId)", event: event, payloadJSON: payload)
    }
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
