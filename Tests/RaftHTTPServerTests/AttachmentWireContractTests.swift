import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

private func attachmentWireHeaders(_ authorization: String, server: String? = nil) -> HTTPFields {
    var result = HTTPFields()
    result[.authorization] = authorization
    if let server { result[HTTPField.Name("X-Server-Id")!] = server }
    return result
}

private func attachmentWireObject(_ response: ClientResponse) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: response.body.data ?? Data()) as? [String: Any])
}

private func attachmentWireUpload(
    _ client: any Client, setup: AttachmentPreviewAccounts, bytes: Data, filename: String, mime: String
) async throws -> [String: Any] {
    let boundary = "attachment-wire-contract"
    var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"channelId\"\r\n\r\n\(setup.channelId)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
    body.append(bytes)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    var headers = attachmentWireHeaders(setup.authorization, server: setup.serverId)
    headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
    let payload = body
    let response = try await client.send(.post, headers: headers, to: "/api/attachments/upload") { $0.body = .init(data: payload) }
    #expect(response.status == .ok)
    let rows = try #require(try attachmentWireObject(response)["attachments"] as? [[String: Any]])
    return try #require(rows.first)
}

/// Upstream attachments.ts:656-676 and internalAgentApi.ts:4890-4917.
/// Required null fields remain observable; raw bytes and headers are independent assertions.
@Test(arguments: ["png", "text", "binary"])
func attachmentUploadAndAgentDownloadPublishThePinnedWireContract(kind: String) async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        let setup = AttachmentPreviewAccounts(storage: fixture.storage)
        let agent = setup.accounts.oauth.createAgent(serverId: setup.serverId, name: "wire-reader")
        let key = setup.accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "wire-reader")
        let filename = kind == "png" ? "pilot.png" : kind == "text" ? "pilot.txt" : "pilot.bin"
        let mime = kind == "png" ? "image/png" : kind == "text" ? "text/plain" : "application/octet-stream"
        let bytes = kind == "png" ? try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
            : kind == "text" ? Data("hello wire\n".utf8) : Data((0..<256).map(UInt8.init))
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {}, emailAccounts: setup.accounts))
            try await app.testing { client in
                let uploaded = try await attachmentWireUpload(client, setup: setup, bytes: bytes, filename: filename, mime: mime)
                #expect(Set(uploaded.keys) == ["id", "filename", "mimeType", "sizeBytes", "width", "height", "thumbnailUrl", "rasterPreviewUrl"])
                #expect(uploaded["filename"] as? String == filename)
                #expect(uploaded["mimeType"] as? String == mime)
                #expect(uploaded["sizeBytes"] as? Int == bytes.count)
                for field in ["width", "height", "thumbnailUrl", "rasterPreviewUrl"] { #expect(uploaded[field] is NSNull) }
                let id = try #require(uploaded["id"] as? String)
                var human = attachmentWireHeaders(setup.authorization, server: setup.serverId)
                human[.contentType] = "application/json"
                let messageBody = try JSONSerialization.data(withJSONObject: [
                    "channelId": setup.channelId, "content": "full attachment envelope", "attachmentIds": [id],
                ])
                let created = try await client.send(.post, headers: human, to: "/api/messages") { $0.body = .init(data: messageBody) }
                #expect(created.status == .ok)
                let messageId = try #require(try attachmentWireObject(created)["id"] as? String)
                let agentHeaders = attachmentWireHeaders("Bearer \(key)")
                let history = try await client.get("/internal/agent-api/history?channel=%23preview&consume=false", headers: agentHeaders)
                #expect(history.status == .ok)
                let messages = try #require(try attachmentWireObject(history)["messages"] as? [[String: Any]])
                let message = try #require(messages.first { $0["id"] as? String == messageId })
                let attachments = try #require(message["attachments"] as? [[String: Any]])
                let row = try #require(attachments.first)
                #expect(Set(row.keys) == ["id", "filename", "mimeType", "sizeBytes", "width", "height", "thumbnailUrl", "commentCount"])
                #expect(row["id"] as? String == id)
                #expect(row["commentCount"] as? Int == 0)
                for field in ["width", "height", "thumbnailUrl"] { #expect(row[field] is NSNull) }
                let download = try await client.get(URI(string: "/internal/agent-api/attachments/\(id)"), headers: agentHeaders)
                #expect(download.status == .ok)
                #expect(download.body.data == bytes)
                #expect(download.headers[.contentType] == (kind == "text" ? "text/plain; charset=utf-8" : mime))
                #expect(download.headers[.cacheControl] == "private, immutable, max-age=31536000")
                #expect(download.headers[HTTPField.Name("X-Content-Type-Options")!] == "nosniff")
                let disposition = kind == "png" ? "inline" : "attachment"
                #expect(download.headers[.contentDisposition] == "\(disposition); filename=\"\(filename)\"; filename*=UTF-8''\(filename)")
                if kind == "text" {
                    let comment = try await client.send(.post, headers: human, to: URI(string: "/api/attachments/\(id)/comments")) {
                        $0.body = .init(string: #"{"content":"review this attachment"}"#)
                    }
                    #expect(comment.status == .ok)
                    for (disabled, count) in [(false, 1), (true, 0)] {
                        setup.accounts.setFeatureFlagKillSwitchForTesting(key: "attachment_comments_v0", killSwitch: disabled)
                        let counted = try await client.get("/internal/agent-api/history?channel=%23preview&consume=false", headers: agentHeaders)
                        #expect(counted.status == .ok)
                        let page = try #require(try attachmentWireObject(counted)["messages"] as? [[String: Any]])
                        let host = try #require(page.first { $0["id"] as? String == messageId })
                        let chips = try #require(host["attachments"] as? [[String: Any]])
                        #expect(chips.first?["commentCount"] as? Int == count)
                    }
                }
            }
        }
        await fixture.stop()
    } catch {
        await fixture.stop()
        throw error
    }
}

