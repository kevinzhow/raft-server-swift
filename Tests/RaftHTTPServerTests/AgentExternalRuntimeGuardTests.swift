import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func externalAgentRejectsManagedRuntimeLifecycleAndMachineAssignment() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001350901"
    let serverId = "33333333-3333-4333-8333-000001350901"
    accounts.addAccount(id: ownerId, email: "external-lifecycle-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "external-lifecycle", name: "External Lifecycle Server", ownerId: ownerId)
    let ownerToken = accounts.mintAccessTokenForTesting(userId: ownerId)

    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(ownerToken)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let create = try await client.send(.post, headers: headers, to: "/api/agents") { request in
                request.body = .init(string: #"{"name":"external-lifecycle-agent","external":true}"#)
            }
            #expect(create.status == .ok)
            let created = try #require((try JSONSerialization.jsonObject(with: Data((create.body.string ?? "").utf8))) as? [String: Any])
            let agentId = try #require(created["id"] as? String)

            // Profile fields still update on an external agent.
            let profilePatch = try await client.send(.patch, headers: headers, to: "/api/agents/\(agentId)") { request in
                request.body = .init(string: #"{"description":"external profile updates still work"}"#)
            }
            #expect(profilePatch.status == .ok)
            let profileBody = try #require((try JSONSerialization.jsonObject(with: Data((profilePatch.body.string ?? "").utf8))) as? [String: Any])
            #expect(profileBody["description"] as? String == "external profile updates still work")

            let runtimePatch = try await client.send(.patch, headers: headers, to: "/api/agents/\(agentId)") { request in
                request.body = .init(string: #"{"runtime":"codex"}"#)
            }
            #expect(runtimePatch.status == .badRequest)
            let runtimeBody = try #require((try JSONSerialization.jsonObject(with: Data((runtimePatch.body.string ?? "").utf8))) as? [String: Any])
            #expect(runtimeBody["error"] as? String == "External agent runtime fields are immutable")

            for action in ["start", "stop", "reset"] {
                let response = try await client.send(.post, headers: headers, to: "/api/agents/\(agentId)/\(action)") { request in
                    request.body = .init(string: #"{"mode":"session"}"#)
                }
                #expect(response.status == .badRequest, "\(action) is not a Raft-managed verb for external agents")
                let body = try #require((try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any])
                #expect(body["error"] as? String == "External agents do not use Raft-managed runtime lifecycle")
            }

            let assign = try await client.send(.post, headers: headers, to: "/api/agents/\(agentId)/assign-machine") { request in
                request.body = .init(string: #"{"machineId":"machine-external-lifecycle"}"#)
            }
            #expect(assign.status == .badRequest)
            let assignBody = try #require((try JSONSerialization.jsonObject(with: Data((assign.body.string ?? "").utf8))) as? [String: Any])
            #expect(assignBody["error"] as? String == "External agents cannot be assigned to a Computer")

            let delete = try await client.send(.delete, headers: headers, to: "/api/agents/\(agentId)")
            #expect(delete.status == .ok)
            let gone = try await client.get(URI(string: "/api/agents/\(agentId)"), headers: headers)
            #expect(gone.status == .notFound, "the external agent is soft-deleted")

            let archived = try await client.get(URI(string: "/api/agents/archived"), headers: headers)
            #expect(archived.status == .ok)
            let archivedBody = (try JSONSerialization.jsonObject(with: Data((archived.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let archivedRows = archivedBody["agents"] as? [[String: Any]] ?? []
            #expect(archivedRows.contains { ($0["agentId"] as? String) == agentId })
        }
    }
}
