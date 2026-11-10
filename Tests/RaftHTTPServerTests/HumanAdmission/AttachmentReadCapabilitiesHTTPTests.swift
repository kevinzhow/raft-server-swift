import Foundation
import HTTPTypes
import TestSupport
import Testing
import Vapor
import VaporTesting
@testable import RaftHTTP
@testable import RaftHTTPServer

private let previewFlag = "attachment_preview_unified_v0"
private let previewPath = "/api/messages/attachment-preview/enabled"
private let readChannel = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private func activePath(_ channel: String = readChannel) -> String { "/api/attachments/upload-sessions/\(channel)/active" }

private struct AttachmentReadFixture {
    let services: FallbackServices
    let server: String
    let otherServer: String
    let owner: String
    let member: String
    let guest: String
    let outsider: String
    let unverified: String
    let pendingProfile: String
    let deletedChannel: String
    let foreignChannel: String
}

private func attachmentReadFixture() -> AttachmentReadFixture {
    let services = FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {})
    let accounts = services.emailAccounts
    let server = "33333333-3333-4333-8333-333333333677"
    let otherServer = "33333333-3333-4333-8333-333333333678"
    let ids = (0..<6).map { _ in UUID().uuidString.lowercased() }
    for (index, id) in ids.enumerated() {
        accounts.addAccount(id: id, email: "read-capability-\(index)@example.com", password: "SyntheticPassword123!")
        if index != 4 { accounts.markEmailVerified(userId: id) }
    }
    accounts.setAccountProfileForTesting(id: ids[5], name: "pending_read_capability")
    accounts.oauth.addOwnedServer(id: server, slug: "read-capability", name: "Read capability", ownerId: ids[0])
    accounts.oauth.addOwnedServer(id: otherServer, slug: "read-capability-other", name: "Read other", ownerId: ids[0])
    accounts.oauth.addMember(serverId: server, userId: ids[1], role: "member")
    accounts.oauth.addMember(serverId: server, userId: ids[2], role: "guest")
    accounts.oauth.addMember(serverId: server, userId: ids[4], role: "member")
    accounts.oauth.addMember(serverId: server, userId: ids[5], role: "member")
    accounts.addPostableChannel(serverId: server, channelId: readChannel, memberId: ids[0], name: "read-channel")
    let deleted = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    accounts.addPostableChannel(serverId: server, channelId: deleted, memberId: ids[0], name: "deleted-read-channel")
    accounts.softDeletePostableChannelForTesting(channelId: deleted)
    let foreign = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    accounts.addPostableChannel(serverId: otherServer, channelId: foreign, memberId: ids[0], name: "foreign-read-channel")
    func token(_ index: Int) -> String { accounts.mintAccessTokenForTesting(userId: ids[index]) }
    return .init(services: services, server: server, otherServer: otherServer, owner: token(0), member: token(1),
        guest: token(2), outsider: token(3), unverified: token(4), pendingProfile: token(5),
        deletedChannel: deleted, foreignChannel: foreign)
}

private func attachmentReadGET(_ client: any Client, _ path: String, token: String? = nil,
    server: String? = nil, method: HTTPRequest.Method = .get) async throws -> ClientResponse {
    var headers = HTTPFields()
    if let token { headers[.authorization] = "Bearer \(token)" }
    if let server { headers[HTTPField.Name("X-Server-Id")!] = server }
    return try await client.send(method, headers: headers, to: URI(string: path))
}

private func expectAttachmentRead(_ response: ClientResponse, status: Int, body: String) {
    #expect(Int(response.status.code) == status)
    #expect(response.body.string == body)
    #expect(response.headers[.contentType] == "application/json; charset=utf-8")
    #expect(response.headers[.contentLength] == String(body.utf8.count))
    #expect(response.headers[.cacheControl] == "private, no-store")
    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
}

