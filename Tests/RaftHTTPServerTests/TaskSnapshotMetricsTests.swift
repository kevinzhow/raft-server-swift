import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func taskSnapshotMetricsAggregateVisibleFactsOnly() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111335"
    let memberId = "11111111-1111-4111-8111-111111111336"
    let serverId = "33333333-3333-4333-8333-333333333500"
    accounts.addAccount(id: ownerId, email: "snapshot-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "snapshot-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "snapshot-metrics", name: "Snapshot metrics", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let visible = accounts.oauth.createChannel(serverId: serverId, name: "visible", creatorUserId: ownerId)
    let hidden = accounts.oauth.createChannel(serverId: serverId, name: "hidden", creatorUserId: "00000000-0000-4000-8000-000000000000", type: "private")
    let iso = ISO8601DateFormatter()
    func date(_ text: String) -> Date { iso.date(from: text) ?? Date() }
    for index in 0..<501 {
        accounts.addTaskSnapshot(
            channelId: visible,
            title: "Review \(index)",
            status: "in_review",
            createdAt: date("2026-07-01T00:00:00Z"),
            updatedAt: date("2026-08-09T00:00:00Z")
        )
    }
    accounts.addTaskSnapshot(
        channelId: visible,
        title: "Done",
        status: "done",
        createdAt: date("2026-07-02T00:00:00Z"),
        updatedAt: date("2026-07-03T00:00:00Z"),
        completedAt: date("2026-07-03T00:00:00Z")
    )
    accounts.addTaskSnapshot(
        channelId: hidden,
        title: "Hidden",
        status: "done",
        createdAt: date("2026-07-01T00:00:00Z"),
        updatedAt: date("2026-07-02T00:00:00Z"),
        completedAt: date("2026-07-02T00:00:00Z")
    )

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
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("snapshot-owner@slock.test")
            let memberToken = try await login("snapshot-member@slock.test")
            func get(_ token: String, _ suffix: String = "") async throws -> ClientResponse {
                try await client.send(.get, headers: headers(token), to: "/api/tasks/server/snapshot-metrics\(suffix)")
            }

            let response = try await get(ownerToken)
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["total"] as? Int == 502)
            #expect(body?["inReview"] as? Int == 501)
            #expect(body?["done"] as? Int == 1)
            #expect(body?["durationSamples"] as? Int == 1)
            #expect((body?["medianHours"] as? NSNumber)?.doubleValue == 24)
            #expect((body?["p90Hours"] as? NSNumber)?.doubleValue == 24)
            #expect(body?["firstCreatedAt"] as? String == "2026-07-01T00:00:00.000Z")
            #expect(body?["latestUpdatedAt"] as? String == "2026-08-09T00:00:00.000Z")

            let scoped = try await get(ownerToken, "?channelId=\(visible)")
            #expect((try JSONSerialization.jsonObject(with: Data((scoped.body.string ?? "").utf8)) as? [String: Any])?["total"] as? Int == 502)
            #expect(try await get(ownerToken, "?channelId=\(hidden)").status == .notFound)
            #expect(try await get(memberToken).status == .forbidden)
        }
    }
}
