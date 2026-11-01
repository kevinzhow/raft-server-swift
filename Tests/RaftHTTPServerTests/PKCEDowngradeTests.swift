import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct PKCEDowngradeFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let serverSlug: String
    let ownerId: String
    let ownerEmail: String
    let clientKey: String
    let clientSecret: String
    let redirectURI: String
    let agentName: String
}

private func makePKCEDowngradeFixture(suffix: String) throws -> PKCEDowngradeFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 190_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 220_000 + number)
    let ownerEmail = "pkce-\(suffix)@raft.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    let slug = "pkce-\(suffix)"
    accounts.oauth.addOwnedServer(id: serverId, slug: slug, name: "PKCE downgrade", ownerId: ownerId)
    let redirectURI = "https://rp.example.test/login/generic_oauth"
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "PKCE RP",
        clientId: "pkce-\(suffix)",
        returnUrl: redirectURI,
        allowedScopes: ["openid", "profile"]
    )
    let agentName = "PkceAgent-\(suffix)"
    _ = accounts.oauth.createAgent(serverId: serverId, name: agentName, runtime: "external")
    return PKCEDowngradeFixture(
        accounts: accounts,
        serverId: serverId,
        serverSlug: slug,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        clientKey: created.clientId,
        clientSecret: created.clientSecret,
        redirectURI: redirectURI,
        agentName: agentName
    )
}

private func pkceLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func pkceObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func basicAuthorization(_ clientKey: String, _ secret: String) -> String {
    "Basic " + Data("\(clientKey):\(secret)".utf8).base64EncodedString()
}

@Test func pkceDowngradeRejectsUnsolicitedVerifiersWithoutConsumingTheCode() async throws {
    for kind in ["agent-code", "agent-request", "human-code", "human-oidc"] {
        let fixture = try makePKCEDowngradeFixture(suffix: kind == "agent-code" ? "851" : kind == "agent-request" ? "852" : kind == "human-code" ? "853" : "854")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let session = try await pkceLogin(client, email: fixture.ownerEmail)
                var authorization = HTTPFields()
                authorization[.contentType] = "application/json"
                let code: String
                if kind.hasPrefix("agent") {
                    authorization[.authorization] = basicAuthorization(fixture.clientKey, fixture.clientSecret)
                    let requested = try await client.send(.post, headers: authorization, to: "/api/oauth/requests/agent") { request in
                        request.body = .init(string: "{\"serverSlug\":\"\(fixture.serverSlug)\",\"agentName\":\"\(fixture.agentName)\",\"scopes\":[\"openid\",\"profile\"]}")
                    }
                    #expect(requested.status == .ok)
                    code = try pkceObject(requested)["requestId"] as? String ?? ""
                } else {
                    authorization[.authorization] = "Bearer \(session)"
                    let oidc = kind == "human-oidc"
                    let body = "{\"clientId\":\"\(fixture.clientKey)\",\"serverId\":\"\(fixture.serverId)\",\"returnUrl\":\"\(fixture.redirectURI)\",\"scopes\":[\"openid\",\"profile\"]\(oidc ? ",\"oidc\":true,\"nonce\":\"pkce-nonce\",\"server\":\"\(fixture.serverSlug)\"" : "")}"
                    let issued = try await client.send(.post, headers: authorization, to: "/api/oauth/authorize/human") { request in
                        request.body = .init(string: body)
                    }
                    #expect(issued.status == .ok)
                    code = try pkceObject(issued)["code"] as? String ?? ""
                }

                func exchange(verifierJSON: String?, mount: String) async throws -> ClientResponse {
                    var headers = HTTPFields()
                    headers[.authorization] = basicAuthorization(fixture.clientKey, fixture.clientSecret)
                    headers[.contentType] = "application/json"
                    let grant = kind == "agent-request" ? "urn:slock:grant-type:agent_request" : "authorization_code"
                    let codeField = kind == "agent-request" ? "\"requestId\":\"\(code)\"" : "\"code\":\"\(code)\""
                    let verifier = verifierJSON.map { ",\"code_verifier\":\($0)" } ?? ""
                    let path = mount.isEmpty
                        ? "/api/oauth/token"
                        : "/oidc/\(fixture.serverSlug)/api/oauth/token"
                    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                        request.body = .init(string: "{\"grant_type\":\"\(grant)\",\(codeField),\"redirect_uri\":\"\(fixture.redirectURI)\"\(verifier)}")
                    }
                }

                let verifiers: [String?] = [
                    "\"rp-verifier-abcdefghijklmnopqrstuvwxyz-0123456789\"",
                    "\"\"",
                    "null",
                    "[\"verifier\"]",
                ]
                for mount in ["", "/oidc"] {
                    for verifier in verifiers {
                        let response = try await exchange(verifierJSON: verifier, mount: mount)
                        #expect(response.status == .badRequest)
                        let body = try pkceObject(response)
                        #expect(body["error"] as? String == "invalid_grant")
                        #expect(body["access_token"] == nil)
                        #expect(body["id_token"] == nil)
                    }
                }

                let legitimate = try await exchange(verifierJSON: nil, mount: "")
                #expect(legitimate.status == .ok)
                #expect((try pkceObject(legitimate)["access_token"] as? String)?.isEmpty == false)

                let replay = try await exchange(verifierJSON: nil, mount: "")
                if kind == "human-oidc" {
                    #expect(replay.status == .badRequest)
                } else {
                    #expect(replay.status == .conflict)
                }
            }
        }
    }
}
