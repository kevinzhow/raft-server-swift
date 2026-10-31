import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func taskMutationRoutesRefuseAnUnknownOrMessageOnlyId() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111337"
    let serverId = "33333333-3333-4333-8333-333333333501"
    accounts.addAccount(id: ownerId, email: "task-projection@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-projection", name: "Task Projection", ownerId: ownerId)
    _ = accounts.oauth.createChannel(serverId: serverId, name: "task-projection-room", creatorUserId: ownerId)

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
                request.body = .init(string: "{\"email\":\"task-projection@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let messageOnlyId = UUID().uuidString.lowercased()
            let claim = try await client.send(.patch, headers: headers, to: "/api/tasks/\(messageOnlyId)/claim")
            #expect(claim.status == .notFound)

            let status = try await client.send(.patch, headers: headers, to: "/api/tasks/\(messageOnlyId)/status") { request in
                request.body = .init(string: "{\"status\":\"in_progress\"}")
            }
            #expect(status.status == .notFound)

            let assign = try await client.send(.patch, headers: headers, to: "/api/tasks/\(messageOnlyId)/assignee") { request in
                request.body = .init(string: "{\"assignee\":null}")
            }
            #expect(assign.status == .notFound)

            let delete = try await client.send(.delete, headers: headers, to: "/api/tasks/\(messageOnlyId)")
            #expect(delete.status == .notFound)
        }
    }
}