/// requireAgentCredentialAuth is a shared precondition, not a human auth envelope.
@Test(arguments: [nil, "Basic ignored", "bearer ignored", "Bearer", "Bearer "] as [String?])
func attachmentAgentSurfaceMissingCredentialUsesPinnedMiddlewareBody(authorization: String?) async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}))
        try await app.testing { client in
            var headers = HTTPFields()
            if let authorization { headers[.authorization] = authorization }
            for path in ["/internal/agent-api/", "/internal/agent-api/history?channel=%23missing",
                         "/internal/agent-api/attachments/11111111-1111-4111-8111-111111111111",
                         "/internal/agent-api/attachments/11111111-1111-4111-8111-111111111111/url",
                         "/internal/agent-api/knowledge", "/internal/agent-api/knowledge/search?q=attachments"] {
                let response = try await client.get(URI(string: path), headers: headers)
                #expect(response.status == .unauthorized)
                #expect(response.body.string == #"{"error":"Missing agent credential"}"#)
            }
            let integration = try await client.send(.post, headers: headers, to: "/internal/agent-api/integrations/app/manage")
            #expect(integration.status == .unauthorized)
            #expect(integration.body.string == #"{"error":"Missing agent credential"}"#)
        }
    }
}

/// auth.ts:739-755 classifies Bearer principals by isAgentApiKey before
/// handlers; other valid principal classes must not become a human auth error.
@Test func attachmentAgentSurfaceRejectsWrongPrincipalBeforeHandlers() async throws {
    let accounts = EmailLoginDirectory()
    let owner = UUID().uuidString.lowercased()
    let server = UUID().uuidString.lowercased()
    accounts.addAccount(id: owner, email: "principal-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: owner)
    accounts.oauth.addOwnedServer(id: server, slug: "principal", name: "Principal", ownerId: owner)
    let agent = accounts.oauth.createAgent(serverId: server, name: "principal-agent")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "principal-agent")
    let jwt = accounts.mintAccessTokenForTesting(userId: owner)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            #expect(try await client.get("/internal/agent-api/", headers: attachmentWireHeaders("Bearer \(key)")).status == .ok)
            for principal in [jwt, "sk_computer_fixture", "sk_machine_fixture", "sk_daemon_fixture", "opaque-principal"] {
                let headers = attachmentWireHeaders("Bearer \(principal)")
                for path in ["/internal/agent-api/", "/internal/agent-api/history?channel=%23missing",
                             "/internal/agent-api/attachments/11111111-1111-4111-8111-111111111111",
                             "/internal/agent-api/attachments/11111111-1111-4111-8111-111111111111/url",
                             "/internal/agent-api/knowledge", "/internal/agent-api/knowledge/search?q=attachments"] {
                    let response = try await client.get(URI(string: path), headers: headers)
                    #expect(response.status == .unauthorized)
                    #expect(response.body.string == #"{"error":"Invalid authentication: agent credential required","code":"invalid_principal"}"#)
                }
                let integration = try await client.send(.post, headers: headers, to: "/internal/agent-api/integrations/app/manage")
                #expect(integration.status == .unauthorized)
                #expect(integration.body.string == #"{"error":"Invalid authentication: agent credential required","code":"invalid_principal"}"#)
            }
            // The class check must not impose length/encoding constraints or
            // replace existing credential validity/capability/grant checks.
            let unknown = try await client.get("/internal/agent-api/", headers: attachmentWireHeaders("Bearer sk_agent_nope"))
            #expect(unknown.status == .unauthorized)
            #expect(try attachmentWireObject(unknown)["code"] as? String != "invalid_principal")
        }
    }
}

