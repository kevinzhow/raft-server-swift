import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

private func attachmentACLHeaders(_ authorization: String, server: String? = nil) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = authorization
    headers[.contentType] = "application/json"
    if let server { headers[HTTPField.Name("X-Server-Id")!] = server }
    return headers
}

private func attachmentACLJSON(_ response: ClientResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: response.body.data ?? Data()) as? [String: Any])
}

private func attachmentACLRequest(
    _ client: any Client, _ method: HTTPRequest.Method, _ path: String,
    headers: HTTPFields, body: [String: String]? = nil
) async throws -> ClientResponse {
    let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
    return try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let data { request.body = .init(data: data) }
    }
}

private func attachmentACLUpload(
    _ client: any Client, headers: HTTPFields, channel: String, bytes: Data
) async throws -> String {
    let boundary = "attachment-acl-contract"
    var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"channelId\"\r\n\r\n\(channel)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"private.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
    body.append(bytes)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    var fields = headers
    fields[.contentType] = "multipart/form-data; boundary=\(boundary)"
    let payload = body
    let uploaded = try await client.send(.post, headers: fields, to: "/api/attachments/upload") {
        $0.body = .init(data: payload)
    }
    #expect(uploaded.status == .ok)
    let rows = try #require(attachmentACLJSON(uploaded)["attachments"] as? [[String: Any]])
    return try #require(rows.first?["id"] as? String)
}

/// Upstream channels.ts:941-1029 commits requested visibility and selected initial
/// members together. A private intent must never silently become a public room.
@Test func attachmentPrivateChannelCreationRetainsVisibilityAndInitialMembership() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        let setup = AttachmentPreviewAccounts(storage: fixture.storage)
        let selected = setup.accounts.oauth.createAgent(serverId: setup.serverId, name: "selected-reader")
        let outsider = setup.accounts.oauth.createAgent(serverId: setup.serverId, name: "unselected-reader")
        let selectedUser = UUID().uuidString.lowercased()
        setup.accounts.addAccount(id: selectedUser, email: "selected-human@slock.test", password: "password123")
        setup.accounts.markEmailVerified(userId: selectedUser)
        setup.accounts.oauth.addMember(serverId: setup.serverId, userId: selectedUser, role: "member")
        let selectedKey = setup.accounts.mintAgentCredential(agentId: selected, scopes: ["read"], name: "selected")
        let outsiderKey = setup.accounts.mintAgentCredential(agentId: outsider, scopes: ["read"], name: "unselected")
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {}, emailAccounts: setup.accounts))
            try await app.testing { client in
                let headers = attachmentACLHeaders(setup.authorization, server: setup.serverId)
                let payload = try JSONSerialization.data(withJSONObject: [
                    "name": "created-private", "visibility": "private",
                    "agentIds": [selected, 17, selected] as [Any],
                    "userIds": [selectedUser, NSNull()] as [Any],
                ])
                let created = try await client.send(.post, headers: headers, to: "/api/channels") { $0.body = .init(data: payload) }
                #expect(created.status == .ok)
                let body = try attachmentACLJSON(created)
                let channel = try #require(body["id"] as? String)
                #expect(body["type"] as? String == "private")
                let detail = try await attachmentACLRequest(client, .get, "/api/channels/\(channel)", headers: headers)
                #expect(detail.status == .ok)
                #expect(try attachmentACLJSON(detail)["type"] as? String == "private")
                let selectedHuman = attachmentACLHeaders("Bearer \(setup.accounts.mintAccessTokenForTesting(userId: selectedUser))", server: setup.serverId)
                #expect(try await attachmentACLRequest(client, .get, "/api/channels/\(channel)", headers: selectedHuman).status == .ok)
                for (key, expected) in [(selectedKey, HTTPResponse.Status.ok), (outsiderKey, .notFound)] {
                    let history = try await attachmentACLRequest(client, .get,
                        "/internal/agent-api/history?channel=%23created-private&consume=false",
                        headers: attachmentACLHeaders("Bearer \(key)"))
                    #expect(history.status == expected)
                }
            }
        }
        await fixture.stop()
    } catch {
        await fixture.stop()
        throw error
    }
}

