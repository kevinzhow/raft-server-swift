import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The published `agent_api_contract_invalid` bytes for the contract routes
/// mounted after the shared validator landed (`taskHistory`, `taskUnclaim`, the
/// direct upload sessions and the integration-app management verbs).
///
/// Pinned `routes/internalAgentApi.ts` registers every one of them through
/// `registerAgentApiRoute(routeKey, ...agentApiRequestValidators(routeKey))`,
/// so the same zod schemas and the same 400 body apply. The companion case
/// locks the middleware order: `requireAgentCapability` -> `requireAgentGrant`
/// -> request validators, so a bound agent without the operation grant answers
/// the 403 before any schema issue.
private struct AgentApiContractCoverageFixture {
    let accounts: EmailLoginDirectory
    let ownerId: String
    let serverId: String
    let agentId: String
    let channelId: String
    let key: String
}

private func makeAgentApiContractCoverageFixture() -> AgentApiContractCoverageFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001029001"
    let serverId = "33333333-3333-4333-8333-000001029001"
    accounts.addAccount(id: ownerId, email: "agent-contract-coverage@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-contract", name: "Agent Contract", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "contract-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "contract-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "ContractCoverageBot", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let key = accounts.mintAgentCredential(
        agentId: agent,
        scopes: ["read", "send", "tasks", "channels", "reactions", "mentions", "mcp", "server"],
        name: "contract-coverage"
    )
    return AgentApiContractCoverageFixture(
        accounts: accounts,
        ownerId: ownerId,
        serverId: serverId,
        agentId: agent,
        channelId: channel,
        key: key
    )
}

@Test func agentApiContractNewlyMountedRoutesPublishPinnedIssues() async throws {
    let fixture = makeAgentApiContractCoverageFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.key)"
            headers[.contentType] = "application/json"

            func send(
                _ method: HTTPRequest.Method,
                _ path: String,
                _ body: String? = nil
            ) async throws -> ClientResponse {
                try await client.send(method, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
            }

            func expectIssue(
                _ method: HTTPRequest.Method,
                _ path: String,
                body: String? = nil,
                key: String,
                part: String,
                issues: String,
                sourceLocation: SourceLocation = #_sourceLocation
            ) async throws {
                let response = try await send(method, path, body)
                let expected = #"{"error":"Invalid agent-api \#(key) \#(part)","code":"agent_api_contract_invalid","issues":\#(issues)}"#
                #expect(response.status == .badRequest, "\(method) \(path)", sourceLocation: sourceLocation)
                #expect(response.body.string == expected, "\(method) \(path)", sourceLocation: sourceLocation)
            }

            // taskHistory: trimmed required channel, then the coerced number.
            try await expectIssue(
                .get,
                "/internal/agent-api/tasks/history",
                key: "taskHistory",
                part: "query",
                issues: #"[{"path":"channel","message":"Invalid input: expected string, received undefined"},{"path":"task_number","message":"Invalid input: expected number, received NaN"}]"#
            )
            try await expectIssue(
                .get,
                "/internal/agent-api/tasks/history?channel=%20&task_number=abc",
                key: "taskHistory",
                part: "query",
                issues: #"[{"path":"channel","message":"Too small: expected string to have >=1 characters"},{"path":"task_number","message":"Invalid input: expected number, received NaN"}]"#
            )

            // taskUnclaim: both required members, in shape order.
            try await expectIssue(
                .post,
                "/internal/agent-api/tasks/unclaim",
                body: "{}",
                key: "taskUnclaim",
                part: "body",
                issues: #"[{"path":"channel","message":"Invalid input: expected string, received undefined"},{"path":"task_number","message":"Invalid input: expected number, received undefined"}]"#
            )

            // The direct upload session create body is a strict object.
            try await expectIssue(
                .post,
                "/internal/agent-api/attachment-upload-sessions",
                body: #"{"channelId":"not-a-uuid"}"#,
                key: "attachmentUploadSessionCreate",
                part: "body",
                issues: #"[{"path":"channelId","message":"Invalid UUID"},{"path":"filename","message":"Invalid input: expected string, received undefined"},{"path":"mimeType","message":"Invalid input: expected string, received undefined"},{"path":"sizeBytes","message":"Invalid input: expected number, received undefined"},{"path":"clientRequestId","message":"Invalid input: expected string, received undefined"}]"#
            )
            let uploadId = UUID().uuidString.lowercased()
            let clientRequestId = UUID().uuidString.lowercased()
            try await expectIssue(
                .post,
                "/internal/agent-api/attachment-upload-sessions",
                body: #"{"channelId":"\#(uploadId)","filename":"f","mimeType":"text/plain","sizeBytes":1,"clientRequestId":"\#(clientRequestId)","extra":1}"#,
                key: "attachmentUploadSessionCreate",
                part: "body",
                issues: #"[{"path":"","message":"Unrecognized key: \"extra\""}]"#
            )

            // The three upload session verbs validate the strict uploadId param.
            try await expectIssue(
                .post,
                "/internal/agent-api/attachment-upload-sessions/not-a-uuid/complete",
                key: "attachmentUploadSessionComplete",
                part: "params",
                issues: #"[{"path":"uploadId","message":"Invalid UUID"}]"#
            )
            try await expectIssue(
                .delete,
                "/internal/agent-api/attachment-upload-sessions/not-a-uuid",
                key: "attachmentUploadSessionCancel",
                part: "params",
                issues: #"[{"path":"uploadId","message":"Invalid UUID"}]"#
            )
            try await expectIssue(
                .get,
                "/internal/agent-api/attachment-upload-sessions/not-a-uuid",
                key: "attachmentUploadSessionStatus",
                part: "params",
                issues: #"[{"path":"uploadId","message":"Invalid UUID"}]"#
            )

            // Integration-app management verbs use their passthrough bodies.
            try await expectIssue(
                .post,
                "/internal/agent-api/integrations/app/rotate-secret",
                body: "{}",
                key: "integrationAppRotateSecret",
                part: "body",
                issues: #"[{"path":"clientKey","message":"Invalid input: expected string, received undefined"}]"#
            )
            try await expectIssue(
                .post,
                "/internal/agent-api/integrations/app/transfer-owner",
                body: #"{"clientKey":""}"#,
                key: "integrationAppTransferOwner",
                part: "body",
                issues: #"[{"path":"clientKey","message":"Too small: expected string to have >=1 characters"},{"path":"targetAgent","message":"Invalid input: expected string, received undefined"}]"#
            )
            try await expectIssue(
                .post,
                "/internal/agent-api/integrations/app/manage",
                body: #"{"clientKey":"k","action":"nope"}"#,
                key: "integrationAppManage",
                part: "body",
                issues: #"[{"path":"action","message":"Invalid option: expected one of \"share_link_get\"|\"share_link_create\"|\"share_link_revoke\"|\"request_publish\"|\"request_unpublish\"|\"clear_logo\"|\"delete\""}]"#
            )
        }
    }
}

