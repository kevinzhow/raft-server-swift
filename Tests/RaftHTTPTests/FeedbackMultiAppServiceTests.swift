import Foundation
import RaftShared
import Synchronization
import Testing
@testable import RaftHTTP

/// The ticket service's own contracts: the exact legacy error bytes and header
/// sets, the authorization-before-validation order, what is relayed to Hands
/// (path, headers, body) and the byte-exact cursor re-wrapping. The HTTP tests
/// lock the wire projection.

private let cursorSecret = "multi-cursor-secret"
private let appId = "a48a84f8-04ed-4db3-9297-189a14a36afc"
private let ticketId = "33333333-3333-4333-8333-333333333333"
private let attachmentId = "55555555-5555-4555-8555-555555555555"

private func makeEnvironment(cursorSecret: String = cursorSecret) -> FeedbackRouteEnvironment {
    FeedbackRouteEnvironment(
        baseURL: "https://hands.test",
        appSlug: "raft-feedback-android",
        appId: appId,
        clientKey: "qk",
        appToken: "app-token",
        conversationToken: "",
        credentialRevision: "1",
        reporterIntegrationId: "legacy",
        reporterIdSecret: "secret",
        routeSubjectKeyId: "v1",
        routeSubjectRoot: "",
        routeCommitmentScope: "multi",
        cursorSecret: cursorSecret,
        conversationSessionEnabled: false,
        isMultiApp: true
    )
}

/// Records every call so a test can assert what the service did and in what
/// order, without any directory state.
private final class Recorder: Sendable {
    struct Relayed: Sendable {
        var method: String
        var path: String
        var bearer: String
        var reporterId: String
        var headers: [String: String]
        var body: String?
    }

    private let state = Mutex(State())
    struct State {
        var events: [String] = []
        var relayed: [Relayed] = []
        var warnings: [String] = []
    }

    var events: [String] { state.withLock { $0.events } }
    var relayed: [Relayed] { state.withLock { $0.relayed } }
    var warnings: [String] { state.withLock { $0.warnings } }

    func event(_ value: String) { state.withLock { $0.events.append(value) } }
    func relay(_ value: Relayed) { state.withLock { $0.relayed.append(value) } }
    func warn(_ value: String) { state.withLock { $0.warnings.append(value) } }
}

private struct Behavior: Sendable {
    var userId: String? = "user-1"
    var verified = true
    var environment: FeedbackRouteEnvironment = makeEnvironment()
    var environmentFailure: (any Error & Sendable)?
    var bindingFailure: (any Error & Sendable)?
    var bearerFailure: (any Error & Sendable)?
    var upstream: FeedbackMultiAppDependencies.Upstream = (200, [:], Data("{}".utf8))
}

private let clock = Date(timeIntervalSince1970: 1_700_000_000)

private func service(_ behavior: Behavior = Behavior(), _ recorder: Recorder = Recorder()) -> FeedbackMultiAppService {
    FeedbackMultiAppService(dependencies: FeedbackMultiAppDependencies(
        userId: { authorization in
            recorder.event("session")
            return authorization == nil ? nil : behavior.userId
        },
        emailVerified: { _ in
            recorder.event("verified")
            return behavior.verified
        },
        routeEnvironment: { source, _ in
            recorder.event("environment:\(source)")
            if let failure = behavior.environmentFailure { throw failure }
            return behavior.environment
        },
        ensureRouteBinding: { userId, _ in
            recorder.event("binding")
            if let failure = behavior.bindingFailure { throw failure }
            return "reporter-\(userId)"
        },
        bearer: { _, _, _ in
            recorder.event("bearer")
            if let failure = behavior.bearerFailure { throw failure }
            return "bearer-token"
        },
        handsRequest: { _, method, path, bearer, reporterId, headers, body in
            recorder.event("relay")
            recorder.relay(Recorder.Relayed(
                method: method,
                path: path,
                bearer: bearer,
                reporterId: reporterId,
                headers: headers,
                body: body.map { String(decoding: $0, as: UTF8.self) }
            ))
            return behavior.upstream
        },
        warn: { recorder.warn($0) },
        now: { clock }
    ))
}