/// CLI agent/login.ts:169-174 validates these fields before saving a profile.
/// Role-dependent authorization facts come from the same pinned server matrix.
@Test(arguments: ["member", "admin", "owner"])
func attachmentAgentIdentityContainsCLIRequiredNamesAndServerAuthorization(role: String) async throws {
    let accounts = EmailLoginDirectory()
    let owner = UUID().uuidString.lowercased()
    let server = UUID().uuidString.lowercased()
    accounts.addAccount(id: owner, email: "wire-identity@slock.test", password: "password123")
    accounts.markEmailVerified(userId: owner)
    accounts.oauth.addOwnedServer(id: server, slug: "wire-identity", name: "Wire Identity", ownerId: owner)
    let agent = accounts.oauth.createAgent(serverId: server, name: "identity-reader", creatorUserId: owner, runtime: "external")
    accounts.oauth.updateAgentDisplayName(id: agent, displayName: "Identity Reader")
    accounts.oauth.setAgentRole(serverId: server, agentId: agent, role: role)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "channels"], name: "identity-reader")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let response = try await client.get("/internal/agent-api/", headers: attachmentWireHeaders("Bearer \(key)"))
            #expect(response.status == .ok)
            let body = try attachmentWireObject(response)
            #expect(Set(body.keys) == ["agentId", "agentName", "agentDisplayName", "serverId", "serverRole", "serverCapabilities", "credentialId", "scopes"])
            #expect(body["agentId"] as? String == agent)
            #expect(body["agentName"] as? String == "identity-reader")
            #expect(body["agentDisplayName"] as? String == "Identity Reader")
            #expect(body["serverId"] as? String == server)
            #expect(body["serverRole"] as? String == role)
            #expect((body["credentialId"] as? String)?.isEmpty == false)
            #expect(body["scopes"] as? [String] == ["channels", "read"])
            if let capabilities = body["serverCapabilities"] as? [String: Bool] {
                #expect(capabilities.count == 41)
                #expect(capabilities["viewChannel"] == true)
                #expect(capabilities["removeChannelMembers"] == (role != "member"))
                #expect(capabilities["manageBilling"] == (role == "owner"))
            } else { Issue.record("serverCapabilities is required by the identity contract") }
        }
    }
}
