import Foundation
import Testing
import TestSupport
@testable import RaftHTTP
import RaftShared

/// The agent lifecycle service's own contracts: the exact legacy error and
/// success bytes, the client-event batch policy and the atomic store sections it
/// depends on. The HTTP route tests lock the wire projection.

private func makeService(
    directory: EmailLoginDirectory,
    environment: @escaping @Sendable () -> [String: String] = { [:] },
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
) -> AgentsLifecycleService {
    AgentsLifecycleService(
        profiles: directory.authProfileStore,
        agents: directory.agentsRuntimeStore,
        machines: directory.machinesAndComputersStore,
        channels: directory.serversAndChannelsStore,
        messages: directory.messagesAndThreadsStore,
        inboxFacts: directory.inboxFactStore,
        productEvents: directory.productEventStore,
        oauth: directory.oauth,
        dependencies: AgentsLifecycleDependencies(
            recordAgentCredentialUse: { _ in },
            jointLocalChannelId: { _, _, _ in nil },
            environment: environment,
            now: now
        )
    )
}

@Test func agentsLifecycleErrorsPublishTheLegacyBytes() {
    let table: [(AgentsLifecycleError, UInt, String)] = [
        (.unauthorized, 401, #"{"error":"Unauthorized"}"#),
        (.invalidOrExpiredToken, 401, #"{"error":"Invalid or expired token","code":"auth_required"}"#),
        (.uploadsDisabled, 503, #"{"error":"File uploads are disabled on this server","errorCode":"ATTACHMENT_UPLOAD_DISABLED"}"#),
        (.capabilityNotAuthorized, 403, #"{"error":"Agent credential is not authorized for this capability","code":"capability_not_authorized"}"#),
        (.channelNotFound, 404, #"{"error":"Channel not found"}"#),
        (.emptyFile, 400, #"{"error":"Empty files are not allowed"}"#),
        (.fileTooLarge(maxBytes: 52_428_800), 413, #"{"error":"Max 50MB per file","errorCode":"ATTACHMENT_TOO_LARGE","maxBytes":52428800}"#),
        (.agentMissing, 404, #"{"code":"agent_missing","error":"Agent not found"}"#),
        (.forbidden, 403, #"{"error":"Forbidden"}"#),
        (.notAMember, 403, #"{"error":"Not a member of this server"}"#),
        (.tooManyFiles, 400, #"{"error":"Max 10 files per message"}"#),
        (.uploadForbidden, 403, #"{"code":"UPLOAD_FORBIDDEN","message":"The member cannot upload to this channel.","retryable":false}"#),
        (.uploadSessionNotFound, 404, #"{"code":"UPLOAD_SESSION_NOT_FOUND","message":"Upload session not found.","retryable":false}"#),
        (.invalidCursor, 400, #"{"error":"Invalid cursor"}"#),
        (.invalidAttachmentId, 400, #"{"code":"invalid_attachment_id","error":"Invalid attachment id"}"#),
        (.serverIdRequired, 400, #"{"error":"X-Server-Id header is required"}"#),
        (.attachmentNotFound, 404, #"{"error":"Attachment not found"}"#),
        (.invalidEventBatch, 400, #"{"error":"Invalid event batch"}"#),
        (.invalidAppVersion, 400, #"{"error":"Invalid app_version"}"#),
        (.computerUnauthorized, 401, #"{"error":"Unauthorized","code":"auth_required"}"#),
        (.invalidPrincipal, 401, #"{"error":"Invalid principal for this surface","code":"invalid_principal"}"#),
        (.surfaceUnregistered, 401, #"{"error":"This internal surface is not registered","code":"auth_policy_unregistered_path"}"#),
        (.unknownRuntimeProvider, 404, #"{"error":"Unknown runtime provider"}"#),
    ]
    for (error, status, body) in table {
        #expect(error.status == status)
        #expect(error.publishedErrorBody.render() == body)
    }
}

@Test func agentsLifecycleSuccessBodiesKeepTheLegacyMemberOrder() {
    // Full identity fields and role matrix are asserted through the published
    // route in AttachmentWireContractTests (upstream internalAgentApi.ts:2386).
    let identity = AgentApiCredentialResponse(agentId: "a", credentialId: "c", serverId: "s", scopes: ["read", "send"],
        agentName: "reader", agentDisplayName: nil, serverRole: nil).jsonBody.render()
    #expect(identity.hasPrefix(#"{"agentId":"a","agentName":"reader","agentDisplayName":null,"serverId":"s","serverRole":null,"serverCapabilities":{"viewChannel":false,"#))
    #expect(identity.hasSuffix(#"},"credentialId":"c","scopes":["read","send"]}"#))
    #expect(
        AgentAttachmentUploadResponse(id: "i", filename: "f.txt", mimeType: nil, sizeBytes: 3).jsonBody.render()
            == #"{"id":"i","filename":"f.txt","mimeType":null,"sizeBytes":3,"thumbnailUrl":null}"#
    )
    #expect(
        AttachmentUploadListResponse(attachments: [.init(id: "1", filename: "a"), .init(id: "2", filename: "b")])
            .jsonBody.render()
            == #"{"attachments":[{"id":"1","filename":"a","mimeType":"application/octet-stream","sizeBytes":null,"width":null,"height":null,"thumbnailUrl":null,"rasterPreviewUrl":null},{"id":"2","filename":"b","mimeType":"application/octet-stream","sizeBytes":null,"width":null,"height":null,"thumbnailUrl":null,"rasterPreviewUrl":null}]}"#
    )
    #expect(
        AttachmentUploadCapabilitiesResponse(maxBytes: 52_428_800).jsonBody.render()
            == #"{"directUploadEnabled":false,"directUploadThresholdBytes":null,"maxBytes":52428800,"sessionExpiresInSeconds":null}"#
    )
    #expect(
        AttachmentReadResponse.metadata(AttachmentMetadataResponse(id: "i", filename: "f", mimeType: "text/plain"))
            .jsonBody.render()
            == #"{"id":"i","filename":"f","mimeType":"text/plain"}"#
    )
    #expect(
        AttachmentReadResponse.htmlPreviewURL(AttachmentHTMLPreviewURLResponse(url: "/u", expiresAt: "t"))
            .jsonBody.render()
            == #"{"url":"/u","expiresAt":"t"}"#
    )
    #expect(RuntimeProviderProbeResponse(available: true).jsonBody.render() == #"{"kind":"antiproton","available":true}"#)
    #expect(AttachmentStreamBody(body: "raw \"text\"").jsonBody.render() == "raw \"text\"")
}

@Test func channelFilesBodyKeepsTheLegacyOrderAndNulls() {
    let file = ChannelFilesResponse.File(
        id: "f1", messageId: "m1", channelId: "c1", filename: "a.png", mimeType: "image/png",
        sizeBytes: nil, width: 4, height: nil, thumbnailUrl: "/api/attachments/f1/thumbnail",
        createdAt: "2024-01-01T00:00:00.000Z",
        uploader: .init(type: "user", id: "u1", name: "ann", displayName: "ann"),
        source: .init(type: "thread", channelId: "c1", parentMessageId: "parent-message", parentMessageShortId: "parent-m")
    )
    #expect(
        ChannelFilesResponse(files: [file], nextCursor: nil).jsonBody.render()
            == #"{"files":[{"id":"f1","messageId":"m1","channelId":"c1","filename":"a.png","mimeType":"image/png","sizeBytes":null,"width":4,"height":null,"thumbnailUrl":"/api/attachments/f1/thumbnail","createdAt":"2024-01-01T00:00:00.000Z","uploader":{"type":"user","id":"u1","name":"ann","displayName":"ann"},"source":{"type":"thread","channelId":"c1","parentMessageId":"parent-message","parentMessageShortId":"parent-m"}}],"nextCursor":null}"#
    )
    #expect(ChannelFilesResponse(files: [], nextCursor: "abc").jsonBody.render() == #"{"files":[],"nextCursor":"abc"}"#)
}

@Test func computerPreflightBodyKeepsTheSurfaceFragmentAndEmptyArrays() {
    let surface = InternalSurfaceSnapshot(
        surfaceVersion: "v1",
        claimedPrefixes: ["/internal/computer/"],
        registeredPrincipals: ["computer"],
        computerSurface: [InternalSurfaceEntry(method: "POST", path: "/internal/computer/preflight", principal: "computer")]
    )
    let body = ComputerPreflightResponse(surface: surface, serverId: "s", serverSlug: "slug", computerId: "c", computerName: "n")
    #expect(
        body.jsonBody.render()
            == #"{"ok":true,"surfaceVersion":"v1","claimedPrefixes":["/internal/computer/"],"registeredPrincipals":["computer"],"computerSurface":[{"method":"POST","path":"/internal/computer/preflight","principal":"computer"}],"serverId":"s","serverSlug":"slug","principal":{"kind":"computer","id":"c","name":"n"}}"#
    )
    let empty = InternalSurfaceSnapshot(surfaceVersion: "v", claimedPrefixes: [], registeredPrincipals: [], computerSurface: [])
    #expect(
        ComputerPreflightResponse(surface: empty, serverId: "s", serverSlug: "g", computerId: "c", computerName: "n")
            .jsonBody.render().contains(#""claimedPrefixes":[],"registeredPrincipals":[],"computerSurface":[],"#)
    )
}

@Test func storedEventPropertiesMatchTheLegacySerializerBytes() throws {
    let samples: [[String: AgentsLifecycleService.ClientEventPropertyValue]] = [
        [:],
        ["from": .text("a/b"), "$browser": .text("chrome"), "$browser_version": .integer(142)],
        ["action": .text("tab\tline\nquote\" back\\ slash/ é 😀 \u{2028} \u{1}"), "$os": .text("linux"), "$country": .text("JP")],
    ]
    for sample in samples {
        var legacy: [String: Any] = [:]
        for (key, value) in sample {
            switch value {
            case .text(let text): legacy[key] = text
            case .integer(let number): legacy[key] = number
            }
        }
        let expected = String(
            decoding: try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys]),
            as: UTF8.self
        )
        #expect(AgentsLifecycleService.renderProperties(sample) == expected)
    }
}

@Test func clientEventDeviceContextKeepsOnlyCoarseFacts() {
    let context = AgentsLifecycleService.ClientEventDeviceContext(
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/142.0.1 Safari/537.36",
        country: " jp "
    ).properties
    #expect(context["$browser"] == .text("chrome"))
    #expect(context["$browser_version"] == .integer(142))
    #expect(context["$os"] == .text("windows"))
    #expect(context["$device_type"] == .text("desktop"))
    #expect(context["$country"] == .text("JP"))
    let unknown = AgentsLifecycleService.ClientEventDeviceContext(userAgent: "curl/8", country: "usa").properties
    #expect(unknown["$browser"] == .text("unknown"))
    #expect(unknown["$country"] == nil)
}

private func batchBody(_ events: [JSONValue], source: String = "web", appVersion: String? = nil) -> ClientEventsBatchRequest {
    var members: [String: JSONValue] = ["source": .string(source), "events": .array(events)]
    if let appVersion { members["app_version"] = .string(appVersion) }
    return ClientEventsBatchRequest(members: members)
}

private func event(uuid: String, name: String = "activity_open", timestamp: String, properties: [String: JSONValue]) -> JSONValue {
    .object([
        "uuid": .string(uuid),
        "event": .string(name),
        "timestamp": .string(timestamp),
        "client_session_id": .string("22222222-2222-4222-8222-222222222222"),
        "properties": .object(properties),
    ])
}

@Test func clientEventsBatchStoresOnceAndHonoursTheOptIn() throws {
    let directory = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111701"
    directory.addAccount(id: userId, email: "events@lifecycle.test", password: "password123")
    let token = directory.mintAccessTokenForTesting(userId: userId)
    let service = makeService(directory: directory)
    let authorization = "Bearer \(token)"
    let batch = batchBody([
        event(uuid: "33333333-3333-4333-8333-333333333701", timestamp: "2023-11-14T22:13:20.000Z", properties: ["from": .string("inbox")]),
        event(uuid: "33333333-3333-4333-8333-333333333702", name: "other", timestamp: "2023-11-14T22:13:20.000Z", properties: [:]),
        event(uuid: "33333333-3333-4333-8333-333333333703", timestamp: "2000-01-01T00:00:00.000Z", properties: [:]),
    ], appVersion: "1.2.3")

    // Not opted in: accepted 0 even for a malformed body.
    #expect(try service.clientEventsBatch(authorization: authorization, serverId: "s", userAgent: "", country: "", body: nil).accepted == 0)

    directory.setShareUsageData(userId: userId, value: true)
    #expect(throws: AgentsLifecycleError.invalidEventBatch) {
        try service.clientEventsBatch(authorization: authorization, serverId: "s", userAgent: "", country: "", body: nil)
    }
    #expect(throws: AgentsLifecycleError.invalidAppVersion) {
        try service.clientEventsBatch(authorization: authorization, serverId: "s", userAgent: "", country: "", body: batchBody([event(uuid: "33333333-3333-4333-8333-333333333704", timestamp: "2023-11-14T22:13:20.000Z", properties: [:])], appVersion: "1.2"))
    }
    let first = try service.clientEventsBatch(
        authorization: authorization, serverId: "s", userAgent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/99.0 Safari/1", country: "us", body: batch
    )
    #expect(first.accepted == 1)
    let rows = directory.recordedClientEvents(serverId: "s")
    #expect(rows.count == 1)
    #expect(rows[0].propertiesJSON == #"{"$browser":"chrome","$browser_version":99,"$country":"US","$device_type":"desktop","$os":"linux","from":"inbox"}"#)
    #expect(rows[0].appVersion == "1.2.3")
    // The same batch id is never stored twice.
    let replay = try service.clientEventsBatch(authorization: authorization, serverId: "s", userAgent: "", country: "", body: batch)
    #expect(replay.accepted == 0)
    #expect(directory.recordedClientEvents(serverId: "s").count == 1)
    #expect(try service.clientEventsConfig(authorization: authorization).clientEventsAllowed)
    #expect(throws: AgentsLifecycleError.unauthorized) {
        try service.clientEventsConfig(authorization: nil)
    }
}

@Test func attachmentUploadGateAndSessionRefusalsKeepTheirOrder() throws {
    let directory = EmailLoginDirectory()
    let off = makeService(directory: directory, environment: { ["ATTACHMENT_UPLOAD_ENABLED": " Off "] })
    #expect(throws: AgentsLifecycleError.uploadsDisabled) {
        try off.uploadAttachments(authorization: nil, serverId: "s", channelId: "c", files: [])
    }
    #expect(throws: AgentsLifecycleError.uploadsDisabled) {
        try off.uploadAgentAttachmentIdless(authorization: nil, channelId: "c", filename: "f", mimeType: nil, sizeBytes: 1, bytes: Data())
    }
    let on = makeService(directory: directory)
    #expect(throws: AgentsLifecycleError.unauthorized) {
        try on.uploadAttachments(authorization: nil, serverId: "s", channelId: "c", files: [])
    }
    #expect(throws: AgentsLifecycleError.capabilityNotAuthorized) {
        try on.uploadAgentAttachmentIdless(authorization: nil, channelId: "c", filename: "f", mimeType: nil, sizeBytes: 1, bytes: Data())
    }
    #expect(throws: AgentsLifecycleError.unauthorized) {
        try on.attachmentUploadSessionMissing(authorization: nil, uploadId: "u")
    }
    let userId = "11111111-1111-4111-8111-111111111702"
    directory.addAccount(id: userId, email: "session@lifecycle.test", password: "password123")
    let authorization = "Bearer \(directory.mintAccessTokenForTesting(userId: userId))"
    #expect(throws: AgentsLifecycleError.uploadSessionNotFound) {
        try on.attachmentUploadSessionMissing(authorization: authorization, uploadId: "u")
    }
    #expect(throws: AgentsLifecycleError.notAMember) {
        try on.attachmentUploadSessionCreate(authorization: authorization, serverId: "unknown")
    }
}

@Test func computerAttachGateReadsTheOverrideBeforeTheEnvironment() {
    let directory = EmailLoginDirectory()
    #expect(makeService(directory: directory, environment: { ["SLOCK_DEVICE_LOGIN_ENABLED": " FALSE "] }).computerAttachEnabled() == false)
    #expect(makeService(directory: directory).computerAttachEnabled() == true)
    directory.setComputerAttachEnabledForTesting(true)
    #expect(makeService(directory: directory, environment: { ["SLOCK_DEVICE_LOGIN_ENABLED": "false"] }).computerAttachEnabled() == true)
}

@Test func cspMetaTagRangeFindsTheDocumentsOwnPolicy() {
    let html = "<html><head><META http-equiv=\"Content-Security-Policy\" content=\"x\"><title>t</title>"
    let range = AgentsLifecycleService.cspMetaTagRange(in: html)
    #expect(range.map { String(html[$0]) } == "<META http-equiv=\"Content-Security-Policy\" content=\"x\">")
    #expect(AgentsLifecycleService.cspMetaTagRange(in: "<meta charset=utf-8>") == nil)
}

// MARK: - Atomic sections

@Test func analyticsIdMintsOnceUnderConcurrentFirstEvents() {
    let directory = EmailLoginDirectory()
    let store = directory.authProfileStore
    let ids = LockedBox<[String]>([])
    DispatchQueue.concurrentPerform(iterations: 64) { _ in
        let id = store.analyticsId(userId: "u")
        ids.mutate { $0.append(id) }
    }
    #expect(Set(ids.value).count == 1)
    #expect(ids.value.count == 64)
}

@Test func clientEventAdmissionStoresAConcurrentlyDeliveredBatchOnce() {
    let store = ProductEventStore()
    func candidate(_ id: String) -> ProductEventStore.ClientEventCandidate {
        ProductEventStore.ClientEventCandidate(
            eventId: id,
            record: ClientEventRecord(event: "activity_open", analyticsId: "a", serverId: "s", source: "web", sessionId: "x", appVersion: nil, propertiesJSON: "{}")
        )
    }
    let candidates = (0..<5).map { candidate("event-\($0)") } + [candidate("event-0")]
    let admittedTotal = LockedBox(0)
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
        let admitted = store.admitClientEvents(candidates, seenIDs: candidates.map(\.eventId))
        admittedTotal.mutate { $0 += admitted }
    }
    #expect(admittedTotal.value == 5)
    #expect(store.clientEvents(serverId: "s").count == 5)
}

@Test func refreshRotationLetsExactlyOneConcurrentRefreshWin() {
    let directory = EmailLoginDirectory()
    let store = directory.authProfileStore
    let issued = store.openSession(userId: "u")
    let rotated = LockedBox(0)
    let rejected = LockedBox(0)
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
        if store.rotateRefreshToken(issued.refreshToken, attemptId: nil, installationId: nil, now: Date()) != nil {
            rotated.mutate { $0 += 1 }
        } else {
            rejected.mutate { $0 += 1 }
        }
    }
    #expect(rotated.value == 1)
    #expect(rejected.value == 31)
}

@Test func durableRefreshReplaysTheSameSuccessorForTheSameAttemptOnly() {
    let store = EmailLoginDirectory().authProfileStore
    let issued = store.openSession(userId: "u")
    guard let first = store.rotateRefreshToken(issued.refreshToken, attemptId: "a", installationId: "i", now: Date()) else {
        Issue.record("first durable refresh must rotate")
        return
    }
    guard let replay = store.rotateRefreshToken(issued.refreshToken, attemptId: "a", installationId: "i", now: Date()) else {
        Issue.record("the same attempt must replay")
        return
    }
    #expect(replay.refreshToken == first.refreshToken)
    #expect(store.rotateRefreshToken(issued.refreshToken, attemptId: "b", installationId: "i", now: Date()) == nil)
}

@Test func openSessionIssuesDistinctPairsUnderConcurrency() {
    let store = EmailLoginDirectory().authProfileStore
    let tokens = LockedBox<[String]>([])
    DispatchQueue.concurrentPerform(iterations: 64) { _ in
        let issued = store.openSession(userId: "u")
        tokens.mutate { $0.append(issued.accessToken); $0.append(issued.refreshToken) }
    }
    #expect(Set(tokens.value).count == 128)
    #expect(store.sessionFamilies.count == 64)
}

@Test func agentAttachmentBytesSurviveConcurrentUploads() {
    let store = EmailLoginDirectory().agentsRuntimeStore
    DispatchQueue.concurrentPerform(iterations: 64) { index in
        store.storeAgentAttachmentBytes(id: "att-\(index)", bytes: Data([UInt8(index)]))
    }
    #expect(store.agentAttachmentBytes.count == 64)
    #expect(store.agentAttachmentBytes["att-7"] == Data([7]))
}

@Test func attachmentRowsInsertConcurrentlyWithoutLoss() {
    let store = EmailLoginDirectory().messagesAndThreadsStore
    DispatchQueue.concurrentPerform(iterations: 64) { index in
        store.insertAttachment(ChannelAttachment(
            id: "a-\(index)", channelId: "c", uploaderId: "u", filename: "f", messageId: nil, messagePosition: nil
        ))
    }
    #expect(store.channelAttachments.count == 64)
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