private func errorOf(_ operation: () async throws -> FeedbackHandsReply) async -> FeedbackMultiAppError? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return error as? FeedbackMultiAppError
    }
}

// MARK: - Error contract

@Test func feedbackMultiAppErrorsKeepTheLegacyBodiesAndHeaders() {
    let cases: [(FeedbackMultiAppError, UInt, String)] = [
        (.unauthorized, 401, #"{"error":"Unauthorized"}"#),
        (.accountUnverified, 403, #"{"error":"Email verification required","code":"account_unverified"}"#),
        (.invalidRequest, 400, #"{"error":"Invalid feedback request","code":"feedback_invalid"}"#),
        (.closeReasonInvalid, 400, #"{"error":"Feedback close reason is invalid","code":"feedback_invalid"}"#),
        (.attachmentTypeInvalid, 400, #"{"error":"Only image attachments are supported","code":"feedback_attachment_type_invalid"}"#),
        (.ticketNotFound, 404, #"{"error":"Feedback ticket not found","code":"feedback_not_found"}"#),
        (.routeNotFound, 404, #"{"error":"Not found"}"#),
        (.commentConflict, 409, #"{"error":"This comment retry does not match the original submission","code":"feedback_comment_conflict"}"#),
        (.rateLimited(retryAfter: "7"), 429, #"{"error":"Too many feedback requests. Please try again later.","code":"feedback_rate_limited"}"#),
        (.integrationUnavailable, 503, #"{"error":"Feedback service is temporarily unavailable","code":"feedback_integration_unavailable"}"#),
        (.integrationUnavailableRetryable(retryAfter: "5"), 503, #"{"error":"Feedback service is temporarily unavailable","code":"feedback_integration_unavailable"}"#),
        (.serviceUnavailable, 503, #"{"error":"Feedback service is temporarily unavailable","code":"feedback_service_unavailable"}"#),
    ]
    for (error, status, body) in cases {
        #expect(error.status == status)
        #expect(error.publishedErrorBody.render() == body)
    }
    #expect(FeedbackMultiAppError.unauthorized.errorHeaders == .standard())
    #expect(FeedbackMultiAppError.rateLimited(retryAfter: "7").errorHeaders == .exact([
        "Content-Type": AppFallback.jsonContentType,
        "Cache-Control": "no-store",
        "Retry-After": "7",
    ]))
    #expect(FeedbackMultiAppError.integrationUnavailableRetryable(retryAfter: "5").errorHeaders == .exact([
        "Content-Type": AppFallback.jsonContentType,
        "Cache-Control": "no-store",
        "Retry-After": "5",
    ]))
}

// MARK: - Authorization order

@Test func feedbackMultiAppAuthorizesBeforeAnyValidationOrUpstreamWork() async {
    let anonymous = Recorder()
    let unauthorized = await errorOf {
        try await service(Behavior(), anonymous).closeTicket(
            authorization: nil, ticketId: "not-a-uuid", request: nil
        )
    }
    #expect(unauthorized == .unauthorized)
    #expect(anonymous.events == ["session"])

    let unverified = Recorder()
    let blocked = await errorOf {
        try await service(Behavior(verified: false), unverified).ticket(
            authorization: "Bearer t", ticketId: "not-a-uuid", commentLimit: 0
        )
    }
    #expect(blocked == .accountUnverified)
    #expect(unverified.events == ["session", "verified"])
}

@Test func feedbackMultiAppValidatesTheTicketBeforeTheRequestBodyAndBeforeTheSource() async {
    let recorder = Recorder()
    let notFound = await errorOf {
        try await service(Behavior(), recorder).closeTicket(
            authorization: "Bearer t", ticketId: "not-a-uuid", request: nil, clientKindHeader: "symbian"
        )
    }
    #expect(notFound == .ticketNotFound)

    let reason = await errorOf {
        try await service(Behavior(), recorder).closeTicket(
            authorization: "Bearer t",
            ticketId: ticketId,
            request: FeedbackTicketCloseRequest(reason: "other"),
            clientKindHeader: "symbian"
        )
    }
    #expect(reason == .closeReasonInvalid)

    let missingBody = await errorOf {
        try await service(Behavior(), recorder).closeTicket(
            authorization: "Bearer t", ticketId: ticketId, request: nil
        )
    }
    #expect(missingBody == .closeReasonInvalid)

    let source = await errorOf {
        try await service(Behavior(), recorder).closeTicket(
            authorization: "Bearer t",
            ticketId: ticketId,
            request: FeedbackTicketCloseRequest(reason: "completed"),
            clientKindHeader: "symbian"
        )
    }
    #expect(source == .invalidRequest)
    #expect(!recorder.events.contains("relay"))
    #expect(!recorder.events.contains { $0.hasPrefix("environment") })

    let limit = await errorOf {
        try await service(Behavior(), recorder).ticket(
            authorization: "Bearer t", ticketId: ticketId, commentLimit: 101
        )
    }
    #expect(limit == .invalidRequest)
}

// MARK: - Failure mapping

@Test func feedbackMultiAppMapsRouteFailuresAndWarnsWithTheirReason() async {
    let source = Recorder()
    let unavailable = await errorOf {
        try await service(
            Behavior(environmentFailure: FeedbackRouteFailure.sourceUnavailable(source: "ohos", reason: "source_entry_missing")),
            source
        ).tickets(authorization: "Bearer t", clientKindHeader: "ios")
    }
    #expect(unavailable == .integrationUnavailable)
    #expect(source.warnings == ["[product-feedback] source unavailable (ohos: source_entry_missing)"])

    let binding = Recorder()
    let retryable = await errorOf {
        try await service(
            Behavior(bindingFailure: FeedbackRouteFailure.routeBinding(reason: "root_invalid")),
            binding
        ).tickets(authorization: "Bearer t")
    }
    #expect(retryable == .integrationUnavailableRetryable(retryAfter: "5"))
    #expect(binding.warnings == ["[product-feedback] route binding failed (root_invalid)"])
    #expect(!binding.events.contains("relay"))

    struct Boom: Error {}
    let generic = await errorOf {
        try await service(Behavior(environmentFailure: Boom())).tickets(authorization: "Bearer t")
    }
    #expect(generic == .integrationUnavailable)
    let bindingGeneric = await errorOf {
        try await service(Behavior(bindingFailure: Boom())).tickets(authorization: "Bearer t")
    }
    #expect(bindingGeneric == .serviceUnavailable)
    let bearer = await errorOf {
        try await service(Behavior(bearerFailure: FeedbackRouteFailure.configuration)).tickets(authorization: "Bearer t")
    }
    #expect(bearer == .serviceUnavailable)
    let invalidSource = await errorOf {
        try await service(Behavior(environmentFailure: FeedbackRouteFailure.invalidSource)).tickets(authorization: "Bearer t")
    }
    #expect(invalidSource == .invalidRequest)
}

@Test func feedbackMultiAppMapsTheUpstreamStatus() async {
    func outcome(_ status: Int, headers: [String: String] = [:]) async -> FeedbackMultiAppError? {
        await errorOf {
            try await service(Behavior(upstream: (status, headers, Data()))).closeTicket(
                authorization: "Bearer t",
                ticketId: ticketId,
                request: FeedbackTicketCloseRequest(reason: "completed")
            )
        }
    }
    #expect(await outcome(400) == .invalidRequest)
    #expect(await outcome(404) == .ticketNotFound)
    #expect(await outcome(409) == .commentConflict)
    #expect(await outcome(429) == .rateLimited(retryAfter: "60"))
    #expect(await outcome(429, headers: ["Retry-After": "12"]) == .rateLimited(retryAfter: "12"))
    #expect(await outcome(401) == .integrationUnavailable)
    #expect(await outcome(403) == .integrationUnavailable)
    #expect(await outcome(500) == .serviceUnavailable)
    #expect(await outcome(0) == .serviceUnavailable)
    #expect(await outcome(204) == .serviceUnavailable)
}

// MARK: - Relayed requests and replies

@Test func feedbackMultiAppListRelaysTheOwnPageAndStampsServerTiming() async throws {
    let recorder = Recorder()
    let body = #"{"tickets":[],"unread_total":0,"next_cursor":null}"#
    let reply = try await service(
        Behavior(upstream: (200, ["Server-Timing": "hands_list;dur=2.0, bogus;dur=1"], Data(body.utf8))),
        recorder
    ).tickets(authorization: "Bearer t")
    #expect(reply.status == 200)
    #expect(reply.body == body)
    #expect(reply.headers == .exact([
        "Content-Type": AppFallback.jsonContentType,
        "Cache-Control": "no-store",
        "Server-Timing": "raft_feedback_hands;dur=0.0, hands_list;dur=2.0",
    ]))
    #expect(recorder.events == ["session", "verified", "environment:web", "binding", "bearer", "relay"])
    let relayed = try #require(recorder.relayed.first)
    #expect(relayed.method == "GET")
    #expect(relayed.path == "/api/apps/\(appId)/reporter-feedback?limit=50")
    #expect(relayed.bearer == "bearer-token")
    #expect(relayed.reporterId == "reporter-user-1")
    #expect(relayed.headers.isEmpty)
    #expect(relayed.body == nil)
}

@Test func feedbackMultiAppListAnswersNotFoundWithoutCredentialsBeforeAnyUpstreamWork() async {
    var empty = makeEnvironment()
    empty.appToken = ""
    empty.conversationToken = ""
    let recorder = Recorder()
    let error = await errorOf {
        try await service(Behavior(environment: empty), recorder).tickets(authorization: "Bearer t")
    }
    #expect(error == .routeNotFound)
    #expect(!recorder.events.contains("binding"))
}

@Test func feedbackMultiAppRewrapsTheListCursorAndSortsTheKeys() async throws {
    let recorder = Recorder()
    let reply = try await service(
        Behavior(upstream: (200, [:], Data(#"{"tickets":[{"id":"a/b"}],"next_cursor":"hands-page-2","unread_total":3}"#.utf8))),
        recorder
    ).tickets(authorization: "Bearer t")
    let object = try #require(
        (try JSONSerialization.jsonObject(with: Data(reply.body.utf8))) as? [String: Any]
    )
    let wrapped = try #require(object["next_cursor"] as? String)
    #expect(wrapped != "hands-page-2")
    #expect(reply.body.hasPrefix(#"{"next_cursor":""#))
    #expect(reply.body.hasSuffix(#","tickets":[{"id":"a\/b"}],"unread_total":3}"#))
    #expect(try FeedbackRouting.feedbackDecodeCursor(
        wrapped, route: "ticket_list", userId: "user-1", ticketId: nil, cursorKey: cursorSecret
    ) == "hands-page-2")
    // The wrapped cursor is bound to its route, user and ticket.
    #expect(throws: (any Error).self) {
        try FeedbackRouting.feedbackDecodeCursor(
            wrapped, route: "ticket_comments", userId: "user-1", ticketId: nil, cursorKey: cursorSecret
        )
    }

    // The next request carries the unwrapped Hands cursor, percent-encoded.
    let next = Recorder()
    _ = try await service(Behavior(), next).tickets(authorization: "Bearer t", cursor: wrapped)
    #expect(next.relayed.first?.path == "/api/apps/\(appId)/reporter-feedback?limit=50&cursor=hands-page-2")

    // A cursor minted for another user is rejected before any relay.
    let foreign = Recorder()
    let error = await errorOf {
        try await service(Behavior(userId: "user-2"), foreign).tickets(authorization: "Bearer t", cursor: wrapped)
    }
    #expect(error == .invalidRequest)
    #expect(!foreign.events.contains("relay"))
}

@Test func feedbackMultiAppLeavesTheBodyUntouchedWithoutACursorSecretOrCursor() async throws {
    let raw = #"{"tickets":[],"next_cursor":"hands-page-2","unread_total":0}"#
    let noSecret = try await service(
        Behavior(environment: makeEnvironment(cursorSecret: ""), upstream: (200, [:], Data(raw.utf8)))
    ).tickets(authorization: "Bearer t")
    #expect(noSecret.body == raw)

    let nullCursor = #"{"tickets":[],"next_cursor":null,"unread_total":0}"#
    let reply = try await service(Behavior(upstream: (200, [:], Data(nullCursor.utf8)))).tickets(authorization: "Bearer t")
    #expect(reply.body == nullCursor)

    let invalidCursor = await errorOf {
        try await service(Behavior(environment: makeEnvironment(cursorSecret: ""))).tickets(
            authorization: "Bearer t", cursor: "anything"
        )
    }
    #expect(invalidCursor == .invalidRequest)
}

@Test func feedbackMultiAppDetailForwardsTheLimitAndRewrapsTheCommentCursor() async throws {
    let recorder = Recorder()
    let reply = try await service(
        Behavior(upstream: (200, [:], Data(#"{"next_comment_cursor":"c2","ticket":{"id":"x"}}"#.utf8))),
        recorder
    ).ticket(authorization: "Bearer t", ticketId: ticketId, commentLimit: 7)
    #expect(recorder.relayed.first?.path == "/api/apps/\(appId)/reporter-feedback/\(ticketId)?comment_limit=7")
    let object = try #require((try JSONSerialization.jsonObject(with: Data(reply.body.utf8))) as? [String: Any])
    let wrapped = try #require(object["next_comment_cursor"] as? String)
    #expect(try FeedbackRouting.feedbackDecodeCursor(
        wrapped, route: "ticket_comments", userId: "user-1", ticketId: ticketId, cursorKey: cursorSecret
    ) == "c2")
    #expect(reply.headers.values["Server-Timing"] == "raft_feedback_hands;dur=0.0")

    let next = Recorder()
    _ = try await service(Behavior(), next).ticket(
        authorization: "Bearer t", ticketId: ticketId, commentCursor: wrapped
    )
    #expect(next.relayed.first?.path
        == "/api/apps/\(appId)/reporter-feedback/\(ticketId)?comment_limit=50&comment_cursor=c2")
}

@Test func feedbackMultiAppRelaysANon200ListWithoutRewrappingOrTiming() async throws {
    let body = #"{"next_cursor":"hands-page-2","ok":true}"#
    let reply = try await service(Behavior(upstream: (201, [:], Data(body.utf8)))).tickets(authorization: "Bearer t")
    #expect(reply.status == 201)
    #expect(reply.body == body)
    #expect(reply.headers == .exact([
        "Content-Type": AppFallback.jsonContentType,
        "Cache-Control": "no-store",
    ]))
}

