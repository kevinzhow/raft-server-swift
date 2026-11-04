import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func legacyMachineReminderCRUDAndAgentApiBoundIdentity() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001087001"
    let ownerId = "11111111-1111-4111-8111-000001087001"
    accounts.addAccount(id: ownerId, email: "reminders-owner@internal.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "internal-reminders", name: "Internal Reminders", ownerId: ownerId)
    let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "reminder-machine")
    let machineKey = try #require(accounts.machineAPIKey(machineId: machineId))
    let agentId = accounts.oauth.createAgent(
        serverId: serverId, name: "reminder-agent", creatorUserId: ownerId, runtime: "claude"
    )
    let agentKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "tasks"], name: "reminder-key")
    let externalAgent = accounts.oauth.createAgent(
        serverId: serverId, name: "external-reminder-agent", creatorUserId: ownerId, runtime: "external"
    )
    let externalKey = accounts.mintAgentCredential(agentId: externalAgent, scopes: ["read", "tasks"], name: "external-key")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var machineHeaders = HTTPFields()
            machineHeaders[.authorization] = "Bearer \(machineKey)"
            machineHeaders[.contentType] = "application/json"
            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(agentKey)"
            agentHeaders[.contentType] = "application/json"
            var externalHeaders = HTTPFields()
            externalHeaders[.authorization] = "Bearer \(externalKey)"
            externalHeaders[.contentType] = "application/json"

            let create = try await client.send(.post, headers: machineHeaders, to: URI(string: "/internal/agent/\(agentId)/reminders")) { request in
                request.body = .init(string: "{\"title\":\"Stand up\",\"msgId\":\"m-1\",\"delaySeconds\":600}")
            }
            #expect(create.status == .ok)
            let created = try JSONSerialization.jsonObject(with: Data((create.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let reminder = try #require(created["reminder"] as? [String: Any])
            let reminderId = try #require(reminder["id"] as? String)
            #expect(reminder["status"] as? String == "scheduled")
            #expect(reminder["version"] as? Int == 1)

            let list = try await client.get(URI(string: "/internal/agent/\(agentId)/reminders?status=scheduled"), headers: machineHeaders)
            #expect(list.status == .ok)
            let listed = try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect((listed["reminders"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == [reminderId])
            #expect((try await client.get(URI(string: "/internal/agent/\(agentId)/reminders?status=bogus"), headers: machineHeaders)).status == .badRequest)

            let cancel = try await client.send(.delete, headers: machineHeaders, to: URI(string: "/internal/agent/\(agentId)/reminders/\(reminderId)")) { request in
                request.body = .init(string: "{\"expectedVersion\":1}")
            }
            #expect(cancel.status == .ok)
            let canceled = try JSONSerialization.jsonObject(with: Data((cancel.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect((canceled["reminder"] as? [String: Any])?["status"] as? String == "canceled")
            let staleCancel = try await client.send(.delete, headers: machineHeaders, to: URI(string: "/internal/agent/\(agentId)/reminders/\(reminderId)")) { request in
                request.body = .init(string: "{\"expectedVersion\":1}")
            }
            #expect(staleCancel.status == .conflict)

            let agentCreate = try await client.send(.post, headers: agentHeaders, to: URI(string: "/internal/agent-api/reminders")) { request in
                request.body = .init(string: "{\"title\":\"Bound identity\",\"msgId\":\"m-2\",\"delaySeconds\":60}")
            }
            #expect(agentCreate.status == .ok)
            let agentList = try await client.get(URI(string: "/internal/agent-api/reminders?status=scheduled"), headers: agentHeaders)
            #expect(agentList.status == .ok)
            let agentListBody = try JSONSerialization.jsonObject(with: Data((agentList.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(((agentListBody["reminders"] as? [[String: Any]]) ?? []).count == 1)

            let externalCreate = try await client.send(.post, headers: externalHeaders, to: URI(string: "/internal/agent-api/reminders")) { request in
                request.body = .init(string: "{\"title\":\"Nope\",\"msgId\":\"m-3\",\"delaySeconds\":60}")
            }
            #expect(externalCreate.status == .conflict)
            #expect(externalCreate.body.string?.contains("reminders_unsupported_for_external_agents") == true)

            let missingMessage = try await client.send(.post, headers: agentHeaders, to: URI(string: "/internal/agent-api/reminders")) { request in
                request.body = .init(string: "{\"title\":\"No msgId\",\"delaySeconds\":60}")
            }
            #expect(missingMessage.status == .badRequest)
        }
    }
}
