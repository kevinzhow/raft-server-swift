import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func taskPeriodMetricsAggregateBeyondThePageCapAndRespectACL() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111333"
    let memberId = "11111111-1111-4111-8111-111111111334"
    let serverId = "33333333-3333-4333-8333-333333333499"
    accounts.addAccount(id: ownerId, email: "period-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "period-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "period-metrics", name: "Period metrics", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let alpha = accounts.oauth.createChannel(serverId: serverId, name: "alpha", creatorUserId: ownerId)
    let zulu = accounts.oauth.createChannel(serverId: serverId, name: "zulu", creatorUserId: ownerId)
    let hidden = accounts.oauth.createChannel(serverId: serverId, name: "hidden", creatorUserId: "00000000-0000-4000-8000-000000000000", type: "private")
    let iso = ISO8601DateFormatter()
    func date(_ text: String) -> Date { iso.date(from: text) ?? Date() }
    accounts.addCompletedTask(channelId: hidden, title: "Hidden current task", createdAt: date("2026-10-10T00:00:00Z"), completedAt: date("2026-10-11T00:00:00Z"))
    for index in 0..<1001 {
        accounts.addCompletedTask(channelId: alpha, title: "Old task \(index)", createdAt: date("2026-09-01T00:00:00Z"), completedAt: date("2026-09-02T00:00:00Z"))
    }
    accounts.addCompletedTask(channelId: zulu, title: "Current", createdAt: date("2026-10-10T00:00:00Z"), completedAt: date("2026-10-11T00:00:00Z"))
    accounts.addCompletedTask(channelId: zulu, title: "Previous", createdAt: date("2026-10-08T00:00:00Z"), completedAt: date("2026-10-10T00:00:00Z"))
    accounts.addCompletedTask(channelId: zulu, title: "Today", createdAt: date("2026-10-10T00:00:00Z"), completedAt: date("2026-10-18T00:00:00Z"))

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
            let ownerToken = try await login("period-owner@slock.test")
            let memberToken = try await login("period-member@slock.test")
            let query = "from=2026-10-04T00:00:00Z&midpoint=2026-10-11T00:00:00Z&to=2026-10-18T00:00:00Z"
            func get(_ token: String, _ suffix: String = "") async throws -> ClientResponse {
                try await client.send(.get, headers: headers(token), to: "/api/tasks/server/period-metrics?\(query)\(suffix)")
            }

            let response = try await get(ownerToken)
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let current = body?["current"] as? [String: Any]
            let previous = body?["previous"] as? [String: Any]
            #expect(current?["completed"] as? Int == 1)
            #expect(current?["durationSamples"] as? Int == 1)
            #expect((current?["meanHours"] as? NSNumber)?.doubleValue == 24)
            #expect((current?["medianHours"] as? NSNumber)?.doubleValue == 24)
            #expect(previous?["completed"] as? Int == 1)
            #expect((previous?["meanHours"] as? NSNumber)?.doubleValue == 48)

            let scoped = try await get(ownerToken, "&channelId=\(alpha)")
            let scopedBody = try JSONSerialization.jsonObject(with: Data((scoped.body.string ?? "").utf8)) as? [String: Any]
            #expect((scopedBody?["current"] as? [String: Any])?["completed"] as? Int == 0)

            #expect(try await get(memberToken).status == .forbidden)
            #expect(try await get(ownerToken, "&channelId=\(hidden)").status == .notFound)
            #expect(try await get(ownerToken, "&channelId=not-a-uuid").status == .badRequest)
            let shifted = query.replacingOccurrences(of: "2026-10-04", with: "2026-10-05")
            let shiftedResponse = try await client.send(.get, headers: headers(ownerToken), to: "/api/tasks/server/period-metrics?\(shifted)")
            #expect(shiftedResponse.status == .badRequest)
        }
    }
}