@Test func feedbackMultiAppCloseForwardsTheCanonicalBodyAndKeepsTheUpstreamStatus() async throws {
    let recorder = Recorder()
    let reply = try await service(
        Behavior(upstream: (201, [:], Data(#"{"closed":true}"#.utf8))), recorder
    ).closeTicket(
        authorization: "Bearer t",
        ticketId: ticketId,
        request: FeedbackTicketCloseRequest(reason: "no_longer_needed"),
        clientKindHeader: " Android "
    )
    #expect(reply.status == 201)
    #expect(reply.body == #"{"closed":true}"#)
    #expect(reply.headers == .exact([
        "Content-Type": AppFallback.jsonContentType,
        "Cache-Control": "no-store",
    ]))
    let relayed = try #require(recorder.relayed.first)
    #expect(relayed.method == "POST")
    #expect(relayed.path == "/api/apps/\(appId)/reporter-feedback/\(ticketId)/close")
    #expect(relayed.headers == ["Content-Type": "application/json"])
    #expect(relayed.body == #"{"reason":"no_longer_needed"}"#)
    #expect(recorder.events.contains("environment:android"))
}

@Test func feedbackMultiAppReplyRejectsNonImageAttachmentsBeforeTheSourceCheck() async throws {
    let multipart = "--b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nx\r\n--b--\r\n"
    let recorder = Recorder()
    let error = await errorOf {
        try await service(Behavior(), recorder).replyTicket(
            authorization: "Bearer t",
            ticketId: ticketId,
            request: FeedbackTicketReplyRequest(contentType: "multipart/form-data; boundary=b", body: multipart),
            clientKindHeader: "symbian"
        )
    }
    #expect(error == .attachmentTypeInvalid)
    #expect(recorder.events == ["session", "verified"])

    let image = "--b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\nContent-Type: image/PNG\r\n\r\nx\r\n--b--\r\n"
    let relay = Recorder()
    let reply = try await service(
        Behavior(upstream: (201, [:], Data(#"{"id":"c1"}"#.utf8))), relay
    ).replyTicket(
        authorization: "Bearer t",
        ticketId: ticketId,
        request: FeedbackTicketReplyRequest(contentType: "multipart/form-data; boundary=b", body: image)
    )
    #expect(reply.status == 201)
    let relayed = try #require(relay.relayed.first)
    #expect(relayed.path == "/api/apps/\(appId)/reporter-feedback/\(ticketId)/comments")
    #expect(relayed.headers == ["Content-Type": "multipart/form-data; boundary=b"])
    #expect(relayed.body == image)
}

@Test func feedbackMultiAppAttachmentKeepsTheUpstreamTypeAndPrivateCaching() async throws {
    let recorder = Recorder()
    let reply = try await service(
        Behavior(upstream: (200, ["content-type": "image/png", "Content-Disposition": "inline; filename=\"a.png\""], Data("PNGDATA".utf8))),
        recorder
    ).attachment(authorization: "Bearer t", ticketId: ticketId, attachmentId: attachmentId)
    #expect(reply.status == 200)
    #expect(reply.body == "PNGDATA")
    #expect(reply.headers == .exact([
        "Content-Type": "image/png",
        "X-Content-Type-Options": "nosniff",
        "Cache-Control": "private, no-store",
        "Content-Disposition": "inline; filename=\"a.png\"",
    ]))
    #expect(recorder.relayed.first?.path
        == "/api/apps/\(appId)/reporter-feedback/\(ticketId)/attachments/\(attachmentId)")

    let plain = try await service(Behavior(upstream: (200, [:], Data("x".utf8)))).attachment(
        authorization: "Bearer t", ticketId: ticketId, attachmentId: attachmentId
    )
    #expect(plain.headers == .exact([
        "Content-Type": "application/octet-stream",
        "X-Content-Type-Options": "nosniff",
        "Cache-Control": "private, no-store",
    ]))

    let badAttachment = await errorOf {
        try await service().attachment(authorization: "Bearer t", ticketId: ticketId, attachmentId: "nope")
    }
    #expect(badAttachment == .ticketNotFound)
}

