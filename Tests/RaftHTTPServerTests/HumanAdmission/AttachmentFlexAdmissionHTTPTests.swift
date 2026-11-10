import Foundation
import HTTPTypes
import Testing
import Vapor
import VaporTesting
import TestSupport
@testable import RaftHTTP
@testable import RaftHTTPServer
import RaftObjectStorage

private let flexRequired = #"{"error":"Authentication required"}"#
private let humanMissing = #"{"error":"Missing or invalid Authorization header","code":"auth_required"}"#
private let humanInvalid = #"{"error":"Invalid or expired token","code":"auth_required"}"#
private let absentAttachment = #"{"error":"Attachment not found"}"#

private func expectFlexError(_ response: ClientResponse, status: Int, body: String) {
    #expect(Int(response.status.code) == status)
    #expect(response.body.string == body)
    #expect(response.headers[.contentLength] == String(body.utf8.count))
    #expect(response.headers[.contentType] == "application/json; charset=utf-8")
    #expect(response.headers[.cacheControl] == "private, no-store")
    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
}

private func flexSend(_ client: any Client, _ method: HTTPRequest.Method, _ path: String,
    token: String? = nil, serverId: String? = nil, query: [URLQueryItem] = [], body: String? = nil
) async throws -> ClientResponse {
    var url = URLComponents()
    url.path = path
    url.queryItems = query.isEmpty ? nil : query
    var headers = HTTPFields()
    if let token { headers[.authorization] = "Bearer \(token)" }
    if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
    if body != nil { headers[.contentType] = "application/json" }
    let uri = try #require(url.string)
    return try await client.send(method, headers: headers, to: URI(string: uri)) { request in
        if let body { request.body = .init(string: body) }
    }
}

private func flexServices() -> (services: FallbackServices, owner: String, token: String, server: String) {
    let services = FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {})
    let accounts = services.emailAccounts
    accounts.oauthFlows.configureSigningSecret("task65-explicit-fixture-preview-signing-key-32-bytes")
    let owner = "11111111-1111-4111-8111-111111111651"
    let server = "33333333-3333-4333-8333-333333333677"
    // These seed real checked stores and issue through the existing auth owner.
    // Deliberately leave email unverified: early serving has no human gate.
    accounts.addAccount(id: owner, email: "flex-owner@example.com", password: "SyntheticPassword123!")
    accounts.oauth.addOwnedServer(id: server, slug: "flex-owner", name: "Flex Owner", ownerId: owner)
    return (services, owner, accounts.mintAccessTokenForTesting(userId: owner), server)
}

@Test func attachmentFlexRunsOnAllSixServingShapesAndLegacyFallthrough() async throws {
    let fixture = flexServices()
    let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let paths: [(HTTPRequest.Method, String)] = [
        (.post, "/api/attachments/urls"), (.get, "/api/attachments/\(id)/url"),
        (.get, "/api/attachments/\(id)/preview"), (.get, "/api/attachments/\(id)/html-preview-url"),
        (.get, "/api/attachments/\(id)/html-preview"), (.get, "/api/attachments/\(id)"),
        (.post, "/api/attachments/upload"), (.get, "/api/attachments/comments/counts"),
        (.post, "/api/attachments/\(id)/comments"), (.get, "/api/attachments/upload-sessions/not-a-uuid")
    ]
    try await withApp { app in
        configure(app, services: fixture.services)
        try await app.testing { client in
            for (method, path) in paths {
                let response = try await flexSend(client, method, path, body: method == .post ? "{}" : nil)
                expectFlexError(response, status: 401, body: flexRequired)
            }
            let invalidPreview = try await flexSend(client, .get, "/api/attachments/\(id)/html-preview",
                query: [.init(name: "previewToken", value: "invalid"), .init(name: "serverId", value: fixture.server)])
            expectFlexError(invalidPreview, status: 401, body: flexRequired)
            let head = try await flexSend(client, .head, "/api/attachments/\(id)")
            #expect(head.status == .unauthorized)
            #expect((head.body.string ?? "").isEmpty)
            #expect(head.headers[.contentLength] == "35")
            #expect(head.headers[.cacheControl] == "private, no-store")
        }
    }
}

