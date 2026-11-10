// Task85 PRIVATE acceptance candidate. Live target did not exist at baseline.
// Requires owner65 AttachmentFlexAdmission and owner82 strict query + real Soto fixture.
import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import RaftObjectStorage
import TestSupport
import Testing
import Vapor
import VaporTesting

@Suite(.serialized) struct AttachmentURLBatchTests: Sendable {
    private let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgqPj/HwAEagJ39jVQDgAAAABJRU5ErkJggg==")!

    @Test(.timeLimit(.minutes(1))) func publishedUploadBatchAndHeaderlessBrowserGETDecryptRealObjects() async throws {
        try await withStorage { setup, storage in
            let bytes = image
            try await withApp { app in
                configure(app, services: batchServices(setup.accounts))
                try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
                    let boundary = "task85-real-image-upload"
                    var multipart = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"channelId\"\r\n\r\n\(setup.channelId)\r\n".utf8)
                    for name in ["first.png", "second.png"] {
                        multipart.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(name)\"\r\nContent-Type: image/png\r\n\r\n".utf8))
                        multipart.append(bytes); multipart.append(Data("\r\n".utf8))
                    }
                    multipart.append(Data("--\(boundary)--\r\n".utf8))
                    let uploadBody = multipart
                    var headers = batchHeaders(setup.authorization, setup.serverId)
                    headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
                    let uploaded = try await client.send(.post, headers: headers, to: "/api/attachments/upload") { $0.body = .init(data: uploadBody) }
                    #expect(uploaded.status == .ok)
                    let uploadBytes = try await attachmentPreviewBody(uploaded)
                    let ids = try JSONDecoder().decode(BatchUploadWire.self, from: uploadBytes).attachments.map(\.id)
                    #expect(ids.count == 2)
                    let first = try #require(ids.first)
                    let second = try #require(ids.last)
                    let response = try await postBatch(client, setup.authorization, setup.serverId,
                        #"{"attachmentIds":["\#(first)","\#(first.uppercased())","\#(first)","\#(second)",null,7,{},"invalid","00000000-0000-4000-8000-000000008500"]}"#)
                    #expect(response.status == .ok)
                    let result = try await batchWire(response)
                    #expect(Set(result.urls.map(\.id)) == Set(ids))
                    #expect(result.urls.count == 2)
                    for entry in result.urls {
                        let components = try #require(URLComponents(string: entry.url))
                        #expect(components.scheme == "http")
                        #expect(components.host == "127.0.0.1")
                        #expect(components.port == client.port)
                        #expect(components.path == "/api/attachments/\(entry.id)")
                        #expect(components.queryItems?.first { $0.name == "token" }?.value == String(setup.authorization.dropFirst(7)))
                        #expect(components.queryItems?.first { $0.name == "serverId" }?.value == setup.serverId)
                        #expect(components.queryItems?.first { $0.name == "disposition" }?.value == "inline")
                        // No Authorization, server scope, cookies, or preview capability is supplied here.
                        let browser = try await client.get(URI(string: entry.url))
                        #expect(browser.status == .ok)
                        let plaintext = try await attachmentPreviewBody(browser)
                        #expect(plaintext == bytes)
                        #expect(browser.headers[.contentType] == "image/png")
                        #expect(browser.headers[.contentDisposition]?.hasPrefix("inline;") == true)
                        #expect(browser.headers[HTTPField.Name("X-Content-Type-Options")!] == "nosniff")
                        #expect(setup.accounts.messagesAndThreadsStore.withState { $0.developmentAttachmentBytes[entry.id] } == nil)
                    }
                    let ciphertext = storage.state.value.withLock { Array($0.ciphertext.values) }
                    #expect(ciphertext.count == 2)
                    #expect(ciphertext.allSatisfy { $0 != bytes && $0.count == bytes.count + 28 })
                    #expect(setup.accounts.messagesAndThreadsStore.attachmentPreviewBody == nil)
                }
            }
        }
    }

    @Test func inputFilteringNullExpiryAndMissingStorageKeepNodeRefusals() async throws {
        let setup = batchSeedWithoutStorage()
        try await withApp { app in
            configure(app, services: batchServices(setup.accounts))
            try await app.testing { client in
                for input in ["{}", #"{"attachmentIds":null}"#, #"{"attachmentIds":"id"}"#, #"{"attachmentIds":[]}"#] {
                    let response = try await postBatch(client, setup.authorization, setup.serverId, input)
                    #expect(response.status == .badRequest)
                    let error = try await batchError(response)
                    #expect(error == "attachmentIds is required")
                }
                for input in [#"{"attachmentIds":[null,1,{},"invalid"]}"#,
                              "{\"attachmentIds\":[" + (0..<51).map { "\"\(batchID($0))\"" }.joined(separator: ",") + "]}"] {
                    let response = try await postBatch(client, setup.authorization, setup.serverId, input)
                    #expect(response.status == .badRequest)
                    let error = try await batchError(response)
                    #expect(error == "attachmentIds must hold 1..50 valid ids")
                }
                let valid = #"{"attachmentIds":["00000000-0000-4000-8000-000000008501"]}"#
                let unavailable = try await postBatch(client, setup.authorization, setup.serverId, valid)
                #expect(unavailable.status == .serviceUnavailable)
                let error = try await batchError(unavailable)
                #expect(error == "File storage is not configured on this server")
                let anonymous = try await postBatch(client, nil, setup.serverId, valid)
                #expect(anonymous.status == .unauthorized)
                let missingScope = try await postBatch(client, setup.authorization, nil, valid)
                #expect(missingScope.status == .badRequest)
            }
        }
        try await withStorage { configured, _ in
            try await withApp { app in
                configure(app, services: batchServices(configured.accounts))
                try await app.testing { client in
                    for values in [(0..<50).map(batchID), Array(repeating: batchID(0), count: 80)] {
                        let body = "{\"attachmentIds\":[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]}"
                        let response = try await postBatch(client, configured.authorization, configured.serverId, body)
                        #expect(response.status == .ok)
                        let result = try await batchWire(response)
                        #expect(result.urls.isEmpty)
                    }
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func queryCredentialsBasePolicyAndPublishedHeaderPropagation() async throws {
        try await withStorage { setup, _ in
            let id = try await setup.upload(image, filename: "query.png", mime: "image/png")
            let body = #"{"attachmentIds":["\#(id)"]}"#
            let token = String(setup.authorization.dropFirst(7))
            try await withApp { app in
                configure(app, services: batchServices(setup.accounts))
                try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
                    var path = URLComponents()
                    path.path = "/api/attachments/urls"
                    path.queryItems = [.init(name: "token", value: token), .init(name: "serverId", value: setup.serverId)]
                    let queryPath = try #require(path.string)
                    let response = try await postBatch(client, nil, nil, body, path: queryPath)
                    #expect(response.status == .ok)
                    let rows = try await batchWire(response)
                    let entry = try #require(rows.urls.first)
                    let browser = try await client.get(URI(string: entry.url))
                    #expect(browser.status == .ok)
                    let plaintext = try await attachmentPreviewBody(browser)
                    #expect(plaintext == image)
                    // Node authenticates query JWT after a generic invalid header,
                    // but its URL builder still propagates that original header.
                    let quirk = try await postBatch(client, "Bearer synthetic-invalid-header", nil, body, path: queryPath)
                    #expect(quirk.status == .ok)
                    let quirkRows = try await batchWire(quirk)
                    let quirkEntry = try #require(quirkRows.urls.first)
                    let components = try #require(URLComponents(string: quirkEntry.url))
                    #expect(components.queryItems?.first { $0.name == "token" }?.value == "synthetic-invalid-header")
                    let refusedBrowser = try await client.get(URI(string: quirkEntry.url))
                    #expect(refusedBrowser.status == .unauthorized)
                }
            }
            for slockdev in [false, true] {
                try await withApp { app in
                    configure(app, services: batchServices(setup.accounts, environment: [
                        "SERVER_URL": "https://configured.example", "DEPLOYMENT_ENV": slockdev ? "slockdev" : "production",
                    ]))
                    try await app.testing { client in
                        var headers = batchHeaders(setup.authorization, setup.serverId)
                        headers[HTTPField.Name("Host")!] = "incoming.example:8080"
                        headers[HTTPField.Name("X-Forwarded-Host")!] = "preview.example:8443, ignored.example"
                        headers[HTTPField.Name("X-Forwarded-Proto")!] = "https, http"
                        let response = try await client.send(.post, headers: headers, to: "/api/attachments/urls") { $0.body = .init(string: body) }
                        #expect(response.status == .ok)
                        let rows = try await batchWire(response)
                        let entry = try #require(rows.urls.first)
                        let components = try #require(URLComponents(string: entry.url))
                        #expect(components.host == (slockdev ? "preview.example" : "configured.example"))
                        #expect(components.scheme == "https")
                        #expect(components.port == (slockdev ? 8443 : nil))
                    }
                }
            }
            try await withApp { app in
                configure(app, services: batchServices(setup.accounts, environment: ["SERVER_URL": "://invalid-base"]))
                try await app.testing { client in
                    let response = try await postBatch(client, setup.authorization, setup.serverId, body)
                    #expect(response.status == .internalServerError)
                    let error = try await batchError(response)
                    #expect(error == "Failed to resolve attachment urls")
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func strictGuestAndThreadParentDenialsOmitInsteadOfCopyingPermissiveACL() async throws {
        try await withStorage { setup, _ in
            let id = try await setup.upload(image, filename: "hidden.png", mime: "image/png")
            setup.accounts.enableGuestRoleTransitions(serverId: setup.serverId)
            setup.accounts.oauth.addMember(serverId: setup.serverId, userId: setup.userId, role: "guest")
            setup.accounts.oauth.removeChannelHuman(channelId: setup.channelId, userId: setup.userId)
            setup.accounts.serversAndChannelsStore.removeMember(channelId: setup.channelId, memberId: setup.userId)
            setup.accounts.setChannelGuestVisibleForTesting(channelId: setup.channelId, visible: false)
            try await withApp { app in
                configure(app, services: batchServices(setup.accounts))
                try await app.testing { client in
                    let response = try await postBatch(client, setup.authorization, setup.serverId, #"{"attachmentIds":["\#(id)"]}"#)
                    #expect(response.status == .ok)
                    let rows = try await batchWire(response)
                    #expect(rows.urls.isEmpty)
                }
            }
            // Same real object owner, a thread, and a still-joined thread must not
            // substitute for revoked access to its current private parent.
            setup.accounts.oauth.addMember(serverId: setup.serverId, userId: setup.userId, role: "member")
            setup.accounts.setChannelPostablePrivateForTesting(channelId: setup.channelId)
            setup.accounts.oauth.setChannelType(id: setup.channelId, type: "private")
            setup.accounts.oauth.addChannelHuman(channelId: setup.channelId, userId: setup.userId)
            let parent = setup.accounts.addChannelMessageForTesting(channelId: setup.channelId, content: "synthetic parent", senderId: setup.userId)
            let thread = UUID().uuidString.lowercased()
            setup.accounts.addThreadChannel(serverId: setup.serverId, threadChannelId: thread,
                parentChannelId: setup.channelId, parentMessageId: parent, memberId: setup.userId)
            let upload = try await setup.accounts.agentsLifecycle.uploadAttachmentContents(authorization: setup.authorization,
                serverId: setup.serverId, channelId: thread, files: [.init(filename: "thread.png", mimeType: "image/png", bytes: image)])
            let threaded = try #require(upload.attachments.first?.id)
            setup.accounts.oauth.removeChannelHuman(channelId: setup.channelId, userId: setup.userId)
            setup.accounts.serversAndChannelsStore.removeMember(channelId: setup.channelId, memberId: setup.userId)
            try await withApp { app in
                configure(app, services: batchServices(setup.accounts))
                try await app.testing { client in
                    let response = try await postBatch(client, setup.authorization, setup.serverId, #"{"attachmentIds":["\#(threaded)"]}"#)
                    #expect(response.status == .ok)
                    let rows = try await batchWire(response)
                    #expect(rows.urls.isEmpty)
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func linkedJointBatchUsesCurrentActiveSiblingProjection() async throws {
        try await withStorage { setup, _ in
            let peer = UUID().uuidString.lowercased(); let peerServer = UUID().uuidString.lowercased()
            setup.accounts.addAccount(id: peer, email: "task85-joint-peer@slock.test", password: "password123")
            setup.accounts.markEmailVerified(userId: peer)
            setup.accounts.oauth.addOwnedServer(id: peerServer, slug: "task85-peer", name: "Peer", ownerId: peer)
            let hostProjection = setup.accounts.oauth.createChannel(serverId: setup.serverId, name: "joint-host", creatorUserId: setup.userId, type: "joint")
            let peerProjection = setup.accounts.oauth.createChannel(serverId: peerServer, name: "joint-peer", creatorUserId: peer, type: "joint")
            for (channel, server, user) in [(hostProjection, setup.serverId, setup.userId), (peerProjection, peerServer, peer)] {
                setup.accounts.addPostableChannel(serverId: server, channelId: channel, memberId: user, kind: "joint", name: "joint")
                setup.accounts.oauth.addChannelHuman(channelId: channel, userId: user)
                setup.accounts.addJointChannelProjection(localChannelId: channel, canonicalChannelId: setup.channelId, serverId: server)
            }
            let parent = setup.accounts.addChannelMessageForTesting(channelId: setup.channelId, content: "joint image host", senderId: setup.userId)
            let uploaded = try await setup.accounts.agentsLifecycle.uploadAttachmentContents(authorization: setup.authorization,
                serverId: setup.serverId, channelId: hostProjection, files: [.init(filename: "joint.png", mimeType: "image/png", bytes: image)])
            let linked = try #require(uploaded.attachments.first?.id)
            // Link the genuine encrypted upload to the canonical message, as the
            // message binding transaction does; never synthesize attachment bytes.
            setup.accounts.messagesAndThreadsStore.withState { $0.channelAttachments[linked]?.messageId = parent }
            let authorization = "Bearer \(setup.accounts.mintAccessTokenForTesting(userId: peer))"
            try await withApp { app in
                configure(app, services: batchServices(setup.accounts))
                try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
                    let body = #"{"attachmentIds":["\#(linked)"]}"#
                    let response = try await postBatch(client, authorization, peerServer, body)
                    #expect(response.status == .ok)
                    let rows = try await batchWire(response)
                    let entry = try #require(rows.urls.first)
                    let components = try #require(URLComponents(string: entry.url))
                    #expect(components.queryItems?.first { $0.name == "serverId" }?.value == peerServer)
                    let browser = try await client.get(URI(string: entry.url))
                    #expect(browser.status == .ok)
                    let plaintext = try await attachmentPreviewBody(browser)
                    #expect(plaintext == image)
                    for remove in [false, true] {
                        setup.accounts.serversAndChannelsStore.mutex.withLock { state in
                            if remove { state.jointProjections.removeAll { $0.localChannelId == peerProjection } }
                            else if let index = state.jointProjections.firstIndex(where: { $0.localChannelId == peerProjection }) {
                                state.jointProjections[index].status = "paused"
                            }
                        }
                        let unavailable = try await postBatch(client, authorization, peerServer, body)
                        #expect(unavailable.status == .ok)
                        let omitted = try await batchWire(unavailable)
                        #expect(omitted.urls.isEmpty)
                    }
                }
            }
        }
    }
}

private struct BatchUploadWire: Decodable { struct Row: Decodable { let id: String }; let attachments: [Row] }
private struct BatchWire: Decodable { let urls: [Entry]
    struct Entry: Decodable, CustomStringConvertible {
        let id: String; let url: String
        var description: String { "BatchWire.Entry(redacted)" }
        enum CodingKeys: String, CodingKey { case id, url, expiresAt }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id); url = try values.decode(String.self, forKey: .url)
            guard values.contains(.expiresAt), try values.decodeNil(forKey: .expiresAt) else {
                throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: values, debugDescription: "Expected explicit null expiry")
            }
        }
    }
}
private func batchWire(_ response: ClientResponse) async throws -> BatchWire {
    let bytes = try await attachmentPreviewBody(response); return try JSONDecoder().decode(BatchWire.self, from: bytes)
}
private func batchError(_ response: ClientResponse) async throws -> String {
    struct Body: Decodable { let error: String }
    let bytes = try await attachmentPreviewBody(response); return try JSONDecoder().decode(Body.self, from: bytes).error
}
private func batchHeaders(_ authorization: String?, _ server: String?) -> HTTPFields {
    var fields = HTTPFields(); fields[.contentType] = "application/json"
    fields[.authorization] = authorization; fields[HTTPField.Name("X-Server-Id")!] = server; return fields
}
private func postBatch(_ client: any TestClient, _ authorization: String?, _ server: String?, _ body: String,
                       path: String = "/api/attachments/urls") async throws -> ClientResponse {
    try await client.send(.post, headers: batchHeaders(authorization, server), to: URI(string: path)) { $0.body = .init(string: body) }
}
private func batchServices(_ accounts: EmailLoginDirectory, environment: [String: String] = [:]) -> FallbackServices {
    FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                     releaseEnvironment: environment, emailAccounts: accounts)
}
private func withStorage(_ body: (AttachmentPreviewAccounts, AttachmentPreviewStorageFixture) async throws -> Void) async throws {
    let storage = try AttachmentPreviewStorageFixture()
    do { try await body(AttachmentPreviewAccounts(storage: storage.storage), storage); await storage.stop() }
    catch { await storage.stop(); throw error }
}
private func batchID(_ value: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012llx", Int64(value)) }
private func batchSeedWithoutStorage() -> (accounts: EmailLoginDirectory, serverId: String, authorization: String) {
    let accounts = EmailLoginDirectory(); let user = UUID().uuidString.lowercased(); let server = UUID().uuidString.lowercased()
    accounts.oauth.jwtSecret = "task85-only-synthetic-signing-secret-2026-attachment-batch"
    accounts.addAccount(id: user, email: "batch-no-storage@slock.test", password: "password123")
    accounts.markEmailVerified(userId: user)
    accounts.oauth.addOwnedServer(id: server, slug: "batch-no-storage", name: "Batch", ownerId: user)
    return (accounts, server, "Bearer \(accounts.mintAccessTokenForTesting(userId: user))")
}
