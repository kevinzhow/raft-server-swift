import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The legacy machine surface: `GET /internal/agent/:id/{knowledge,messages/:mid/resolve,receive,tasks}`
/// and `POST /internal/agent/:id/server/avatar` at raft-source
/// v1.21.23-source.1 (`routes/internal.ts`).
@Test func legacyAgentMachineRoutesAuthenticateBeforeAnswering() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001031001"
    let ownerId = "11111111-1111-4111-8111-000001031001"
    accounts.addAccount(id: ownerId, email: "legacy-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "legacy-agent", name: "Legacy Agent", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "legacy-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "legacy-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "LegacyBot", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: agent, name: "legacy-room")
    accounts.oauth.setAgentRole(serverId: serverId, agentId: agent, role: "owner")
    let messageId = accounts.addChannelMessageForTesting(
        channelId: channel, content: "resolve me", senderId: ownerId
    )
    accounts.addTaskForTesting(
        channelId: channel, title: "legacy task", messageId: messageId,
        assigneeType: nil, assigneeId: nil
    )
    let machineKey = accounts.registerMachineForAgent(serverId: serverId, agentId: agent)

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
            headers[.authorization] = "Bearer \(machineKey)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Raft-Client")!] = "cli"

            let knowledge = try await client.send(
                .get, headers: headers, to: URI(string: "/internal/agent/\(agent)/knowledge?topic=slock-home")
            )
            #expect(knowledge.status == .ok)

            let resolve = try await client.send(
                .get, headers: headers, to: "/internal/agent/\(agent)/messages/\(messageId)/resolve"
            )
            #expect(resolve.status == .ok)
            let resolved = try #require(object(resolve)["message"] as? [String: Any])
            #expect(resolved["message_id"] as? String == messageId)
            #expect(resolved["content"] as? String == "resolve me")
            #expect(resolved["sender_type"] as? String == "human")

            let receive = try await client.send(
                .get, headers: headers, to: "/internal/agent/\(agent)/receive?block=false"
            )
            #expect(receive.status == .ok)
            #expect((object(receive)["messages"] as? [Any])?.isEmpty == true)

            let tasks = try await client.send(
                .get, headers: headers,
                to: URI(string: "/internal/agent/\(agent)/tasks?channel=%23legacy-room")
            )
            #expect(tasks.status == .ok)
            let rows = try #require(object(tasks)["tasks"] as? [[String: Any]])
            #expect(rows.count == 1)
            #expect(rows[0]["title"] as? String == "legacy task")
            #expect(rows[0]["readOnlyReason"] is NSNull)
            #expect(rows[0]["channelName"] as? String == "legacy-room")

            let missingChannel = try await client.send(
                .get, headers: headers, to: "/internal/agent/\(agent)/tasks"
            )
            #expect(missingChannel.status == .badRequest)
            #expect(object(missingChannel)["error"] as? String == "channel query param is required (e.g. #general)")

            let badStatus = try await client.send(
                .get, headers: headers,
                to: URI(string: "/internal/agent/\(agent)/tasks?channel=%23legacy-room&status=nope")
            )
            #expect(badStatus.status == .badRequest)
            #expect(object(badStatus)["error"] as? String == "Invalid status value")

            let avatarForm = MultipartTestBody(
                filename: "server.png", mimeType: "image/png",
                bytes: Data([0x89, 0x50, 0x4E, 0x47])
            )
            var avatarHeaders = headers
            avatarHeaders[.contentType] = avatarForm.contentType
            let avatar = try await client.send(
                .post, headers: avatarHeaders, to: "/internal/agent/\(agent)/server/avatar"
            ) { request in
                request.body = .init(data: avatarForm.body)
            }
            #expect(avatar.status == .ok)
            #expect(object(avatar)["id"] as? String == serverId)

            // Missing machine auth is the middleware 401 before any lookup.
            var anonymous = HTTPFields()
            anonymous[.contentType] = "application/json"
            let missingAuth = try await client.send(
                .get, headers: anonymous, to: "/internal/agent/\(agent)/receive"
            )
            #expect(missingAuth.status == .unauthorized)
            #expect(object(missingAuth)["error"] as? String == "Missing machine API key")

            // The machine key is bound to one agent only.
            let otherAgent = accounts.oauth.createAgent(serverId: serverId, name: "OtherBot", runtime: "codex")
            let notAssigned = try await client.send(
                .get, headers: headers, to: "/internal/agent/\(otherAgent)/receive"
            )
            #expect(notAssigned.status == .forbidden)
            #expect(object(notAssigned)["error"] as? String == "This agent is not assigned to your machine")

            // A missing agent id is 404 Agent not found.
            let missingAgent = try await client.send(
                .get, headers: headers,
                to: "/internal/agent/\(UUID().uuidString.lowercased())/receive"
            )
            #expect(missingAgent.status == .notFound)
            #expect(object(missingAgent)["error"] as? String == "Agent not found")
        }
    }
}
