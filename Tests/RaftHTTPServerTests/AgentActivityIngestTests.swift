import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func externalAgentActivityIngestIsReadGatedAndRejectsTranscriptPaths() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111650"
    let serverId = "33333333-3333-4333-8333-333333333690"
    accounts.addAccount(id: ownerId, email: "activity-ingest@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "activity-ingest", name: "Activity Ingest", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "ActivityBot", creatorUserId: ownerId, runtime: "claude")
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "activity-read")
    let writeKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["send"], name: "activity-write")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func ingest(_ key: String, _ json: [String: Any]) async throws -> (HTTPResponse.Status, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: json)
                let response = try await client.send(.post, headers: headers, to: "/internal/agent-api/activity") { request in
                    request.body = .init(data: data)
                }
                return (response.status, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let schema = "raft-agent-activity-ingest.v1"
            let accepted = try await ingest(key, [
                "schema": schema,
                "events": [["eventId": "activity-route-1", "hookEventName": "PreToolUse", "toolName": "Bash", "toolInput": "npm test", "truncated": true]],
                "dropped": 1,
            ])
            #expect(accepted.0 == .ok)
            #expect(accepted.1["acceptedCount"] as? Int == 1)
            #expect(accepted.1["droppedCount"] as? Int == 1)

            let forbidden = try await ingest(key, [
                "schema": schema,
                "events": [["eventId": "activity-route-2", "hookEventName": "PreToolUse", "toolName": "Bash", "transcript_path": "/tmp/claude-transcript.jsonl"]],
            ])
            #expect(forbidden.0 == .badRequest)
            #expect(forbidden.1["code"] as? String == "transcript_path_forbidden")

            let stripped = try await ingest(key, [
                "schema": schema,
                "events": [["eventId": "activity-route-3", "hookEventName": "PostToolUse", "toolName": "Bash", "tool_use_id": "toolu_1", "exit_code": 1, "ok": true, "futureField": ["nested": true]]],
            ])
            #expect(stripped.0 == .ok)
            #expect(stripped.1["ignoredFields"] as? [String] == ["futureField"])

            let writeOnly = try await ingest(writeKey, ["schema": schema, "events": []])
            #expect(writeOnly.0 == .forbidden)
        }
    }
}
