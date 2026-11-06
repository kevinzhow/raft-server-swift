import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct PageFixture {
    let accounts = EmailLoginDirectory()
    let serverId: String
    let ownerId: String

    init(serverId: String, ownerId: String) {
        self.serverId = serverId
        self.ownerId = ownerId
        accounts.addAccount(id: ownerId, email: "page-owner@task-page.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "task-pagination", name: "Task Pagination", ownerId: ownerId)
    }

    func headers() -> HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))"
        headers[.contentType] = "application/json"
        headers[HTTPField.Name("X-Server-Id")!] = serverId
        return headers
    }
}

private func json(_ text: String?) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((text ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func serverTaskListRejectsNonUUIDChannelAndInvalidPaginationParams() async throws {
    let fixture = PageFixture(serverId: "33333333-3333-4333-8333-000001092011", ownerId: "11111111-1111-4111-8111-000001092011")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let notFound = try await client.get(URI(string: "/api/tasks/channel/not-a-uuid"), headers: fixture.headers())
            #expect(notFound.status == .notFound)
            #expect(json(notFound.body.string)["error"] as? String == "Channel not found")

            for query in ["limit=0", "limit=501", "limit=abc", "limit=2&limit=3", "detail=bogus", "cursor=abc", "limit=2&cursor=%%%not-base64%%%"] {
                let response = try await client.get(URI(string: "/api/tasks/server?\(query)"), headers: fixture.headers())
                #expect(response.status == .badRequest, Comment(rawValue: query))
            }
            let wrongShape = Data("{\"c\":\"not-a-uuid\",\"n\":1}".utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let wrongShapeResponse = try await client.get(URI(string: "/api/tasks/server?limit=2&cursor=\(wrongShape)"), headers: fixture.headers())
            #expect(wrongShapeResponse.status == .badRequest)
        }
    }
}

@Test func serverTaskPaginationWalksEveryTaskOnceAndComposesFilters() async throws {
    let fixture = PageFixture(serverId: "33333333-3333-4333-8333-000001092012", ownerId: "11111111-1111-4111-8111-000001092012")
    let accounts = fixture.accounts
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func createChannel(_ name: String) async throws -> String {
                let response = try await client.send(.post, headers: fixture.headers(), to: URI(string: "/api/channels")) { request in
                    request.body = .init(string: "{\"name\":\"\(name)\",\"type\":\"channel\"}")
                }
                return try #require(json(response.body.string)["id"] as? String)
            }
            func createTasks(_ channelId: String, _ titles: [String]) async throws -> [String] {
                let payload = try JSONSerialization.data(withJSONObject: ["tasks": titles.map { ["title": $0] }])
                let response = try await client.send(.post, headers: fixture.headers(), to: URI(string: "/api/tasks/channel/\(channelId)")) { request in
                    request.body = .init(string: String(decoding: payload, as: UTF8.self))
                }
                return try #require(json(response.body.string)["taskIds"] as? [String])
            }
            let gamma = try await createChannel("gamma")
            let beta = try await createChannel("beta")
            let alpha = try await createChannel("alpha")
            _ = gamma
            let alphaTasks = try await createTasks(alpha, ["alpha-1", "alpha-2", "alpha-3"])
            let betaTasks = try await createTasks(beta, ["beta-1", "beta-2"])

            var seen: [String] = []
            var pageSizes: [Int] = []
            var cursor: String?
            repeat {
                let path = "/api/tasks/server?limit=2" + (cursor.map { "&cursor=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)" } ?? "")
                let response = try await client.get(URI(string: path), headers: fixture.headers())
                #expect(response.status == .ok)
                let body = json(response.body.string)
                let tasks = body["tasks"] as? [[String: Any]] ?? []
                pageSizes.append(tasks.count)
                seen.append(contentsOf: tasks.compactMap { $0["id"] as? String })
                for task in tasks { #expect(task.keys.contains("description")) }
                cursor = body["next_cursor"] as? String
            } while cursor != nil
            #expect(pageSizes == [2, 2, 1])
            #expect(seen == alphaTasks + betaTasks)

            let created = alphaTasks + betaTasks
            _ = try await client.send(.patch, headers: fixture.headers(), to: URI(string: "/api/tasks/\(created[1])/claim"))
            _ = try await client.send(.patch, headers: fixture.headers(), to: URI(string: "/api/tasks/\(created[3])/claim"))
            let todos = try await client.get(URI(string: "/api/tasks/server?status=todo&limit=2"), headers: fixture.headers())
            let todoIds = (json(todos.body.string)["tasks"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            #expect(todoIds == [created[0], created[2], created[4]] || todoIds == [created[0], created[2]])
        }
    }
}

@Test func serverTaskSummaryKeepsContractedKeysAndLegacyShapeIsIntact() async throws {
    let fixture = PageFixture(serverId: "33333333-3333-4333-8333-000001092013", ownerId: "11111111-1111-4111-8111-000001092013")
    let accounts = fixture.accounts
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let channel = try await client.send(.post, headers: fixture.headers(), to: URI(string: "/api/channels")) { request in
                request.body = .init(string: "{\"name\":\"summary-room\",\"type\":\"channel\"}")
            }
            let channelId = try #require(json(channel.body.string)["id"] as? String)
            let payload = try JSONSerialization.data(withJSONObject: ["tasks": [["title": "has a body", "description": "héllo summary world"], ["title": "bodiless"]]])
            let created = try await client.send(.post, headers: fixture.headers(), to: URI(string: "/api/tasks/channel/\(channelId)")) { request in
                request.body = .init(string: String(decoding: payload, as: UTF8.self))
            }
            let ids = try #require(json(created.body.string)["taskIds"] as? [String])
            _ = try await client.send(.patch, headers: fixture.headers(), to: URI(string: "/api/tasks/\(ids[0])/claim"))

            let summary = try await client.get(URI(string: "/api/tasks/server?detail=summary&limit=10"), headers: fixture.headers())
            #expect(summary.status == .ok, Comment(rawValue: summary.body.string ?? ""))
            let summaryBody = json(summary.body.string)
            #expect(summaryBody["next_cursor"] == nil || summaryBody["next_cursor"] is NSNull)
            let rows = summaryBody["tasks"] as? [[String: Any]] ?? []
            let expectedKeys: Set<String> = ["channelId", "channelName", "channelType", "claimedAt", "claimedById", "claimedByName", "claimedByType", "completedAt", "createdAt", "createdById", "createdByName", "createdByType", "descriptionBytes", "hasDescription", "id", "isLegacy", "messageId", "readOnlyReason", "revision", "source", "status", "taskNumber", "title", "updatedAt"]
            for row in rows {
                #expect(Set(row.keys) == expectedKeys)
                #expect(row["description"] == nil)
                #expect(row["source"] as? String == "tasks")
                #expect(row["channelName"] as? String == "summary-room")
                #expect(row["createdById"] as? String == fixture.ownerId)
            }
            let legacyEarly = try await client.get(URI(string: "/api/tasks/server"), headers: fixture.headers())
            let legacyEarlyIds = (json(legacyEarly.body.string)["tasks"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
            #expect(rows.compactMap { $0["id"] as? String }.sorted() == legacyEarlyIds, "summary ids equal legacy ids")
            let withDesc = try #require(rows.first { $0["title"] as? String == "has a body" }, Comment(rawValue: "summary=\(summary.body.string ?? "")"))
            #expect(withDesc["hasDescription"] as? Bool == true)
            #expect(withDesc["descriptionBytes"] as? Int == "héllo summary world".utf8.count)
            #expect(withDesc["claimedById"] as? String == fixture.ownerId)
            #expect(withDesc["claimedByName"] as? String != nil)

            let legacy = try await client.get(URI(string: "/api/tasks/server"), headers: fixture.headers())
            let raw = legacy.body.string ?? ""
            let legacyBody = json(raw)
            #expect(Set(legacyBody.keys) == ["tasks"])
            #expect(legacy.headers[HTTPField.Name("x-response-bytes")!] == String(raw.utf8.count))
            let legacyTask = (legacyBody["tasks"] as? [[String: Any]] ?? []).first { $0["title"] as? String == "has a body" }
            #expect(legacyTask?["description"] as? String == "héllo summary world")
        }
    }
}

@Test func serverTaskPaginationMatchesLegacyVisibilityAndWarnsOnlyForNewShapeOverTripwire() async throws {
    let fixture = PageFixture(serverId: "33333333-3333-4333-8333-000001092014", ownerId: "11111111-1111-4111-8111-000001092014")
    let accounts = fixture.accounts
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let channelResponse = try await client.send(.post, headers: fixture.headers(), to: URI(string: "/api/channels")) { request in
                request.body = .init(string: "{\"name\":\"big-room\",\"type\":\"channel\"}")
            }
            let channelId = try #require(json(channelResponse.body.string)["id"] as? String)
            _ = accounts.addTaskWithDescriptionForTesting(channelId: channelId, title: "huge card", description: String(repeating: "x", count: 8 * 1024 * 1024 + 4096))

            let legacy = try await client.get(URI(string: "/api/tasks/server"), headers: fixture.headers())
            let paged = try await client.get(URI(string: "/api/tasks/server?limit=1"), headers: fixture.headers())
            #expect(legacy.status == .ok)
            #expect(paged.status == .ok)
            #expect(legacy.headers[HTTPField.Name("x-response-bytes")!] != nil)
            #expect(paged.headers[HTTPField.Name("x-response-bytes")!] != nil)
            let warning = try #require(accounts.lastTaskServerWarningForTesting())
            #expect(warning.contains("[tasks/server]"))
            #expect(warning.contains("paginated/summary"))
            #expect(warning.contains(fixture.serverId))
        }
    }
}

@Test func serverTaskCursorForInaccessibleChannelIsRejected() async throws {
    let fixture = PageFixture(serverId: "33333333-3333-4333-8333-000001092015", ownerId: "11111111-1111-4111-8111-000001092015")
    let accounts = fixture.accounts
    let readerId = "11111111-1111-4111-8111-000001092002"
    accounts.addAccount(id: readerId, email: "page-reader@task-page.test", password: "password123")
    accounts.markEmailVerified(userId: readerId)
    accounts.oauth.addMember(serverId: fixture.serverId, userId: readerId, role: "member")
    let hiddenJoint = accounts.oauth.createChannel(serverId: fixture.serverId, name: "hidden-joint", creatorUserId: fixture.ownerId, type: "joint")
    let cursor = Data("{\"c\":\"\(hiddenJoint)\",\"n\":1}".utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: readerId))"
            headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let response = try await client.get(URI(string: "/api/tasks/server?limit=2&cursor=\(cursor)"), headers: headers)
            #expect(response.status == .badRequest)
        }
    }
}
