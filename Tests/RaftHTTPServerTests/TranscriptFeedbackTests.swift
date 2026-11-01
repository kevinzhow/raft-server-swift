import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func transcriptFeedbackIsAcceptedForAdminsAndCreatorsOnly() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111312"
    let creatorId = "11111111-1111-4111-8111-111111111313"
    let extraId = "11111111-1111-4111-8111-111111111314"
    let serverId = "33333333-3333-4333-8333-333333333484"
    for (id, email) in [
        (ownerId, "transcript-owner@slock.test"),
        (creatorId, "transcript-creator@slock.test"),
        (extraId, "transcript-extra@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "transcript", name: "Transcript", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: creatorId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: extraId, role: "member")
    let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "machine")
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "feedback-agent", creatorUserId: creatorId)
    let reportId = UUID().uuidString.lowercased()

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
            func post(_ token: String, _ report: String, body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(token), to: "/api/servers/\(serverId)/machines/\(machineId)/agents/\(agentId)/feedback/\(report)/transcript") { request in
                    request.body = .init(string: body)
                }
            }
            let ownerToken = try await login("transcript-owner@slock.test")
            let creatorToken = try await login("transcript-creator@slock.test")
            let extraToken = try await login("transcript-extra@slock.test")

            let accepted = try await post(ownerToken, reportId, body: "{\"reportGeneratedAt\":\"2026-07-20T16:40:04.797Z\"}")
            #expect(accepted.status == .accepted)
            let body = try JSONSerialization.jsonObject(with: Data((accepted.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["accepted"] as? Bool == true)
            #expect(body?["feedbackReportId"] as? String == reportId)
            #expect(body?["agentId"] as? String == agentId)

            let creatorAccepted = try await post(creatorToken, UUID().uuidString.lowercased(), body: "{}")
            #expect(creatorAccepted.status == .accepted)

            let malformed = try await post(ownerToken, UUID().uuidString.lowercased(), body: "{\"reportGeneratedAt\":\"not-a-timestamp\"}")
            #expect(malformed.status == .badRequest)

            let nonUUID = try await post(ownerToken, "report-1", body: "{}")
            #expect(nonUUID.status == .notFound)
            let encodedTraversal = try await post(ownerToken, "..%2Fx", body: "{}")
            #expect(encodedTraversal.status == .notFound)

            let forbidden = try await post(extraToken, UUID().uuidString.lowercased(), body: "{}")
            #expect(forbidden.status == .forbidden)
        }
    }
}