/// Isolate removal from the separate creation defect: the precondition is a
/// genuinely private room with both retained membership representations. Exercise
/// published mutations and parent-derived reads; an owner witness retains bytes.
@Test(arguments: ["human", "agent", "leave"])
func attachmentPrivateMembershipRemovalRevokesParentAndThreadDerivedReads(remover: String) async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        let setup = AttachmentPreviewAccounts(storage: fixture.storage)
        _ = setup.accounts.oauth.setChannelType(id: setup.channelId, type: "private")
        let agent = setup.accounts.oauth.createAgent(serverId: setup.serverId, name: "revoked-reader")
        setup.accounts.oauth.addChannelAgent(channelId: setup.channelId, agentId: agent)
        setup.accounts.addPostableChannel(serverId: setup.serverId, channelId: setup.channelId,
            memberId: agent, kind: "private", name: "preview")
        let key = setup.accounts.mintAgentCredential(agentId: agent, scopes: ["read", "channels"], name: "revocation-reader")
        let admin = setup.accounts.oauth.createAgent(serverId: setup.serverId, name: "membership-admin")
        setup.accounts.oauth.setAgentRole(serverId: setup.serverId, agentId: admin, role: "admin")
        let adminKey = setup.accounts.mintAgentCredential(agentId: admin, scopes: ["channels"], name: "membership-admin")
        let bytes = Data((0..<256).map(UInt8.init))
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {}, emailAccounts: setup.accounts))
            try await app.testing { client in
                let human = attachmentACLHeaders(setup.authorization, server: setup.serverId)
                let reader = attachmentACLHeaders("Bearer \(key)")
                let parentAttachment = try await attachmentACLUpload(client, headers: human, channel: setup.channelId, bytes: bytes)
                let messageData = try JSONSerialization.data(withJSONObject: [
                    "channelId": setup.channelId, "content": "private attachment anchor", "attachmentIds": [parentAttachment],
                ])
                let message = try await client.send(.post, headers: human, to: "/api/messages") { $0.body = .init(data: messageData) }
                #expect(message.status == .ok)
                let messageId = try #require(attachmentACLJSON(message)["id"] as? String)
                let thread = try await attachmentACLRequest(client, .post, "/api/channels/\(setup.channelId)/threads",
                    headers: human, body: ["parentMessageId": messageId])
                #expect(thread.status == .ok)
                let threadId = try #require(attachmentACLJSON(thread)["threadChannelId"] as? String)
                let threadAttachment = try await attachmentACLUpload(client, headers: human, channel: threadId, bytes: bytes)
                let ids = [parentAttachment, threadAttachment]
                for id in ids {
                    let path = "/internal/agent-api/attachments/\(id)"
                    let before = try await attachmentACLRequest(client, .get, path, headers: reader)
                    #expect(before.status == .ok)
                    #expect(before.body.data == bytes)
                    #expect(try await attachmentACLRequest(client, .get, path + "/url", headers: reader).status == .conflict)
                }
                let historyPath = "/internal/agent-api/history?channel=%23preview&consume=false"
                #expect(try await attachmentACLRequest(client, .get, historyPath, headers: reader).status == .ok)
                let removed: ClientResponse
                switch remover {
                case "agent":
                    removed = try await attachmentACLRequest(client, .delete,
                        "/internal/agent-api/channels/\(setup.channelId)/members",
                        headers: attachmentACLHeaders("Bearer \(adminKey)"), body: ["agent": agent])
                case "leave":
                    removed = try await attachmentACLRequest(client, .post,
                        "/internal/agent-api/channels/\(setup.channelId)/leave", headers: reader)
                default:
                    removed = try await attachmentACLRequest(client, .delete,
                        "/api/channels/\(setup.channelId)/members/agent/\(agent)", headers: human)
                }
                #expect(removed.status == .ok)
                for id in ids {
                    let path = "/internal/agent-api/attachments/\(id)"
                    for suffix in ["", "/url"] {
                        let denied = try await attachmentACLRequest(client, .get, path + suffix, headers: reader)
                        #expect(denied.status == .notFound)
                        if denied.status == .notFound {
                            #expect(try attachmentACLJSON(denied)["code"] as? String == "ATTACHMENT_UNAVAILABLE")
                        }
                        #expect(denied.body.data != bytes)
                    }
                    let witness = try await attachmentACLRequest(client, .get, "/api/attachments/\(id)", headers: human)
                    #expect(witness.status == .ok)
                    #expect(witness.body.data == bytes)
                }
                #expect(try await attachmentACLRequest(client, .get, historyPath, headers: reader).status == .notFound)
            }
        }
        await fixture.stop()
    } catch {
        await fixture.stop()
        throw error
    }
}
