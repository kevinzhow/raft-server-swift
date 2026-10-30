import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func directoryObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func agentDirectoryListsOnlyThisServersLiveAgents() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111231"
    let serverId = "33333333-3333-4333-8333-333333333425"
    let otherServerId = "33333333-3333-4333-8333-333333333426"
    accounts.addAccount(id: ownerId, email: "directory-231@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "directory-231", name: "Directory", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "other-231", name: "Other", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "DirectoryAgent")
    _ = accounts.oauth.createAgent(serverId: otherServerId, name: "ForeignAgent")
    let deletedId = accounts.oauth.createAgent(serverId: serverId, name: "DeletedAgent")
    accounts.oauth.deleteAgent(id: deletedId)
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Directory only",
        clientId: "directory-231",
        allowedScopes: ["openid", "profile", "agent:read"]
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login() async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"directory-231@slock.test\",\"password\":\"password123\"}")
                }
                #expect(response.status == .ok)
                return try directoryObject(response)["accessToken"] as? String ?? ""
            }

            func mintHumanToken(scopes: String) async throws -> String {
                let session = try await login()
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(session)"
                headers[.contentType] = "application/json"
                let authorize = try await client.send(.post, headers: headers, to: "/api/oauth/authorize/human") { request in
                    request.body = .init(string: "{\"clientId\":\"directory-231\",\"serverId\":\"\(serverId)\",\"scopes\":[\(scopes)]}")
                }
                #expect(authorize.status == .ok)
                let code = try directoryObject(authorize)["code"] as? String ?? ""
                var tokenHeaders = HTTPFields()
                tokenHeaders[.contentType] = "application/json"
                let exchanged = try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/token") { request in
                    request.body = .init(string: "{\"clientId\":\"directory-231\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\"}")
                }
                #expect(exchanged.status == .ok)
                return try directoryObject(exchanged)["access_token"] as? String ?? ""
            }

            let bearer = try await mintHumanToken(scopes: "\"openid\",\"profile\",\"agent:read\"")
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(bearer)"
            let response = try await client.send(
                .get,
                headers: headers,
                to: "/api/oauth/agents?server_id=\(otherServerId)&agentId=foreign"
            )
            #expect(response.status == .ok)
            #expect(response.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            let rows = try directoryObject(response)["agents"] as? [[String: Any]] ?? []
            #expect(rows.map { $0["id"] as? String } == [agentId])
            #expect(rows.first.map { $0.keys.sorted() } == ["avatar_url", "display_name", "handle", "id", "picture"])
            #expect(rows.first?["handle"] as? String == "DirectoryAgent")

            let scoped = try await client.send(
                .get,
                headers: headers,
                to: "/oidc/directory-231/api/oauth/agents?server_id=\(otherServerId)"
            )
            #expect(scoped.status == .ok)
            #expect((try directoryObject(scoped)["agents"] as? [[String: Any]])?.map { $0["id"] as? String } == [agentId])

            let crossServer = try await client.send(.get, headers: headers, to: "/oidc/other-231/api/oauth/agents")
            #expect(crossServer.status == .unauthorized)
            #expect((try directoryObject(crossServer))["agents"] == nil)

            let discovery = try await client.send(
                .get,
                headers: HTTPFields(),
                to: "/oidc/directory-231/api/oauth/.well-known/openid-configuration"
            )
            #expect(discovery.status == .ok)
            let document = try directoryObject(discovery)
            #expect((document["scopes_supported"] as? [String])?.contains("agent:read") == true)
            #expect((document["agents_endpoint"] as? String)?.hasSuffix("/oidc/directory-231/api/oauth/agents") == true)

            let identityOnly = try await mintHumanToken(scopes: "\"openid\",\"profile\"")
            var identityHeaders = HTTPFields()
            identityHeaders[.authorization] = "Bearer \(identityOnly)"
            #expect(try await client.send(.get, headers: identityHeaders, to: "/api/oauth/agents").status == .forbidden)

            accounts.oauth.setClientEnabled(clientRecordId: created.id, enabled: false)
            #expect(try await client.send(.get, headers: headers, to: "/api/oauth/agents").status == .forbidden)
            accounts.oauth.setClientEnabled(clientRecordId: created.id, enabled: true)

            accounts.oauth.removeMember(serverId: serverId, userId: ownerId)
            #expect(try await client.send(.get, headers: headers, to: "/api/oauth/agents").status == .unauthorized)

            accounts.oauth.addMember(serverId: serverId, userId: ownerId, role: "owner")
            var requestHeaders = HTTPFields()
            requestHeaders[.contentType] = "application/json"
            let requested = try await client.send(.post, headers: requestHeaders, to: "/api/oauth/requests/agent") { request in
                request.body = .init(string: "{\"clientId\":\"directory-231\",\"clientSecret\":\"\(created.clientSecret)\",\"serverSlug\":\"directory-231\",\"agentName\":\"DirectoryAgent\",\"scopes\":[\"openid\",\"profile\",\"agent:read\"]}")
            }
            #expect(requested.status == .ok)
            let requestId = try directoryObject(requested)["requestId"] as? String ?? ""
            let exchanged = try await client.send(.post, headers: requestHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"directory-231\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\"\(requestId)\"}")
            }
            #expect(exchanged.status == .ok)
            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(try directoryObject(exchanged)["access_token"] as? String ?? "")"
            let asAgent = try await client.send(.get, headers: agentHeaders, to: "/api/oauth/agents")
            #expect(asAgent.status == .ok)
            #expect((try directoryObject(asAgent)["agents"] as? [[String: Any]])?.map { $0["id"] as? String } == [agentId])

            accounts.oauth.removeAgentMember(serverId: serverId, agentId: agentId)
            #expect(try await client.send(.get, headers: agentHeaders, to: "/api/oauth/agents").status == .unauthorized)

            for missing in ["not-a-token", ""] {
                var badHeaders = HTTPFields()
                if !missing.isEmpty { badHeaders[.authorization] = "Bearer \(missing)" }
                let bad = try await client.send(.get, headers: badHeaders, to: "/api/oauth/agents")
                #expect(bad.status == .unauthorized)
                #expect((try directoryObject(bad))["agents"] == nil)
            }
        }
    }
}

