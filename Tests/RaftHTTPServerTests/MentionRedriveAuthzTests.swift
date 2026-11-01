import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func mentionRedriveRequiresAgentInspectionRightsAndAValidVersion() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111667"
    let memberId = "11111111-1111-4111-8111-111111111668"
    let serverId = "33333333-3333-4333-8333-333333333688"
    for (id, email) in [
        (ownerId, "redrive-owner@slock.test"),
        (memberId, "redrive-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "redrive", name: "Redrive", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "redrive-machine")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "redrive-agent")
    accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)
    let messageId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func token(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func redrive(_ bearer: String, message: String? = nil, agentId: String? = nil, body: String = "{\"expectedVersion\":0}") async throws -> ClientResponse {
                let message = message ?? messageId
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[.contentType] = "application/json"
                let target = agentId ?? agent
                return try await client.send(.post, headers: headers, to: "/api/servers/\(serverId)/machines/\(machine)/agents/\(target)/diagnostic/mention-delivery/\(message)/redrive") { request in
                    request.body = .init(string: body)
                }
            }
            func diagnostic(_ bearer: String, message: String? = nil, agentId: String? = nil) async throws -> ClientResponse {
                let message = message ?? messageId
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                let target = agentId ?? agent
                return try await client.get("/api/servers/\(serverId)/machines/\(machine)/agents/\(target)/diagnostic/mention-delivery/\(message)", headers: headers)
            }
            let owner = try await token("redrive-owner@slock.test")
            let member = try await token("redrive-member@slock.test")

            let refused = try await redrive(member)
            #expect(refused.status == .notFound)
            #expect((try JSONSerialization.jsonObject(with: Data((refused.body.string ?? "").utf8)) as? [String: Any])?["status"] as? String == "NOT_ACCESSIBLE")

            let allowed = try await redrive(owner)
            #expect(allowed.status == .notFound)
            #expect((try JSONSerialization.jsonObject(with: Data((allowed.body.string ?? "").utf8)) as? [String: Any])?["status"] as? String == "NOT_JOINABLE")

            let malformedId = try await redrive(owner, message: "not-a-uuid")
            #expect(malformedId.status == .notFound)
            #expect((try JSONSerialization.jsonObject(with: Data((malformedId.body.string ?? "").utf8)) as? [String: Any])?["status"] as? String == "NOT_JOINABLE")

            let invalidBody = try await redrive(owner, body: "{\"expectedVersion\":-1}")
            #expect(invalidBody.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((invalidBody.body.string ?? "").utf8)) as? [String: Any])?["status"] as? String == "INVALID_REQUEST")

            let unassigned = accounts.oauth.createAgent(serverId: serverId, name: "unassigned")
            accounts.setAgentMachineForTesting(agentId: unassigned, machineId: "other-machine")
            let mismatch = try await redrive(owner, agentId: unassigned)
            #expect(mismatch.status == .notFound)
            #expect((try JSONSerialization.jsonObject(with: Data((mismatch.body.string ?? "").utf8)) as? [String: Any])?["status"] as? String == "NOT_ACCESSIBLE")

            let diagnosticRefused = try await diagnostic(member)
            #expect(diagnosticRefused.status == .notFound)
            #expect((try JSONSerialization.jsonObject(with: Data((diagnosticRefused.body.string ?? "").utf8)) as? [String: Any])?["status"] as? String == "NOT_ACCESSIBLE")
            let diagnosticAllowed = try await diagnostic(owner)
            #expect(diagnosticAllowed.status == .notFound)
            #expect((try JSONSerialization.jsonObject(with: Data((diagnosticAllowed.body.string ?? "").utf8)) as? [String: Any])?["status"] as? String == "NOT_JOINABLE")
            let diagnosticBadId = try await diagnostic(owner, message: "not-a-uuid")
            #expect(diagnosticBadId.status == .notFound)
            #expect((try JSONSerialization.jsonObject(with: Data((diagnosticBadId.body.string ?? "").utf8)) as? [String: Any])?["status"] as? String == "NOT_JOINABLE")
            let diagnosticMismatch = try await diagnostic(owner, agentId: unassigned)
            #expect(diagnosticMismatch.status == .notFound)
            #expect((try JSONSerialization.jsonObject(with: Data((diagnosticMismatch.body.string ?? "").utf8)) as? [String: Any])?["status"] as? String == "NOT_ACCESSIBLE")
        }
    }
}
