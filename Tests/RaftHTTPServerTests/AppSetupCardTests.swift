import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func installationCardsCarryCanonicalSetupAndRejectChangedDeclarations() async throws {
    let accounts = EmailLoginDirectory()
    let sourceId = "33333333-3333-4333-8333-000001080001"
    let targetId = "33333333-3333-4333-8333-000001080002"
    let ownerId = "11111111-1111-4111-8111-000001080001"
    accounts.addAccount(id: ownerId, email: "setup-card@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: sourceId, slug: "publisher", name: "Publisher", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: targetId, slug: "target", name: "Target", ownerId: ownerId)
    let created = try accounts.oauth.createClient(
        serverId: sourceId, createdByUserId: ownerId, name: "Setup Card App", clientId: "setup-card-app",
        returnUrl: "https://setup.example.test/callback",
        setupUrl: "https://setup.example.test/configure", setupDescription: "Choose a repository"
    )
    accounts.oauth.setClientAppType(clientRecordId: created.id, appType: "third_party_global")
    accounts.oauth.publishClient(clientRecordId: created.id, humanMarketplaceVisible: true)
    let agent = accounts.oauth.createAgent(serverId: targetId, name: "CardAgent", runtime: "external")
    let agentKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send", "read"], name: "setup-card")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"setup-card@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var ownerHeaders = HTTPFields()
            ownerHeaders[.authorization] = "Bearer \(token)"
            ownerHeaders[.contentType] = "application/json"
            ownerHeaders[HTTPField.Name("X-Server-Id")!] = targetId
            var sourceHeaders = ownerHeaders
            sourceHeaders[HTTPField.Name("X-Server-Id")!] = sourceId
            let channelResponse = try await client.send(.post, headers: ownerHeaders, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"setup-review\",\"type\":\"channel\"}")
            }
            #expect(channelResponse.status == .ok || channelResponse.status == .created)
            let channelBody = try JSONSerialization.jsonObject(with: Data((channelResponse.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let channelId = try #require(channelBody["id"] as? String)
            accounts.oauth.addChannelAgent(channelId: channelId, agentId: agent)
            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(agentKey)"
            agentHeaders[.contentType] = "application/json"

            func prepare(_ setupUrl: String, _ revision: Int) async throws -> (Int, [String: Any]) {
                let body = "{\"target\":\"#setup-review\",\"action\":{\"type\":\"integration:install_marketplace_app\",\"clientId\":\"\(created.id)\",\"clientKey\":\"setup-card-app\",\"scopes\":[\"openid\"],\"setupUrl\":\"\(setupUrl)\",\"setupRevision\":\(revision)}}"
                let response = try await client.send(.post, headers: agentHeaders, to: "/internal/agent-api/prepare-action") { request in
                    request.body = .init(string: body)
                }
                return (Int(response.status.code), (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let first = try await prepare("https://attacker.example.test/not-canonical", 999)
            #expect(first.0 == 201, Comment(rawValue: String(describing: first.1)))
            let metadata = try #require(first.1["metadata"] as? [String: Any])
            let action = try #require(metadata["action"] as? [String: Any])
            #expect(action["setupUrl"] as? String == "https://setup.example.test/configure")
            #expect(action["setupRevision"] as? Int == 1)
            let firstCard = try #require(first.1["messageId"] as? String)

            let patch = try await client.send(.patch, headers: sourceHeaders, to: "/api/integrations/clients/\(created.id)") { request in
                request.body = .init(string: "{\"setupUrl\":\"https://setup.example.test/revised\"}")
            }
            #expect(patch.status == .ok)
            let staleExecute = try await client.send(.post, headers: ownerHeaders, to: "/api/actions/\(firstCard)/execute") { request in
                request.body = .init(string: "{}")
            }
            #expect(staleExecute.status == .conflict)
            #expect(staleExecute.body.string?.contains("APP_SETUP_CHANGED") == true)
            let read = try await client.get(URI(string: "/api/integrations/clients/\(created.id)/setup"), headers: ownerHeaders)
            #expect(read.status == .notFound, "stale approval did not install the App")

            let fresh = try await prepare("https://setup.example.test/revised", 2)
            #expect(fresh.0 == 201)
            let freshCard = try #require(fresh.1["messageId"] as? String)
            let execute = try await client.send(.post, headers: ownerHeaders, to: "/api/actions/\(freshCard)/execute") { request in
                request.body = .init(string: "{}")
            }
            #expect(execute.status == .ok)
            let executed = try JSONSerialization.jsonObject(with: Data((execute.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let execMetadata = try #require(executed["metadata"] as? [String: Any])
            let result = try #require(execMetadata["result"] as? [String: Any])
            let setupUrl = try #require(result["setupUrl"] as? String)
            #expect(URLComponents(string: setupUrl)?.path == "/revised")
            #expect(setupUrl.contains("server_id=\(targetId)"))
        }
    }
}

@Test func registrationCardsValidateAndCarryTheSetupDeclaration() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001080003"
    let ownerId = "11111111-1111-4111-8111-000001080003"
    accounts.addAccount(id: ownerId, email: "setup-register@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "register", name: "Register", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "RegisterAgent", runtime: "external")
    let agentKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send", "read"], name: "setup-register")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"setup-register@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var ownerHeaders = HTTPFields()
            ownerHeaders[.authorization] = "Bearer \(token)"
            ownerHeaders[.contentType] = "application/json"
            ownerHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let channelResponse = try await client.send(.post, headers: ownerHeaders, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"setup-registration\",\"type\":\"channel\"}")
            }
            let channelBody = try JSONSerialization.jsonObject(with: Data((channelResponse.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let channelId = try #require(channelBody["id"] as? String)
            accounts.oauth.addChannelAgent(channelId: channelId, agentId: agent)
            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(agentKey)"
            agentHeaders[.contentType] = "application/json"

            func prepare(_ setupUrl: String, _ description: String) async throws -> (Int, [String: Any]) {
                let body = "{\"target\":\"#setup-registration\",\"action\":{\"type\":\"integration:register_app\",\"name\":\"Registered setup\",\"clientKey\":\"registered-setup\",\"category\":\"Developer Tools\",\"returnUrl\":\"https://registered.example.test/callback\",\"scopes\":[\"openid\"],\"setupUrl\":\"\(setupUrl)\",\"setupDescription\":\"\(description)\"}}"
                let response = try await client.send(.post, headers: agentHeaders, to: "/internal/agent-api/prepare-action") { request in
                    request.body = .init(string: body)
                }
                return (Int(response.status.code), (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let invalid1 = try await prepare("http://registered.example.test/setup", "Select a repository")
            #expect(invalid1.0 == 400, Comment(rawValue: String(describing: invalid1.1)))
            #expect(try await prepare("https://registered.example.test/setup#secret", "Select a repository").0 == 400)
            #expect(try await prepare("https://registered.example.test/setup", "two\\nlines").0 == 400)

            let valid = try await prepare("https://registered.example.test/setup", "Select a repository")
            #expect(valid.0 == 201)
            let messageId = try #require(valid.1["messageId"] as? String)
            let execute = try await client.send(.post, headers: ownerHeaders, to: "/api/actions/\(messageId)/execute") { request in
                request.body = .init(string: "{}")
            }
            #expect(execute.status == .ok)
            let recordId = try #require(accounts.oauth.clientRecordIdForServer(serverId: serverId, clientKey: "registered-setup"))
            let declaration = try #require(accounts.oauth.clientSetupDeclarationForTesting(clientRecordId: recordId))
            #expect(declaration.url == "https://registered.example.test/setup")
            #expect(declaration.description == "Select a repository")
        }
    }
}
