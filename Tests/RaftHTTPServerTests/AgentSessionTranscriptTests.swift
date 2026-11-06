import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func agentSessionTranscriptRequiresMachineAssignmentAndOnlineMachine() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111669"
    let memberId = "11111111-1111-4111-8111-111111111670"
    let serverId = "33333333-3333-4333-8333-333333333689"
    for (id, email) in [
        (ownerId, "transcript-owner@slock.test"),
        (memberId, "transcript-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "transcript", name: "Transcript", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "transcript-machine")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "transcript-agent")
    accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)

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
            func transcript(_ bearer: String?, _ machineId: String = machine, _ agentId: String? = nil) async throws -> ClientResponse {
                let agentId = agentId ?? agent
                var headers = HTTPFields()
                if let bearer { headers[.authorization] = "Bearer \(bearer)" }
                return try await client.get("/api/servers/\(serverId)/machines/\(machineId)/agents/\(agentId)/diagnostic/session-transcript", headers: headers)
            }
            let owner = try await token("transcript-owner@slock.test")
            let member = try await token("transcript-member@slock.test")

            #expect(try await transcript(owner).status == .conflict)
            accounts.setMachineOnline(machineId: machine, online: true)
            #expect(try await transcript(member).status == .forbidden)
            let response = try await transcript(owner)
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["sessionId"] is NSNull)
            #expect((body?["transcript"] as? [Any])?.isEmpty == true)

            let otherMachine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "other-transcript-machine")
            #expect(try await transcript(owner, otherMachine).status == .badRequest)
            #expect(try await transcript(owner, machine, "missing-agent").status == .notFound)
            accounts.oauth.addMember(serverId: serverId, userId: "11111111-1111-4111-8111-111111111699", role: "member")
            #expect(try await transcript(nil).status == .unauthorized)
        }
    }
}
