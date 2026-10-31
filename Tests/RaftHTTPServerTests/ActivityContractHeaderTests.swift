import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func activitySyncEndpointsReportTheContractRevisionEvenOnRejection() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111386"
    let serverId = "33333333-3333-4333-8333-333333333525"
    accounts.addAccount(id: ownerId, email: "activity-contract@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "activity-contract", name: "Activity Contract", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"activity-contract@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            let expected = "raft.activity-sync;revision=2"
            let contractHeader = HTTPField.Name("X-Raft-Contract")!

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let snapshot = try await client.send(.get, headers: headers, to: "/api/channels/activity/snapshot")
            #expect(snapshot.status == .badRequest)
            #expect(snapshot.headers[contractHeader] == expected)
            #expect((snapshot.headers[HTTPField.Name("Access-Control-Expose-Headers")!] ?? "").contains("X-Raft-Contract"))

            var revisionHeaders = headers
            revisionHeaders[HTTPField.Name("X-Raft-Contract-Revision")!] = "1"
            let difference = try await client.send(.get, headers: revisionHeaders, to: "/api/channels/activity/difference?requestId=r1")
            #expect(difference.status == .badRequest)
            #expect(difference.headers[contractHeader] == expected)

            var garbageHeaders = headers
            garbageHeaders[HTTPField.Name("X-Raft-Contract-Revision")!] = "not-a-number"
            let garbage = try await client.send(.get, headers: garbageHeaders, to: "/api/channels/activity/snapshot")
            #expect(garbage.status == .badRequest)
            #expect(garbage.headers[contractHeader] == expected)
        }
    }
}
