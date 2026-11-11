import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The credential-surface task history and unclaim reads/writes:
/// `GET /internal/agent-api/tasks/history` and
/// `POST /internal/agent-api/tasks/unclaim` at raft-source
/// v1.21.23-source.1 (`routes/internalAgentApi.ts`).
@Test func agentApiTaskHistoryAndUnclaimLockThePublishedContract() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001027001"
    let ownerId = "11111111-1111-4111-8111-000001027001"
    accounts.addAccount(id: ownerId, email: "agent-history-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-history", name: "Agent History", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "history-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "history-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "HistoryBot", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send", "tasks"], name: "tasks")
    let readonlyKey = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send"], name: "no-tasks")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func object(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            let channelRef = "#history-room"

            // A canonical task (host message + task_events) is required for history.
            let created = try await client.send(
                .post, headers: headers, to: "/internal/agent-api/tasks"
            ) { request in
                request.body = .init(string: "{\"channel\":\"\(channelRef)\",\"tasks\":[{\"title\":\"history task\"}]}")
            }
            #expect(created.status == .ok)
            let createdTasks = object(created)["tasks"] as? [[String: Any]] ?? []
            let taskNumber = try #require(createdTasks.first?["taskNumber"] as? Int)

            let history = try await client.send(
                .get, headers: headers,
                to: URI(string: "/internal/agent-api/tasks/history?channel=\(channelRef.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&task_number=\(taskNumber)")
            )
            #expect(history.status == .ok)
            let historyBody = object(history)
            let task = try #require(historyBody["task"] as? [String: Any])
            #expect(task["taskNumber"] as? Int == taskNumber)
            #expect(task["title"] as? String == "history task")
            #expect(task["revision"] as? Int == 0)
            let events = try #require(historyBody["events"] as? [[String: Any]])
            #expect(events.isEmpty == false)
            #expect(Set(events[0].keys) == ["id", "seq", "eventType", "actorType", "actorName", "payload", "createdAt"])
            #expect(events[0]["eventType"] as? String != nil)

            let missingQuery = try await client.send(
                .get, headers: headers, to: URI(string: "/internal/agent-api/tasks/history")
            )
            #expect(missingQuery.status == .badRequest)
            #expect(object(missingQuery)["code"] as? String == "agent_api_contract_invalid")

            let badTask = try await client.send(
                .get, headers: headers,
                to: URI(string: "/internal/agent-api/tasks/history?channel=%23history-room&task_number=0")
            )
            #expect(badTask.status == .badRequest)
            #expect(object(badTask)["code"] as? String == "agent_api_contract_invalid")

            let missingTask = try await client.send(
                .get, headers: headers,
                to: URI(string: "/internal/agent-api/tasks/history?channel=%23history-room&task_number=99")
            )
            #expect(missingTask.status == .notFound)
            #expect(object(missingTask)["error"] as? String == "Task not found")

            // Unclaim releases a claimed task and is member-level; a second
            // unclaim is the canonical "task is not assigned" 409.
            let claim = try await client.send(.post, headers: headers, to: "/internal/agent-api/tasks/claim") { request in
                request.body = .init(string: "{\"channel\":\"\(channelRef)\",\"task_numbers\":[\(taskNumber)]}")
            }
            #expect(claim.status == .ok)

            let unclaim = try await client.send(.post, headers: headers, to: "/internal/agent-api/tasks/unclaim") { request in
                request.body = .init(string: "{\"channel\":\"\(channelRef)\",\"task_number\":\(taskNumber)}")
            }
            #expect(unclaim.status == .ok)
            #expect(object(unclaim)["ok"] as? Bool == true)

            let secondUnclaim = try await client.send(.post, headers: headers, to: "/internal/agent-api/tasks/unclaim") { request in
                request.body = .init(string: "{\"channel\":\"\(channelRef)\",\"task_number\":\(taskNumber)}")
            }
            #expect(secondUnclaim.status == .conflict)
            #expect(object(secondUnclaim)["error"] as? String == "task is not assigned")

            let badUnclaim = try await client.send(.post, headers: headers, to: "/internal/agent-api/tasks/unclaim") { request in
                request.body = .init(string: "{\"channel\":\"\(channelRef)\"}")
            }
            #expect(badUnclaim.status == .badRequest)
            #expect(object(badUnclaim)["code"] as? String == "agent_api_contract_invalid")

            // The credential capability gates both routes before the body.
            var readonlyHeaders = HTTPFields()
            readonlyHeaders[.authorization] = "Bearer \(readonlyKey)"
            readonlyHeaders[.contentType] = "application/json"
            let denied = try await client.send(.get, headers: readonlyHeaders,
                to: URI(string: "/internal/agent-api/tasks/history?channel=%23history-room&task_number=1"))
            #expect(denied.status == .forbidden)
            #expect(object(denied)["code"] as? String == "capability_not_authorized")
            #expect(object(denied)["requiredCapability"] as? String == "tasks")

            // The grant gate is separate from the capability.
            accounts.setAgentGrantsForTesting(agentId: agent, scopes: ["task:read"])
            let missingGrant = try await client.send(.post, headers: headers, to: "/internal/agent-api/tasks/unclaim") { request in
                request.body = .init(string: "{\"channel\":\"\(channelRef)\",\"task_number\":\(taskNumber)}")
            }
            #expect(missingGrant.status == .forbidden)
            #expect(object(missingGrant)["error"] as? String == "missing required scope")
            #expect(object(missingGrant)["requiredScope"] as? String == "task:write")
        }
    }
}