/// Published HTTP response evidence over actual checked owner fixtures. This
/// evaluates configuration, not preview format implementation or model support.
@Test func attachmentPreviewReadUsesScopedFlagAndMissingFlagDefaultsTrue() async throws {
    let f = attachmentReadFixture()
    let accounts = f.services.emailAccounts
    try await withApp { app in
        configure(app, services: f.services)
        try await app.testing { client in
            let missing = try await attachmentReadGET(client, previewPath, token: f.owner, server: f.server)
            expectAttachmentRead(missing, status: 200, body: #"{"enabled":true}"#)
            accounts.createFeatureFlagForTesting(key: previewFlag, defaultEnabled: true)
            accounts.addFeatureFlagRuleForTesting(key: previewFlag, stage: "server", decision: "deny", values: [f.server])
            let disabled = try await attachmentReadGET(client, previewPath, token: f.owner, server: f.server)
            expectAttachmentRead(disabled, status: 200, body: #"{"enabled":false}"#)
            let other = try await attachmentReadGET(client, previewPath, token: f.owner, server: f.otherServer)
            expectAttachmentRead(other, status: 200, body: #"{"enabled":true}"#)
            let headerWins = try await attachmentReadGET(client, previewPath + "?serverId=\(f.otherServer)", token: f.owner, server: f.server)
            expectAttachmentRead(headerWins, status: 200, body: #"{"enabled":false}"#)
            for token in [f.member, f.guest] {
                let member = try await attachmentReadGET(client, previewPath, token: token, server: f.server)
                expectAttachmentRead(member, status: 200, body: #"{"enabled":false}"#)
            }
            let noHeader = try await attachmentReadGET(client, previewPath + "?serverId=\(f.server)", token: f.owner)
            expectAttachmentRead(noHeader, status: 400, body: #"{"error":"Missing X-Server-Id header"}"#)
            let outsider = try await attachmentReadGET(client, previewPath, token: f.outsider, server: f.server)
            expectAttachmentRead(outsider, status: 403, body: #"{"error":"Not a member of this server"}"#)
            accounts.setFeatureFlagKillSwitchForTesting(key: previewFlag, killSwitch: true)
            let killed = try await attachmentReadGET(client, previewPath, token: f.owner, server: f.otherServer)
            expectAttachmentRead(killed, status: 200, body: #"{"enabled":false}"#)
        }
    }
}

/// Active direct-upload service is absent. Empty recovery reads do not admit a
/// writer, reveal resource contents, or establish resumable upload support.
@Test func activeUploadReadUsesExactAbsentServiceContractAfterNarrowAdmission() async throws {
    let f = attachmentReadFixture()
    try await withApp { app in
        configure(app, services: f.services)
        try await app.testing { client in
            for token in [f.owner, f.member, f.guest] {
                for channel in [readChannel, f.deletedChannel, f.foreignChannel,
                    "dddddddd-dddd-4ddd-8ddd-dddddddddddd", "00000000-0000-0000-0000-000000000000"] {
                    let response = try await attachmentReadGET(client, activePath(channel), token: token, server: f.server)
                    expectAttachmentRead(response, status: 200, body: #"{"uploads":[]}"#)
                }
            }
            let conflict = try await attachmentReadGET(client, activePath() + "?serverId=\(f.otherServer)", token: f.owner, server: f.server)
            expectAttachmentRead(conflict, status: 200, body: #"{"uploads":[]}"#)
            for invalid in ["not-a-uuid", "11111111-1111-4111-7111-111111111111"] {
                let response = try await attachmentReadGET(client, activePath(invalid), token: f.owner, server: f.server)
                expectAttachmentRead(response, status: 400, body: #"{"code":"UPLOAD_INVALID_REQUEST","message":"The channel id is invalid.","retryable":false}"#)
            }
            let noScope = try await attachmentReadGET(client, activePath("not-a-uuid") + "?serverId=\(f.server)", token: f.owner)
            expectAttachmentRead(noScope, status: 400, body: #"{"error":"Missing X-Server-Id header"}"#)
            let nonmember = try await attachmentReadGET(client, activePath("not-a-uuid"), token: f.outsider, server: f.server)
            expectAttachmentRead(nonmember, status: 403, body: #"{"error":"Not a member of this server"}"#)
            let head = try await attachmentReadGET(client, activePath(), token: f.owner, server: f.server, method: .head)
            // The in-memory client returns the GET responder body unchanged.
            // The real HTTP server strips HEAD bodies; test that transport below.
            #expect(head.status == .ok)
            #expect(head.body.string == #"{"uploads":[]}"#)
            #expect(head.body.count == 14)
            #expect(head.headers[.contentLength] == String(#"{"uploads":[]}"#.utf8.count))
            #expect(head.headers[.cacheControl] == "private, no-store")
        }
    }
}

@Test func readCapabilitiesKeepHumanAuthBeforeFlexScopeAndChannelValidation() async throws {
    let f = attachmentReadFixture()
    try await withApp { app in
        configure(app, services: f.services)
        try await app.testing { client in
            for path in [previewPath, activePath("not-a-uuid")] {
                let missing = try await attachmentReadGET(client, path)
                expectAttachmentRead(missing, status: 401, body: #"{"error":"Missing or invalid Authorization header","code":"auth_required"}"#)
                #expect(missing.body.count == 74)
                let invalid = try await attachmentReadGET(client, path, token: "invalid-token")
                expectAttachmentRead(invalid, status: 401, body: #"{"error":"Invalid or expired token","code":"auth_required"}"#)
                let queryOnly = try await attachmentReadGET(client, path + "?token=\(f.owner)&serverId=\(f.server)")
                expectAttachmentRead(queryOnly, status: 401, body: #"{"error":"Missing or invalid Authorization header","code":"auth_required"}"#)
                let unverified = try await attachmentReadGET(client, path, token: f.unverified)
                expectAttachmentRead(unverified, status: 403, body: #"{"error":"Email verification required"}"#)
                let pending = try await attachmentReadGET(client, path, token: f.pendingProfile)
                expectAttachmentRead(pending, status: 403, body: #"{"error":"Profile setup required","code":"PROFILE_SETUP_REQUIRED"}"#)
            }
            let serving = try await attachmentReadGET(client, "/api/attachments/\(readChannel)/url")
            expectAttachmentRead(serving, status: 401, body: #"{"error":"Authentication required"}"#)
            #expect(serving.body.count == 35)
        }
    }
}


/// Exercise these APIs through actual HTTP; in-memory responder bodies do not
/// model HEAD framing. GET and HEAD must retain the same representation headers.
@Test(.timeLimit(.minutes(1))) func attachmentReadCapabilityHEADIsBodylessOnRealHTTP() async throws {
    let f = attachmentReadFixture()
    try await withApp { app in
        configure(app, services: f.services)
        try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
            for (path, body) in [(previewPath, #"{"enabled":true}"#), (activePath(), #"{"uploads":[]}"#)] {
                let get = try await attachmentReadGET(client, path, token: f.owner, server: f.server)
                let getBytes = try await attachmentPreviewBody(get)
                #expect(get.status == .ok)
                #expect(getBytes == Data(body.utf8))
                #expect(get.headers[.contentLength] == String(body.utf8.count))
                #expect(get.headers[.contentType] == "application/json; charset=utf-8")
                #expect(get.headers[.cacheControl] == "private, no-store")
                #expect(get.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
                let head = try await attachmentReadGET(client, path, token: f.owner, server: f.server, method: .head)
                let headBytes = try await attachmentPreviewBody(head)
                #expect(head.status == .ok)
                #expect(headBytes.isEmpty)
                #expect(head.headers[.contentLength] == String(body.utf8.count))
                #expect(head.headers[.contentLength] == get.headers[.contentLength])
                #expect(head.headers[.contentType] == get.headers[.contentType])
                #expect(head.headers[.cacheControl] == get.headers[.cacheControl])
                #expect(head.headers[HTTPField.Name("X-Robots-Tag")!] == get.headers[HTTPField.Name("X-Robots-Tag")!])
            }
        }
    }
}
