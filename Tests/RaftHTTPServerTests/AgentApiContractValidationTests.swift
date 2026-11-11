import Foundation
import HTTPTypes
import RaftHTTP
import RaftShared
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The published `agent_api_contract_invalid` bytes for the credential route
/// surface.
///
/// Pinned `packages/server/src/routes/internalAgentApi.ts:402-431` parses the
/// same `agentApiContract` schemas the Swift port now validates with and
/// prints `{"error":"Invalid agent-api <key> <part>","code":…,"issues":[…]}`.
/// These assertions are the bytes a client sees, not a DTO shape.
@Test func agentApiContractRoutesPublishPinnedIssues() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111660"
    let serverId = "33333333-3333-4333-8333-333333333690"
    accounts.addAccount(id: ownerId, email: "contract-owner@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "contract", name: "Contract", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(
        serverId: serverId,
        name: "ContractBot",
        creatorUserId: ownerId,
        runtime: "claude"
    )
    let key = accounts.mintAgentCredential(
        agentId: agentId,
        scopes: ["read", "send", "tasks", "channels", "server", "mentions", "reactions", "mcp"],
        name: "contract"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func call(
                _ method: HTTPRequest.Method,
                _ path: String,
                _ body: String? = nil
            ) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                return try await client.send(method, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
            }
            func expect(
                _ method: HTTPRequest.Method,
                _ path: String,
                body: String? = nil,
                key: String,
                part: String,
                issues: String,
                sourceLocation: SourceLocation = #_sourceLocation
            ) async throws {
                let response = try await call(method, path, body)
                let expected = #"{"error":"Invalid agent-api \#(key) \#(part)","code":"agent_api_contract_invalid","issues":\#(issues)}"#
                #expect(response.status == .badRequest, "\(method) \(path)", sourceLocation: sourceLocation)
                #expect(response.body.string == expected, "\(method) \(path)", sourceLocation: sourceLocation)
            }

            // Non-object body root: `req.body ?? {}` only substitutes null.
            try await expect(.post, "/internal/agent-api/channels", body: "[]", key: "channelCreate", part: "body", issues: #"[{"path":"","message":"Invalid input: expected object, received array"}]"#)

            // Missing required member and per-member shape order.
            try await expect(.post, "/internal/agent-api/channels", body: "{}", key: "channelCreate", part: "body", issues: #"[{"path":"name","message":"Invalid input: expected string, received undefined"}]"#)
            try await expect(
                .post,
                "/internal/agent-api/channels",
                body: #"{"name":"  ","description":5,"visibility":"team"}"#,
                key: "channelCreate",
                part: "body",
                issues: #"[{"path":"name","message":"Too small: expected string to have >=1 characters"},{"path":"description","message":"Invalid input: expected string, received number"},{"path":"visibility","message":"Invalid option: expected one of \"public\"|\"private\""}]"#
            )

            // Array element paths, trimmed min, and a later boolean member.
            try await expect(
                .post,
                "/internal/agent-api/send",
                body: #"{"attachmentIds":[1,"","ok"],"reconcileOnly":"yes"}"#,
                key: "messageSend",
                part: "body",
                issues: #"[{"path":"attachmentIds.0","message":"Invalid input: expected string, received number"},{"path":"attachmentIds.1","message":"Too small: expected string to have >=1 characters"},{"path":"reconcileOnly","message":"Invalid input: expected boolean, received string"}]"#
            )

            // V2 mentions: enum, UUID, and trimmed name.
            try await expect(
                .post,
                "/internal/agent-api/v2/send",
                body: #"{"mentions":[{"type":"bot","id":"nope","name":""}]}"#,
                key: "messageSendV2",
                part: "body",
                issues: #"[{"path":"mentions.0.type","message":"Invalid option: expected one of \"user\"|\"agent\""},{"path":"mentions.0.id","message":"Invalid UUID"},{"path":"mentions.0.name","message":"Too small: expected string to have >=1 characters"}]"#
            )

            // Int/positive wording and enum wording on a task body.
            try await expect(
                .post,
                "/internal/agent-api/tasks/update-status",
                body: ##"{"channel":"c","task_number":1.5,"status":"blocked"}"##,
                key: "taskUpdateStatus",
                part: "body",
                issues: #"[{"path":"task_number","message":"Invalid input: expected int, received number"},{"path":"status","message":"Invalid option: expected one of \"todo\"|\"in_progress\"|\"in_review\"|\"done\"|\"closed\""}]"#
            )

            // Nested object path, ISO datetime, and the @handle refine.
            try await expect(
                .post,
                "/internal/agent-api/tasks/resource-receipt",
                body: ##"{"channel":"c","task_number":1,"receipt":{"object":"o","purpose":"p","teardown_owner":"nope","security_privacy":"s","expiry":"tomorrow","runbook":"r","tracking":"t"}}"##,
                key: "taskResourceReceipt",
                part: "body",
                issues: #"[{"path":"receipt.teardown_owner","message":"teardown_owner must be an @agent handle"},{"path":"receipt.expiry","message":"Invalid ISO datetime"}]"#
            )

            // Strict body: member issue first, then the root unknown-key issue.
            try await expect(
                .post,
                "/internal/agent-api/integrations/token",
                body: #"{"service":"A","extra":1}"#,
                key: "integrationToken",
                part: "body",
                issues: #"[{"path":"service","message":"Invalid string: must match pattern /^[a-z][a-z0-9-]{2,63}$/"},{"path":"","message":"Unrecognized key: \"extra\""}]"#
            )

            // Query: literal, union, trim/regex, custom positive integer.
            try await expect(
                .get,
                "/internal/agent-api/tasks?mine=TRUE",
                key: "taskList",
                part: "query",
                issues: #"[{"path":"mine","message":"Invalid input: expected \"true\""}]"#
            )
            try await expect(
                .get,
                "/internal/agent-api/tasks?status=bogus",
                key: "taskList",
                part: "query",
                issues: #"[{"path":"status","message":"Invalid input"}]"#
            )
            try await expect(
                .get,
                "/internal/agent-api/history?channel=%20",
                key: "historyRead",
                part: "query",
                issues: #"[{"path":"channel","message":"Too small: expected string to have >=1 characters"}]"#
            )
            try await expect(
                .get,
                "/internal/agent-api/assistant/owner-inbox?limit=0",
                key: "assistantOwnerInbox",
                part: "query",
                issues: #"[{"path":"limit","message":"must be a positive integer"}]"#
            )
            try await expect(
                .get,
                "/internal/agent-api/assistant/owner-messages?channelId=nope",
                key: "assistantOwnerMessages",
                part: "query",
                issues: #"[{"path":"channelId","message":"Invalid UUID"}]"#
            )
            try await expect(
                .get,
                "/internal/agent-api/feedback-locators?limit=0&runtime=foo",
                key: "feedbackLocatorList",
                part: "query",
                issues: #"[{"path":"runtime","message":"Invalid option: expected one of \"claude\"|\"codex\"|\"grok\"|\"kimi\"|\"kimi-sdk\"|\"pi\"|\"builtin\"|\"other\""},{"path":"limit","message":"Invalid string: must match pattern /^([1-9]|[1-9][0-9]|100)$/"}]"#
            )
            try await expect(
                .get,
                "/internal/agent-api/events?ack=bad",
                key: "events",
                part: "query",
                issues: #"[{"path":"ack","message":"Invalid option: expected one of \"cursor\"|\"immediate\""}]"#
            )

            // The custom `.superRefine` message runs only when every member
            // parses.
            try await expect(
                .get,
                "/internal/agent-api/tasks?channel=a&mine=true",
                key: "taskList",
                part: "query",
                issues: #"[{"path":"","message":"exactly one of channel or mine=true is required"}]"#
            )
            try await expect(
                .post,
                "/internal/agent-api/tasks/amend",
                body: ##"{"channel":"c","task_number":1}"##,
                key: "taskAmend",
                part: "body",
                issues: #"[{"path":"","message":"At least one of title or description is required"}]"#
            )

            // Params: trimmed min before the body is read.
            try await expect(
                .post,
                "/internal/agent-api/messages/%20/reactions",
                body: #"{}"#,
                key: "messageReactionAdd",
                part: "params",
                issues: #"[{"path":"msgId","message":"Too small: expected string to have >=1 characters"}]"#
            )

            // Reminder params/body schemas.
            try await expect(
                .delete,
                "/internal/agent-api/reminders/%20",
                key: "reminderCancel",
                part: "params",
                issues: #"[{"path":"reminderId","message":"Too small: expected string to have >=1 characters"}]"#
            )
            try await expect(
                .post,
                "/internal/agent-api/reminders/x/snooze",
                body: "{}",
                key: "reminderSnooze",
                part: "body",
                issues: #"[{"path":"delaySeconds","message":"Invalid input: expected number, received undefined"}]"#
            )

            // Discriminated union: selected member fields keep `action.` paths.
            try await expect(
                .post,
                "/internal/agent-api/prepare-action",
                body: #"{"target":"t","action":{"type":"channel:create","name":""}}"#,
                key: "actionPrepare",
                part: "body",
                issues: #"[{"path":"action.name","message":"Too small: expected string to have >=1 characters"}]"#
            )
            try await expect(
                .post,
                "/internal/agent-api/prepare-action",
                body: #"{"target":"t","action":{"type":"nope"}}"#,
                key: "actionPrepare",
                part: "body",
                issues: #"[{"path":"action.type","message":"Invalid input"}]"#
            )

            // The body schema itself is a discriminated union here, so the
            // discriminator path is `mode`, not a wrapped member.
            try await expect(
                .post,
                "/internal/agent-api/integrations/app/prepare",
                body: #"{"mode":"nope"}"#,
                key: "integrationAppPrepare",
                part: "body",
                issues: #"[{"path":"mode","message":"Invalid input"}]"#
            )
            try await expect(
                .post,
                "/internal/agent-api/integrations/app/prepare",
                body: #"{"mode":"update"}"#,
                key: "integrationAppPrepare",
                part: "body",
                issues: #"[{"path":"target","message":"Invalid input: expected string, received undefined"},{"path":"clientKey","message":"Invalid input: expected string, received undefined"}]"#
            )

            // Strict object with a non-negative integer member.
            try await expect(
                .patch,
                "/internal/agent-api/apps/app/config",
                body: #"{"expectedRevision":-1,"extra":1}"#,
                key: "appConfigPatch",
                part: "body",
                issues: #"[{"path":"expectedRevision","message":"Too small: expected number to be >=0"},{"path":"","message":"Unrecognized key: \"extra\""}]"#
            )

            // Auth and capability refusals stay ahead of request-schema
            // issues, matching the pinned middleware order.
            var noAuth = HTTPFields()
            let missingAuth = try await client.send(
                .post,
                headers: noAuth,
                to: "/internal/agent-api/channels"
            ) { request in
                request.body = .init(string: "[]")
            }
            #expect(missingAuth.status == .unauthorized)
            #expect(!(missingAuth.body.string ?? "").contains("agent_api_contract_invalid"))

            let readOnlyKey = accounts.mintAgentCredential(
                agentId: agentId,
                scopes: ["read"],
                name: "contract-read-only"
            )
            noAuth[.authorization] = "Bearer \(readOnlyKey)"
            let wrongCapability = try await client.send(
                .post,
                headers: noAuth,
                to: "/internal/agent-api/channels"
            ) { request in
                request.body = .init(string: "[]")
            }
            #expect(!(wrongCapability.body.string ?? "").contains("agent_api_contract_invalid"))

            // A valid request keeps its existing path: no contract 400.
            let valid = try await call(.get, "/internal/agent-api/tasks?channel=%23general")
            #expect(valid.status != .badRequest || !(valid.body.string ?? "").contains("agent_api_contract_invalid"))
        }
    }
}

