import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func providerConnectionsAreGatedAndNeverEchoCredentials() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111244"
    let memberId = "11111111-1111-4111-8111-111111111245"
    let serverId = "33333333-3333-4333-8333-333333333440"
    accounts.addAccount(id: ownerId, email: "provider-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "provider-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "provider-api", name: "Provider API", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            let ownerToken = try await login("provider-owner@slock.test")
            let memberToken = try await login("provider-member@slock.test")

            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }

            let gatedRead = try await client.send(.get, headers: headers(ownerToken), to: "/api/provider-connections")
            #expect(gatedRead.status == .notFound)
            #expect((try JSONSerialization.jsonObject(with: Data((gatedRead.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "provider_connections_disabled")

            let gatedWrite = try await client.send(.post, headers: headers(ownerToken), to: "/api/provider-connections") { request in
                request.body = .init(string: "{\"name\":\"Hidden\",\"providerId\":\"deepseek\",\"apiKey\":\"disabled-secret\"}")
            }
            #expect(gatedWrite.status == .notFound)
            #expect((gatedWrite.body.string ?? "").contains("disabled-secret") == false)

            accounts.setProviderConnectionsEnabled(serverId: serverId, enabled: true)

            let forbiddenRead = try await client.send(.get, headers: headers(memberToken), to: "/api/provider-connections")
            #expect(forbiddenRead.status == .forbidden)
            let forbiddenWrite = try await client.send(.post, headers: headers(memberToken), to: "/api/provider-connections") { request in
                request.body = .init(string: "{\"name\":\"Nope\",\"providerId\":\"deepseek\",\"apiKey\":\"member-secret\"}")
            }
            #expect(forbiddenWrite.status == .forbidden)
            #expect((forbiddenWrite.body.string ?? "").contains("member-secret") == false)

            let alias = try await client.send(.post, headers: headers(ownerToken), to: "/api/provider-connections") { request in
                request.body = .init(string: "{\"name\":\"Alias\",\"providerId\":\"deepseek\",\"apiKey\":\"write-only-secret\",\"clientSecret\":\"unexpected-alias\"}")
            }
            #expect(alias.status == .badRequest)
            #expect((alias.body.string ?? "").contains("write-only-secret") == false)
            #expect((alias.body.string ?? "").contains("unexpected-alias") == false)

            let createdResponse = try await client.send(.post, headers: headers(ownerToken), to: "/api/provider-connections") { request in
                request.body = .init(string: "{\"name\":\"Team DeepSeek\",\"providerId\":\"deepseek\",\"apiKey\":\"api-private-value\"}")
            }
            #expect(createdResponse.status == .created)
            #expect((createdResponse.body.string ?? "").contains("api-private-value") == false)
            let created = try JSONSerialization.jsonObject(with: Data((createdResponse.body.string ?? "").utf8)) as? [String: Any]
            #expect(created?["status"] as? String == "unchecked")
            #expect(created?["hasCredential"] as? Bool == true)
            let createdId = created?["id"] as? String ?? ""

            let listResponse = try await client.send(.get, headers: headers(ownerToken), to: "/api/provider-connections")
            #expect(listResponse.status == .ok)
            #expect((listResponse.body.string ?? "").contains("api-private-value") == false)
            #expect((listResponse.body.string ?? "").contains("encryptedApiKey") == false)
            let list = try JSONSerialization.jsonObject(with: Data((listResponse.body.string ?? "").utf8)) as? [String: Any]
            let connections = list?["connections"] as? [[String: Any]] ?? []
            #expect(connections.map { $0["id"] as? String } == [createdId])
            let options = list?["providerOptions"] as? [[String: Any]] ?? []
            #expect(options.map { $0["id"] as? String } == EmailLoginDirectory.providerConnectionProviderIds)
            #expect(options.first { $0["id"] as? String == "google" }?["providerKind"] as? String == "preset")
            #expect(options.first { $0["id"] as? String == "openai-compatible" }?["providerKind"] as? String == "gateway")
            #expect(options.allSatisfy { (($0["label"] as? String) ?? "").isEmpty == false })
        }
    }
}