@Test func attachmentNarrowUploadRouterRunsBeforeFlexOnlyForItsExactMatches() async throws {
    let fixture = flexServices()
    let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let routes: [(HTTPRequest.Method, String)] = [
        (.get, "/api/attachments/upload-capabilities"),
        (.get, "/api/attachments/upload-sessions/not-a-uuid/active"),
        (.post, "/api/attachments/upload-sessions"),
        (.post, "/api/attachments/upload-sessions/\(id)/complete"),
        (.delete, "/api/attachments/upload-sessions/\(id)"),
        (.get, "/api/attachments/upload-sessions/\(id)")
    ]
    try await withApp { app in
        configure(app, services: fixture.services)
        try await app.testing { client in
            for (method, path) in routes {
                let response = try await flexSend(client, method, path, body: method == .post ? "{}" : nil)
                expectFlexError(response, status: 401, body: humanMissing)
            }
            let narrow = try await flexSend(client, .get, "/api/attachments/upload-capabilities", token: fixture.token)
            expectFlexError(narrow, status: 403, body: #"{"error":"Email verification required"}"#)
            let legacy = try await flexSend(client, .post, "/api/attachments/upload", token: fixture.token, body: "{}")
            expectFlexError(legacy, status: 400, body: #"{"error":"Missing X-Server-Id"}"#)
        }
    }
}

@Test func attachmentFlexPreservesHeaderQueryAndLaterHeaderOnlyAuthentication() async throws {
    let fixture = flexServices()
    let missing = "/api/attachments/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/url"
    let query = [URLQueryItem(name: "token", value: fixture.token), .init(name: "serverId", value: fixture.server)]
    try await withApp { app in
        configure(app, services: fixture.services)
        try await app.testing { client in
            // The unverified user reaches the serving leaf via query JWT.
            let queryRead = try await flexSend(client, .get, missing, query: query)
            expectFlexError(queryRead, status: 404, body: absentAttachment)
            let fallbackRead = try await flexSend(client, .get, missing, token: "invalid-access-token", query: query)
            expectFlexError(fallbackRead, status: 404, body: absentAttachment)
            let queryWrite = try await flexSend(client, .post, "/api/attachments/upload", query: query, body: "{}")
            expectFlexError(queryWrite, status: 401, body: humanMissing)
            let fallbackWrite = try await flexSend(client, .post, "/api/attachments/upload", token: "invalid-access-token", query: query, body: "{}")
            expectFlexError(fallbackWrite, status: 401, body: humanInvalid)
            let wrongServer = try await flexSend(client, .get, missing, token: fixture.token,
                serverId: "33333333-3333-4333-8333-333333333678", query: query)
            expectFlexError(wrongServer, status: 403, body: #"{"error":"Not a member of this server"}"#)
            let duplicate = try await flexSend(client, .get, missing, query: query + [.init(name: "token", value: fixture.token)])
            expectFlexError(duplicate, status: 401, body: flexRequired)
            let stranger = "11111111-1111-4111-8111-111111111652"
            fixture.services.emailAccounts.addAccount(id: stranger, email: "flex-stranger@example.com", password: "SyntheticPassword123!")
            let strangerToken = fixture.services.emailAccounts.mintAccessTokenForTesting(userId: stranger)
            let headerWins = try await flexSend(client, .get, missing, token: strangerToken, query: query)
            expectFlexError(headerWins, status: 403, body: #"{"error":"Not a member of this server"}"#)
        }
    }
}

@Test func attachmentFlexPreservesMachineComputerAndAgentPrincipalBoundaries() async throws {
    let fixture = flexServices()
    let accounts = fixture.services.emailAccounts
    let machine = accounts.registerMachineWithKeyForTesting(serverId: fixture.server, userId: fixture.owner, name: "flex-machine")
    accounts.linkComputerForTesting(serverId: fixture.server, machineId: machine.id)
    let computerKey = try #require(accounts.computerAPIKeyForTesting(machineId: machine.id))
    let agentId = accounts.oauth.createAgent(serverId: fixture.server, name: "flex-agent", runtime: "claude")
    let agentKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "flex-agent-key")
    let missing = "/api/attachments/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/url"
    let query = [URLQueryItem(name: "token", value: fixture.token), .init(name: "serverId", value: fixture.server)]
    try await withApp { app in
        configure(app, services: fixture.services)
        try await app.testing { client in
            for key in [machine.apiKey, computerKey] {
                // Bound machine server wins over an unrelated header scope.
                let read = try await flexSend(client, .get, missing, token: key,
                    serverId: "33333333-3333-4333-8333-333333333678")
                expectFlexError(read, status: 404, body: absentAttachment)
                let write = try await flexSend(client, .post, "/api/attachments/upload", token: key, body: "{}")
                expectFlexError(write, status: 401, body: humanInvalid)
            }
            let invalidMachine = try await flexSend(client, .get, missing, token: "sk_machine_invalid", query: query)
            expectFlexError(invalidMachine, status: 401, body: #"{"error":"Invalid machine API key"}"#)
            let invalidComputer = try await flexSend(client, .get, missing, token: "sk_computer_invalid", query: query)
            expectFlexError(invalidComputer, status: 401, body: #"{"error":"Invalid computer credential"}"#)
            let agentOnly = try await flexSend(client, .get, missing, token: agentKey)
            expectFlexError(agentOnly, status: 401, body: flexRequired)
            let agentWithQuery = try await flexSend(client, .get, missing, token: agentKey, query: query)
            expectFlexError(agentWithQuery, status: 404, body: absentAttachment)
            let machineQuery = try await flexSend(client, .get, missing,
                query: [.init(name: "token", value: machine.apiKey), .init(name: "serverId", value: fixture.server)])
            expectFlexError(machineQuery, status: 401, body: flexRequired)
        }
    }
}

@Test func attachmentIssuedHumanAndMachinePreviewProofsPassFlexBeforeMethodFallthrough() async throws {
    try await withSingleURLStorage { storage in
    let fixture = flexServices()
    let accounts = fixture.services.emailAccounts
    let channelId = accounts.oauth.createChannel(serverId: fixture.server, name: "flex-preview", creatorUserId: fixture.owner)
    accounts.addPostableChannel(serverId: fixture.server, channelId: channelId, memberId: fixture.owner, name: "flex-preview")
    let bytes = Data("<html><body>Published preview capability</body></html>".utf8)
    let attachmentId = accounts.addChannelAttachment(channelId: channelId, uploaderId: fixture.owner,
        filename: "preview.html", mimeType: "text/html", sizeBytes: bytes.count, bytes: bytes)
    let reference = try await storage.storage.put(attachmentID: attachmentId, bytes: bytes)
    accounts.configureAttachmentStorage(storage.storage)
    accounts.messagesAndThreadsStore.withState { state in
        state.attachmentObjectReferences[attachmentId] = reference
        state.developmentAttachmentBytes.removeValue(forKey: attachmentId)
    }
    let machine = accounts.registerMachineWithKeyForTesting(serverId: fixture.server, userId: fixture.owner, name: "preview-machine")
    try await withApp { app in
        configure(app, services: fixture.services)
        try await app.testing { client in
            for token in [fixture.token, machine.apiKey] {
                // Bootstrap through the published real issuer. The emitted token
                // is input to an independently Node-derived 74-byte assertion.
                let mint = try await flexSend(client, .get, "/api/attachments/\(attachmentId)/html-preview-url",
                    token: token, serverId: fixture.server)
                try #require(mint.status == .ok)
                let object = try #require(JSONSerialization.jsonObject(with: Data((mint.body.string ?? "").utf8)) as? [String: Any])
                let url = try #require(object["url"] as? String)
                let parsed = try #require(URLComponents(string: url))
                let query = try #require(parsed.queryItems)
                // The auth helper checks path, not HTTP method. A POST is not
                // served by the public GET router, so later requireAuth yields74.
                let post = try await flexSend(client, .post, parsed.path, query: query, body: "{}")
                expectFlexError(post, status: 401, body: humanMissing)
                let ordinary = try await flexSend(client, .get, "/api/attachments/\(attachmentId)/url", query: query)
                expectFlexError(ordinary, status: 401, body: flexRequired)
                let wrongId = try await flexSend(client, .get,
                    "/api/attachments/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/html-preview", query: query)
                expectFlexError(wrongId, status: 401, body: flexRequired)
            }
        }
    }
    }
}

@Test func attachmentRetiredAccessJWTFailsBeforeScopeButMayFallbackToAnotherLiveQueryJWT() async throws {
    let fixture = flexServices()
    let accounts = fixture.services.emailAccounts
    let other = "11111111-1111-4111-8111-111111111653"
    accounts.addAccount(id: other, email: "flex-live@example.com", password: "SyntheticPassword123!")
    accounts.oauth.addMember(serverId: fixture.server, userId: other, role: "member")
    let queryToken = accounts.mintAccessTokenForTesting(userId: other)
    accounts.retireUserForTesting(userId: fixture.owner)
    let missing = "/api/attachments/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/url"
    try await withApp { app in
        configure(app, services: fixture.services)
        try await app.testing { client in
            let retired = try await flexSend(client, .get, missing, token: fixture.token)
            expectFlexError(retired, status: 401, body: flexRequired)
            let fallback = try await flexSend(client, .get, missing, token: fixture.token,
                query: [.init(name: "token", value: queryToken), .init(name: "serverId", value: fixture.server)])
            expectFlexError(fallback, status: 404, body: absentAttachment)
        }
    }
}

@Test func attachmentPreviewLeafUsesOneExpressScalarBoundaryForBareEmptyAndRepeatedQueries() async throws {
    let fixture = flexServices()
    let accounts = fixture.services.emailAccounts
    let channelId = accounts.oauth.createChannel(serverId: fixture.server, name: "scalar-preview", creatorUserId: fixture.owner)
    accounts.addPostableChannel(serverId: fixture.server, channelId: channelId, memberId: fixture.owner, name: "scalar-preview")
    let bytes = Data("Actual non-HTML document".utf8)
    let id = accounts.addChannelAttachment(channelId: channelId, uploaderId: fixture.owner,
        filename: "document.txt", mimeType: "text/plain", sizeBytes: bytes.count, bytes: bytes)
    let bearerForbidden = #"{"error":"User bearer query tokens cannot authorize HTML preview"}"#
    let nonHTML = #"{"error":"Attachment is not previewable HTML"}"#
    let invalidPreview = #"{"error":"Invalid attachment preview token"}"#
    let cases: [([URLQueryItem], Int, String)] = [
        ([.init(name: "token", value: nil)], 403, bearerForbidden),
        ([.init(name: "token", value: "")], 403, bearerForbidden),
        ([.init(name: "token", value: "a"), .init(name: "token", value: "b")], 415, nonHTML),
        ([.init(name: "previewToken", value: "a"), .init(name: "previewToken", value: "b")], 415, nonHTML),
        ([.init(name: "previewToken", value: nil)], 415, nonHTML),
        ([.init(name: "previewToken", value: "")], 415, nonHTML),
        ([.init(name: "previewToken", value: " ")], 403, invalidPreview)
    ]
    try await withApp { app in
        configure(app, services: fixture.services)
        try await app.testing { client in
            for (query, status, body) in cases {
                let response = try await flexSend(client, .get, "/api/attachments/\(id)/html-preview",
                    token: fixture.token, serverId: fixture.server, query: query)
                expectFlexError(response, status: status, body: body)
            }
        }
    }
}