/// The valid side of the same schemas: a value upstream accepts must not be
/// reported as a contract failure (trim, defaults, unions, datetime and UUID
/// shapes included).
@Test func agentApiContractSchemaAcceptsPinnedValues() throws {
    func failure(
        _ key: AgentApiContractRouteKey,
        _ part: AgentApiContractPart,
        _ text: String
    ) throws -> AgentApiContractFailure? {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        return AgentApiContractValidator.failure(for: key, part: part, value: value)
    }

    let receipt = #"{"channel":"c","task_number":1,"receipt":{"object":" o ","purpose":"p","teardown_owner":" @bot ","security_privacy":"s","expiry":"2024-02-29T23:59:59.123Z","runbook":"r","tracking":"t"}}"#
    #expect(try failure(.taskResourceReceipt, .body, receipt) == nil)

    let badDate = receipt.replacingOccurrences(of: "2024-02-29T23:59:59.123Z", with: "2024-02-30T00:00:00Z")
    #expect(try failure(.taskResourceReceipt, .body, badDate) != nil)

    let mute = #"{"attentionHintAccepted":{"schema":"attention-dependency-hint.v1","trigger":"M3","scope":" room ","copy_version":"v1","epoch_ms":1}}"#
    #expect(try failure(.channelMute, .body, mute) == nil)

    let prepare = #"{"mode":"update","target":"room","clientKey":" key ","name":"N"}"#
    #expect(try failure(.integrationAppPrepare, .body, prepare) == nil)

    let v2 = #"{"target":"c","content":"hi","mentions":[{"type":"agent","id":"11111111-1111-4111-8111-111111111111","name":" bot "}]}"#
    #expect(try failure(.messageSendV2, .body, v2) == nil)

    // Query values are strings; trim makes the padded forms valid.
    let page = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"limit":" 200 ","offset":" 0 "}"#.utf8))
    #expect(AgentApiContractValidator.failure(for: .userChannels, part: .query, value: page) == nil)
}