// MARK: - Cursor re-serialization is byte-identical to the retired serializer

@Test func feedbackCursorRewriteMatchesTheRetiredSortedKeySerializer() throws {
    let bodies = [
        #"{"tickets":[],"next_cursor":"hands-page-2","unread_total":0}"#,
        #"{"b":1,"a":{"z":[1,2.5,-3,true,null,"x/y"],"A":"é☃😀"},"next_cursor":"c","B":"line\nbreak \"q\" \\ tab\t"}"#,
        #"{"next_cursor":"c","n":[0,-0,1e2,1.25,12345678901,0.1,1E-7],"_":1,"Z10":2,"z2":3,"é":4}"#,
        #"{"next_cursor":"c","comments":1,"comment_count":2,"a_b":3,"ab":4,"a-b":5,"aB":6,"Ab":7,"10":8,"9":9,"last_messages":1,"last_message_at":2,"ñ":3,"n":4}"#,
        #"{"next_cursor":"c","nested":{"next_cursor":"inner","list":[{"k":"v"},[],{}]},"s":"\u0001\u001f\u007f"}"#,
    ]
    for raw in bodies {
        let data = Data(raw.utf8)
        let rewritten = try #require(FeedbackCursorRewrite.rewrite(body: data, member: "next_cursor") { _ in "WRAPPED" })
        var object = try #require((try JSONSerialization.jsonObject(with: data)) as? [String: Any])
        object["next_cursor"] = "WRAPPED"
        let legacy = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        #expect(rewritten == legacy, "\(raw)")
    }
    // Not rewritten: not an object, absent/empty/non-string member, refused wrap.
    for raw in ["[]", "\"x\"", "not json", #"{"a":1}"#, #"{"next_cursor":""}"#, #"{"next_cursor":5}"#] {
        #expect(FeedbackCursorRewrite.rewrite(body: Data(raw.utf8), member: "next_cursor") { _ in "W" } == nil, "\(raw)")
    }
    #expect(FeedbackCursorRewrite.rewrite(body: Data(#"{"next_cursor":"c"}"#.utf8), member: "next_cursor") { _ in nil } == nil)
}
