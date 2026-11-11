import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The credential-surface direct-upload session routes at
/// `POST/GET/DELETE /internal/agent-api/attachment-upload-sessions[/:id]` and
/// `POST .../:id/complete`.
///
/// This deployment has no presigned object upload (the capabilities route
/// publishes `directUploadEnabled: false`), so every verb answers the pinned
/// service-unavailable 404 after the credential capability, the
/// `attachment:upload` grant and the request contract.
@Test func agentApiUploadSessionsPublishTheDisabledContract() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001028001"
    let ownerId = "11111111-1111-4111-8111-000001028001"
    accounts.addAccount(id: ownerId, email: "agent-upload-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-upload", name: "Agent Upload", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "upload-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "upload-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "UploadBot", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send"], name: "send")
    let readonlyKey = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "read")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func object(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            let uploadId = UUID().uuidString.lowercased()

            let validBody = """
            {"channelId":"\(channel)","filename":"log.txt","mimeType":"text/plain","sizeBytes":12,"clientRequestId":"\(UUID().uuidString.lowercased())"}
            """
            let create = try await client.send(
                .post, headers: headers, to: "/internal/agent-api/attachment-upload-sessions"
            ) { request in
                request.body = .init(string: validBody)
            }
            #expect(create.status == .notFound)
            #expect(object(create)["code"] as? String == "UPLOAD_SESSION_NOT_FOUND")
            #expect(object(create)["message"] as? String == "Direct uploads are disabled.")
            #expect(object(create)["retryable"] as? Bool == false)

            // The request contract still runs before the disabled answer.
            let invalid = try await client.send(
                .post, headers: headers, to: "/internal/agent-api/attachment-upload-sessions"
            ) { request in
                request.body = .init(string: "{\"channelId\":\"not-a-uuid\"}")
            }
            #expect(invalid.status == .badRequest)
            #expect(object(invalid)["code"] as? String == "agent_api_contract_invalid")
            let issues = object(invalid)["issues"] as? [[String: Any]] ?? []
            #expect(issues.contains { $0["path"] as? String == "channelId" })
            #expect(issues.contains { $0["path"] as? String == "filename" })

            for (method, path) in [
                (HTTPRequest.Method.get, "/internal/agent-api/attachment-upload-sessions/\(uploadId)"),
                (.delete, "/internal/agent-api/attachment-upload-sessions/\(uploadId)"),
                (.post, "/internal/agent-api/attachment-upload-sessions/\(uploadId)/complete"),
            ] {
                let response = try await client.send(method, headers: headers, to: URI(string: path))
                #expect(response.status == .notFound)
                #expect(object(response)["code"] as? String == "UPLOAD_SESSION_NOT_FOUND")
            }

            var readonlyHeaders = HTTPFields()
            readonlyHeaders[.authorization] = "Bearer \(readonlyKey)"
            readonlyHeaders[.contentType] = "application/json"
            let denied = try await client.send(
                .post, headers: readonlyHeaders, to: "/internal/agent-api/attachment-upload-sessions"
            ) { request in
                request.body = .init(string: validBody)
            }
            #expect(denied.status == .forbidden)
            #expect(object(denied)["code"] as? String == "capability_not_authorized")
            #expect(object(denied)["requiredCapability"] as? String == "send")

            accounts.setAgentGrantsForTesting(agentId: agent, scopes: ["message:read"])
            let missingGrant = try await client.send(
                .get, headers: headers, to: "/internal/agent-api/attachment-upload-sessions/\(uploadId)"
            )
            #expect(missingGrant.status == .forbidden)
            #expect(object(missingGrant)["requiredScope"] as? String == "attachment:upload")

            var anonymousHeaders = HTTPFields()
            anonymousHeaders[.contentType] = "application/json"
            let anonymous = try await client.send(
                .post, headers: anonymousHeaders, to: "/internal/agent-api/attachment-upload-sessions"
            ) { request in
                request.body = .init(string: validBody)
            }
            #expect(anonymous.status == .unauthorized)
        }
    }
}
