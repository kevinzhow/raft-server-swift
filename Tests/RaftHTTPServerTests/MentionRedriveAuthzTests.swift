import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func mentionRedriveHidesAuthorizationBehindNotAccessible() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111315"
    let outsiderId = "11111111-1111-4111-8111-111111111316"
    let serverId = "33333333-3333-4333-8333-333333333485"
    accounts.addAccount(id: ownerId, email: "redrive-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: outsiderId, email: "redrive-outsider@slock.test", password: "password123")
    accounts.markEmailVerified(userId: outsiderId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "redrive", name: "Redrive", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "redrive-machine")
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "redrive-agent", creatorUserId: ownerId)
    let messageId = UUID().uuidString.lowercased()

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
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            func redrive(_ token: String) async throws -> ClientResponse {
                try await client.send(
                    .post,
                    headers: headers(token),
                    to: "/api/servers/\(serverId)/machines/\(machineId)/agents/\(agentId)/diagnostic/mention-delivery/\(messageId)/redrive"
                ) { request in
                    request.body = .init(string: "{\"expectedVersion\":0}")
                }
            }
            func status(_ response: ClientResponse) throws -> String? {
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return body?["status"] as? String
            }

            let outsiderToken = try await login("redrive-outsider@slock.test")
            let ownerToken = try await login("redrive-owner@slock.test")

            let refused = try await redrive(outsiderToken)
            #expect(refused.status == .notFound)
            #expect(try status(refused) == "NOT_ACCESSIBLE")

            let allowed = try await redrive(ownerToken)
            #expect(allowed.status == .notFound)
            #expect(try status(allowed) == "NOT_JOINABLE")
        }
    }
}
