import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Byte-exact bodies for the migrated execute surface. Each expectation is the
/// legacy hand-built JSON string, so a key reorder or a stray space fails here
/// even when the parsed JSON still matches.
private struct ExecuteByteFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let agentId: String
    let agentKey: String
    let channelId: String
}

private func makeExecuteByteFixture(_ suffix: String) -> ExecuteByteFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001150\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001150\(suffix)"
    accounts.addAccount(id: ownerId, email: "execute-bytes-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "execute-bytes-\(suffix)", name: "Execute \(suffix)", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(
        serverId: serverId,
        name: "ByteBot\(suffix)",
        creatorUserId: ownerId,
        runtime: "claude"
    )
    let channelId = accounts.oauth.createChannel(
        serverId: serverId,
        name: "bytes-\(suffix)",
        creatorUserId: ownerId,
        type: "channel"
    )
    accounts.seedPostableChannelForTesting(
        serverId: serverId,
        channelId: channelId,
        name: "bytes-\(suffix)",
        humanIds: [ownerId],
        agentIds: [agentId]
    )
    return ExecuteByteFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        agentId: agentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read", "tasks"], name: "bytes-\(suffix)"),
        channelId: channelId
    )
}

private func executeAgentHeaders(_ key: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return headers
}

private func executePost(
    _ client: any Client,
    key: String,
    path: String,
    body: String
) async throws -> ClientResponse {
    try await client.send(.post, headers: executeAgentHeaders(key), to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

@Test func taskListBodyKeepsTheLegacyMemberOrder() async throws {
    let f = makeExecuteByteFixture("001")
    let first = f.accounts.addTaskWithDescriptionForTesting(channelId: f.channelId, title: "first", description: "one")
    let second = f.accounts.addTaskWithDescriptionForTesting(channelId: f.channelId, title: "second", description: "two")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let encoded = ("#bytes-001").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let response = try await client.get(
                URI(string: "/internal/agent-api/tasks?channel=\(encoded)"),
                headers: executeAgentHeaders(f.agentKey)
            )
            #expect(response.status == .ok)
            let expected = "{\"tasks\":["
                + "{\"id\":\"\(first)\",\"channelId\":\"\(f.channelId)\",\"title\":\"first\",\"status\":\"todo\",\"taskNumber\":1},"
                + "{\"id\":\"\(second)\",\"channelId\":\"\(f.channelId)\",\"title\":\"second\",\"status\":\"todo\",\"taskNumber\":2}"
                + "]}"
            #expect(response.body.string == expected)
        }
    }
}

@Test func taskClaimFailureBodyKeepsTheLegacyMemberOrder() async throws {
    let f = makeExecuteByteFixture("002")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let response = try await executePost(
                client,
                key: f.agentKey,
                path: "/internal/agent-api/tasks/claim",
                body: "{\"channel\":\"#bytes-002\",\"task_numbers\":[9],\"message_ids\":[\"deadbeef\"]}"
            )
            #expect(response.status == .ok)
            #expect(
                response.body.string
                    == "{\"results\":[{\"taskNumber\":9,\"success\":false,\"reason\":\"not found\"},{\"messageId\":\"deadbeef\",\"success\":false,\"reason\":\"not found\"}]}"
            )
        }
    }
}

@Test func taskClaimSuccessBodyKeepsTheLegacyMemberOrder() async throws {
    let f = makeExecuteByteFixture("003")
    let taskId = f.accounts.addTaskWithDescriptionForTesting(channelId: f.channelId, title: "claim me", description: "body")
    let messageId = try #require(f.accounts.taskMessageIdForTesting(taskId: taskId))
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let response = try await executePost(
                client,
                key: f.agentKey,
                path: "/internal/agent-api/tasks/claim",
                body: "{\"channel\":\"#bytes-003\",\"task_numbers\":[1]}"
            )
            #expect(response.status == .ok)
            #expect(
                response.body.string
                    == "{\"results\":[{\"taskNumber\":1,\"messageId\":\"\(messageId)\",\"success\":true}]}"
            )
        }
    }
}

@Test func taskStatusUpdateBodyKeepsTheLegacyMemberOrder() async throws {
    let f = makeExecuteByteFixture("004")
    let taskId = f.accounts.addTaskWithDescriptionForTesting(channelId: f.channelId, title: "finish me", description: "body")
    let messageId = try #require(f.accounts.taskMessageIdForTesting(taskId: taskId))
    f.accounts.oauth.setAgentRole(serverId: f.serverId, agentId: f.agentId, role: "admin")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let response = try await executePost(
                client,
                key: f.agentKey,
                path: "/internal/agent-api/tasks/update-status",
                body: "{\"channel\":\"#bytes-004\",\"task_number\":1,\"status\":\"done\"}"
            )
            #expect(response.status == .ok)
            let expected = "{\"id\":\"\(taskId)\",\"channelId\":\"\(f.channelId)\","
                + "\"messageId\":\"\(messageId)\",\"title\":\"finish me\",\"status\":\"done\","
                + "\"taskNumber\":1,\"claimedById\":null,\"claimedByType\":null,"
                + "\"claimedAt\":null,\"revision\":1}"
            #expect(response.body.string == expected)
        }
    }
}

@Test func sendErrorsAndReconcileBodiesAreByteExact() async throws {
    let f = makeExecuteByteFixture("005")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let noContent = try await executePost(
                client,
                key: f.agentKey,
                path: "/internal/agent-api/send",
                body: "{\"target\":\"#bytes-005\"}"
            )
            #expect(noContent.status == .badRequest)
            #expect(noContent.body.string == "{\"error\":\"Content is required\"}")

            let reminders = try await executePost(
                client,
                key: f.agentKey,
                path: "/internal/agent-api/send",
                body: "{\"target\":\"dm:@reminders\",\"content\":\"x\"}"
            )
            #expect(reminders.status == .forbidden)
            #expect(
                reminders.body.string
                    == "{\"error\":\"dm:@reminders is your private reminder conversation; nobody else reads it. Act at the reminder's anchor instead.\",\"code\":\"DM_TARGET_NOT_SENDABLE\"}"
            )

            let reconcile = try await executePost(
                client,
                key: f.agentKey,
                path: "/internal/agent-api/v2/send",
                body: "{\"target\":\"#bytes-005\",\"content\":\"x\",\"idempotencyKey\":\"byte-key\",\"reconcileOnly\":true}"
            )
            #expect(reconcile.status == .ok)
            #expect(
                reconcile.body.string
                    == "{\"ok\":true,\"state\":\"not_found\",\"reconciliation\":true}"
            )
        }
    }
}

@Test func withheldSendBodyIsByteExact() async throws {
    let f = makeExecuteByteFixture("006")
    _ = f.accounts.addHumanMessageForTesting(
        channelId: f.channelId,
        senderId: f.ownerId,
        content: "newer than the agent boundary"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let withheld = try await executePost(
                client,
                key: f.agentKey,
                path: "/internal/agent-api/v2/send",
                body: "{\"target\":\"#bytes-006\",\"content\":\"draft\",\"seenUpToSeq\":0,\"freshnessContextMode\":\"withheld\"}"
            )
            #expect(withheld.status == .ok)
            #expect(
                withheld.body.string
                    == "{\"state\":\"held\",\"freshnessContextMode\":\"withheld\",\"withheldMessageCount\":1}"
            )
        }
    }
}
