import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func deletingAMachineRevokesItsComputerCredential() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111392"
    let serverId = "33333333-3333-4333-8333-333333333529"
    accounts.addAccount(id: ownerId, email: "computer-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "computer-revocation", name: "Computer Revocation", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"computer-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let attach = try await client.send(.post, headers: headers, to: "/api/computer/attach") { request in
                request.body = .init(string: "{\"serverSlug\":\"computer-revocation\",\"name\":\"audit-computer\"}")
            }
            #expect(attach.status == .created)
            let attachBody = try JSONSerialization.jsonObject(with: Data((attach.body.string ?? "").utf8)) as? [String: Any]
            let apiKey = attachBody?["apiKey"] as? String ?? ""
            let machineId = attachBody?["machineId"] as? String ?? ""
            #expect(apiKey.hasPrefix("raft_computer_"))
            #expect(!machineId.isEmpty)

            func runners(_ key: String) async throws -> ClientResponse {
                var runnerHeaders = HTTPFields()
                runnerHeaders[.authorization] = "Bearer \(key)"
                return try await client.send(.get, headers: runnerHeaders, to: "/internal/computer/runners")
            }
            #expect(try await runners(apiKey).status == .ok)

            let removed = try await client.send(.delete, headers: headers, to: "/api/servers/\(serverId)/machines/\(machineId)")
            #expect(removed.status == .ok)
            #expect(try await runners(apiKey).status == .unauthorized)
            #expect(try await runners("raft_computer_unknown").status == .unauthorized)
        }
    }
}
