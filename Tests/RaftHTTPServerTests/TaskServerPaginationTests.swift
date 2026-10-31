import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverTaskPagesWalkEveryTaskOnceAndValidateParams() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111324"
    let serverId = "33333333-3333-4333-8333-333333333492"
    accounts.addAccount(id: ownerId, email: "page-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-pagination", name: "Task Pagination", ownerId: ownerId)
    _ = accounts.oauth.createChannel(serverId: serverId, name: "gamma", creatorUserId: ownerId)
    let beta = accounts.oauth.createChannel(serverId: serverId, name: "beta", creatorUserId: ownerId)
    let alpha = accounts.oauth.createChannel(serverId: serverId, name: "alpha", creatorUserId: ownerId)
    let alphaIds = [
        accounts.addTask(channelId: alpha, title: "alpha-1", description: "alpha body 1"),
        accounts.addTask(channelId: alpha, title: "alpha-2", description: nil),
        accounts.addTask(channelId: alpha, title: "alpha-3", description: nil),
    ]
    let betaIds = [
        accounts.addTask(channelId: beta, title: "beta-1", description: nil),
        accounts.addTask(channelId: beta, title: "beta-2", description: nil),
    ]
    let expected = alphaIds + betaIds

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
                request.body = .init(string: "{\"email\":\"page-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            func get(_ path: String) async throws -> ClientResponse {
                try await client.send(.get, headers: headers, to: URI(string: path))
            }

            var cursor: String?
            var sizes: [Int] = []
            var seen: [String] = []
            repeat {
                var path = "/api/tasks/server?limit=2"
                if let cursor { path += "&cursor=\(cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cursor)" }
                let response = try await get(path)
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                let page = body?["tasks"] as? [[String: Any]] ?? []
                sizes.append(page.count)
                seen.append(contentsOf: page.compactMap { $0["id"] as? String })
                #expect(page.allSatisfy { $0.keys.contains("description") })
                cursor = body?["next_cursor"] as? String
            } while cursor != nil
            #expect(sizes == [2, 2, 1])
            #expect(seen == expected)

            for query in [
                "limit=0", "limit=501", "limit=abc", "limit=2&limit=3",
                "detail=bogus", "cursor=abc", "limit=2&cursor=%%%not-base64%%%",
            ] {
                #expect(try await get("/api/tasks/server?\(query)").status == .badRequest)
            }
            let wrongShape = Data("{\"c\":\"not-a-uuid\",\"n\":1}".utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            #expect(try await get("/api/tasks/server?limit=2&cursor=\(wrongShape)").status == .badRequest)
            let staleChannel = Data("{\"c\":\"\(UUID().uuidString.lowercased())\",\"n\":1}".utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            #expect(try await get("/api/tasks/server?limit=2&cursor=\(staleChannel)").status == .badRequest)

            let summary = try await get("/api/tasks/server?detail=summary&limit=10")
            #expect(summary.status == .ok)
            let summaryBody = try JSONSerialization.jsonObject(with: Data((summary.body.string ?? "").utf8)) as? [String: Any]
            #expect(summaryBody?["next_cursor"] == nil || summaryBody?["next_cursor"] is NSNull)
            let summaryTasks = summaryBody?["tasks"] as? [[String: Any]] ?? []
            #expect(summaryTasks.count == 5)
            #expect(summaryTasks.allSatisfy { !$0.keys.contains("description") })
            let withDesc = summaryTasks.first { $0["id"] as? String == alphaIds[0] }
            #expect(withDesc?["hasDescription"] as? Bool == true)
            #expect(withDesc?["descriptionBytes"] as? Int == Data("alpha body 1".utf8).count)
            let withoutDesc = summaryTasks.first { $0["id"] as? String == alphaIds[1] }
            #expect(withoutDesc?["hasDescription"] as? Bool == false)
            #expect(withoutDesc?["descriptionBytes"] as? Int == 0)

            let legacy = try await get("/api/tasks/server")
            #expect(legacy.status == .ok)
            let legacyBody = try JSONSerialization.jsonObject(with: Data((legacy.body.string ?? "").utf8)) as? [String: Any]
            #expect(legacyBody?.keys.sorted() == ["tasks"])
            let legacyTasks = legacyBody?["tasks"] as? [[String: Any]] ?? []
            #expect(legacyTasks.first { $0["id"] as? String == alphaIds[0] }?["description"] as? String == "alpha body 1")

            let nonUUID = try await get("/api/tasks/channel/not-a-uuid")
            #expect(nonUUID.status == .notFound)
            #expect((try JSONSerialization.jsonObject(with: Data((nonUUID.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Channel not found")
        }
    }
}