@Test func agentDirectoryRejectsIdentityOnlyExpiredAndRevokedCredentials() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111232"
    let serverId = "33333333-3333-4333-8333-333333333427"
    accounts.addAccount(id: ownerId, email: "directory-232@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "directory-232", name: "Directory", ownerId: ownerId)
    _ = accounts.oauth.createAgent(serverId: serverId, name: "DirectoryAgent")
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Directory only",
        clientId: "directory-232",
        allowedScopes: ["openid", "profile"]
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"directory-232@slock.test\",\"password\":\"password123\"}")
            }
            let session = try directoryObject(login)["accessToken"] as? String ?? ""

            func authorize(_ scopes: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(session)"
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: "/api/oauth/authorize/human") { request in
                    request.body = .init(string: "{\"clientId\":\"directory-232\",\"serverId\":\"\(serverId)\",\"scopes\":[\(scopes)]}")
                }
            }
            func exchange(_ code: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/oauth/token") { request in
                    request.body = .init(string: "{\"clientId\":\"directory-232\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\"}")
                }
                #expect(response.status == .ok)
                return try directoryObject(response)["access_token"] as? String ?? ""
            }

            let webhookScope = try await authorize("\"agent:read\"")
            #expect(webhookScope.status == .badRequest)

            accounts.oauth.setClientAllowedScopes(
                clientRecordId: created.id,
                scopes: ["openid", "profile", "agent:read"]
            )
            let identityOnlyCode = try directoryObject(try await authorize("\"openid\",\"profile\""))["code"] as? String ?? ""
            let identityOnly = try await exchange(identityOnlyCode)
            var identityHeaders = HTTPFields()
            identityHeaders[.authorization] = "Bearer \(identityOnly)"
            #expect(try await client.send(.get, headers: identityHeaders, to: "/api/oauth/agents").status == .forbidden)

            for credential in [nil, "not-a-token", created.clientSecret] {
                var headers = HTTPFields()
                if let credential { headers[.authorization] = "Bearer \(credential)" }
                let response = try await client.send(.get, headers: headers, to: "/api/oauth/agents")
                #expect(response.status == .unauthorized)
                #expect((try directoryObject(response))["agents"] == nil)
            }

            let code = try directoryObject(try await authorize("\"openid\",\"profile\",\"agent:read\""))["code"] as? String ?? ""
            let bearer = try await exchange(code)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(bearer)"
            #expect(try await client.send(.get, headers: headers, to: "/api/oauth/agents").status == .ok)

            accounts.oauth.revokeAccessTokens(clientRecordId: created.id)
            #expect(try await client.send(.get, headers: headers, to: "/api/oauth/agents").status == .unauthorized)

            let renewed = try await exchange(try directoryObject(try await authorize("\"openid\",\"profile\",\"agent:read\""))["code"] as? String ?? "")
            var renewedHeaders = HTTPFields()
            renewedHeaders[.authorization] = "Bearer \(renewed)"
            #expect(try await client.send(.get, headers: renewedHeaders, to: "/api/oauth/agents").status == .ok)

            var requestHeaders = HTTPFields()
            requestHeaders[.contentType] = "application/json"
            let requested = try await client.send(.post, headers: requestHeaders, to: "/api/oauth/requests/agent") { request in
                request.body = .init(string: "{\"clientId\":\"directory-232\",\"clientSecret\":\"\(created.clientSecret)\",\"serverSlug\":\"directory-232\",\"agentName\":\"DirectoryAgent\",\"scopes\":[\"openid\",\"profile\",\"agent:read\"]}")
            }
            let requestId = try directoryObject(requested)["requestId"] as? String ?? ""
            let agentTokenResponse = try await client.send(.post, headers: requestHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"directory-232\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\"\(requestId)\"}")
            }
            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(try directoryObject(agentTokenResponse)["access_token"] as? String ?? "")"
            #expect(try await client.send(.get, headers: agentHeaders, to: "/api/oauth/agents").status == .ok)

            accounts.oauth.revokeAgentGrants(clientRecordId: created.id)
            #expect(try await client.send(.get, headers: agentHeaders, to: "/api/oauth/agents").status == .unauthorized)
        }
    }
}