@Test func agentApiContractGrantCheckPrecedesSchemaValidation() async throws {
    let fixture = makeAgentApiContractCoverageFixture()
    // A saved custom grant set that lacks the operation grants under test.
    fixture.accounts.setAgentGrantsForTesting(agentId: fixture.agentId, scopes: ["task:read"])
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.key)"
            headers[.contentType] = "application/json"

            func send(
                _ method: HTTPRequest.Method,
                _ path: String,
                _ body: String? = nil
            ) async throws -> ClientResponse {
                try await client.send(method, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
            }
            let missingScope = { (scope: String) in
                #"{"error":"missing required scope","requiredScope":"\#(scope)","reason":"missing_scope"}"#
            }

            // `historyRead` requires `message:read`; an invalid query must not
            // preempt the grant middleware.
            let history = try await send(.get, "/internal/agent-api/history")
            #expect(history.status == .forbidden)
            #expect(history.body.string == missingScope("message:read"))

            // `messageSend` requires `message:send`.
            let sendMessage = try await send(
                .post, "/internal/agent-api/send", #"{"attachmentIds":[1]}"#
            )
            #expect(sendMessage.status == .forbidden)
            #expect(sendMessage.body.string == missingScope("message:send"))

            // `taskUnclaim` requires `task:write`; the grant wins over the body.
            let unclaim = try await send(.post, "/internal/agent-api/tasks/unclaim", "{}")
            #expect(unclaim.status == .forbidden)
            #expect(unclaim.body.string == missingScope("task:write"))

            // A route without a per-agent grant still publishes schema issues
            // for the same custom grant set.
            let rotate = try await send(
                .post, "/internal/agent-api/integrations/app/rotate-secret", "{}"
            )
            #expect(rotate.status == .badRequest)
            #expect(rotate.body.string == #"{"error":"Invalid agent-api integrationAppRotateSecret body","code":"agent_api_contract_invalid","issues":[{"path":"clientKey","message":"Invalid input: expected string, received undefined"}]}"#)

            // Reset to the default (every grantable scope): the same invalid
            // request reaches the request validator.
            fixture.accounts.resetAgentGrantsForTesting(agentId: fixture.agentId)
            let grantedHistory = try await send(.get, "/internal/agent-api/history")
            #expect(grantedHistory.status == .badRequest)
            #expect(grantedHistory.body.string == #"{"error":"Invalid agent-api historyRead query","code":"agent_api_contract_invalid","issues":[{"path":"channel","message":"Invalid input: expected string, received undefined"}]}"#)
        }
    }
}
