import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Byte-level locks for the server task routes, channel archive/join and the
/// agent channel and server management routes: the published member order, the
/// `Content-Length`/`Content-Type` header set, the ordered refusal bodies, and
/// the raw-body fallback the retired handlers accepted without a JSON
/// `Content-Type`.

private func assertJSONHeaders(_ response: ClientResponse, body expected: String) {
    #expect(response.headers[.contentType] == "application/json; charset=utf-8")
    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
    #expect(response.headers[.contentLength] == String(Data(expected.utf8).count))
    #expect(response.body.string == expected)
}

private func jsonField(_ response: ClientResponse, _ path: [String]) -> String {
    var node: Any? = try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))
    for key in path { node = (node as? [String: Any])?[key] }
    return node as? String ?? ""
}

@Test func serverTaskRoutesPublishTheLegacyBytes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001220001"
    let memberId = "11111111-1111-4111-8111-000001220002"
    let serverId = "33333333-3333-4333-8333-000001220001"
    for (id, email) in [(ownerId, "tl-bytes-owner@slock.test"), (memberId, "tl-bytes-member@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "tl-bytes", name: "TL Bytes", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "tl-bytes", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "tl-bytes")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: memberId)
    let taskId = accounts.taskCatalog.addTasks(channelId: channelId, titles: ["Write bytes"]).first ?? ""
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            // `GET /api/tasks/channel/:id`: the published task row order.
            let list = try await client.send(.get, headers: headers, to: "/api/tasks/channel/\(channelId)")
            #expect(list.status == .ok)
            let row = (try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8))
                as? [String: Any])?["tasks"] as? [[String: Any]]
            let messageId = row?.first?["messageId"] as? String ?? ""
            // Node canonical task reads always publish description, including
            // null. Keep these literals source-derived, not captured Swift output.
            let taskCreatedAt = try #require(row?.first?["createdAt"] as? String)
            #expect(!taskCreatedAt.isEmpty)
            let taskRow = #"{"id":"\#(taskId)","messageId":"\#(messageId)","channelId":"\#(channelId)","channelName":"tl-bytes","channelType":"channel","taskNumber":1,"title":"Write bytes","description":null,"status":"todo","createdByType":null,"createdById":null,"createdByName":null,"createdByMembershipStatus":null,"claimedByType":null,"claimedById":null,"claimedByName":null,"claimedAt":null,"completedAt":null,"requiresResourceReceipt":false,"resourceReceipt":null,"resourceReceiptRecordedAt":null,"resourceTeardownOwnerAgentId":null,"resourceExpiryFollowupId":null,"createdAt":"\#(taskCreatedAt)","updatedAt":null,"revision":0,"taskCurrentProjection":{"title":"Write bytes","description":null,"revision":0,"superseded":false,"amendedAt":null,"amendedByType":null,"amendedByName":null,"source":"tasks_current_projection"},"isLegacy":false}"#
            assertJSONHeaders(list, body: "{\"tasks\":[\(taskRow)]}")

            let number = try await client.send(.get, headers: headers, to: "/api/tasks/channel/\(channelId)/number/1")
            assertJSONHeaders(number, body: "{\"task\":\(taskRow)}")
            let empty = try await client.send(.get, headers: headers, to: "/api/tasks/channel/\(channelId)?status=done")
            assertJSONHeaders(empty, body: "{\"tasks\":[]}")

            let badStatus = try await client.send(.get, headers: headers, to: "/api/tasks/channel/\(channelId)?status=nope")
            #expect(badStatus.status == .badRequest)
            assertJSONHeaders(badStatus, body: "{\"error\":\"status must be a single valid task status\"}")
            let missingNumber = try await client.send(.get, headers: headers, to: "/api/tasks/channel/\(channelId)/number/9")
            #expect(missingNumber.status == .notFound)
            assertJSONHeaders(missingNumber, body: "{\"error\":\"Task not found\"}")
            let anonymous = try await client.send(.get, headers: HTTPFields(), to: "/api/tasks/channel/\(channelId)")
            #expect(anonymous.status == .unauthorized)
            assertJSONHeaders(anonymous, body: "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
            #expect(anonymous.headers[.cacheControl] == "private, no-store")

            // `PATCH /api/tasks/:id/assignee`: a stale revision names the current one.
            var json = headers
            json[.contentType] = "application/json"
            let stale = try await client.send(.patch, headers: json, to: "/api/tasks/\(taskId)/assignee") { request in
                request.body = .init(string: "{\"assignee\":{\"type\":\"user\",\"id\":\"\(memberId)\"},\"expectedRevision\":4}")
            }
            #expect(stale.status == .conflict)
            assertJSONHeaders(stale, body: "{\"error\":\"Task changed concurrently\",\"currentRevision\":0}")
            let invalid = try await client.send(.patch, headers: json, to: "/api/tasks/\(taskId)/assignee") { request in
                request.body = .init(string: "{\"assignee\":\"nobody\"}")
            }
            assertJSONHeaders(invalid, body: "{\"error\":\"Invalid assignment\"}")
            let badRevision = try await client.send(.patch, headers: json, to: "/api/tasks/\(taskId)/assignee") { request in
                request.body = .init(string: "{\"assignee\":null,\"expectedRevision\":\"zero\"}")
            }
            assertJSONHeaders(badRevision, body: "{\"error\":\"expectedRevision must be an integer\"}")

            // A body without a JSON Content-Type is still accepted.
            let assigned = try await client.send(.patch, headers: headers, to: "/api/tasks/\(taskId)/assignee") { request in
                request.body = .init(string: "{\"assignee\":{\"type\":\"user\",\"id\":\"\(memberId)\"},\"expectedRevision\":0}")
            }
            #expect(assigned.status == .ok)
            let createdAt = jsonField(assigned, ["task", "createdAt"])
            let updatedAt = jsonField(assigned, ["task", "updatedAt"])
            #expect(!createdAt.isEmpty)
            #expect(!updatedAt.isEmpty)
            let expectedAssignment = #"{"task":{"id":"\#(taskId)","messageId":"\#(messageId)","channelId":"\#(channelId)","channelName":"tl-bytes","channelType":"channel","taskNumber":1,"title":"Write bytes","description":null,"status":"todo","createdByType":null,"createdById":null,"createdByName":null,"createdByMembershipStatus":null,"claimedByType":"user","claimedById":"\#(memberId)","claimedByName":"tl-bytes-member","claimedAt":null,"completedAt":null,"requiresResourceReceipt":false,"resourceReceipt":null,"resourceReceiptRecordedAt":null,"resourceTeardownOwnerAgentId":null,"resourceExpiryFollowupId":null,"createdAt":"\#(createdAt)","updatedAt":"\#(updatedAt)","revision":1,"taskCurrentProjection":{"title":"Write bytes","description":null,"revision":1,"superseded":false,"amendedAt":null,"amendedByType":null,"amendedByName":null,"source":"tasks_current_projection"},"isLegacy":false}}"#
            assertJSONHeaders(assigned, body: expectedAssignment)
            let sameAssignee = try await client.send(.patch, headers: json, to: "/api/tasks/\(taskId)/assignee") { request in
                request.body = .init(string: "{\"assignee\":{\"type\":\"user\",\"id\":\"\(memberId)\"}}")
            }
            #expect(sameAssignee.status == .ok)
            assertJSONHeaders(sameAssignee, body: expectedAssignment)
        }
    }
}

@Test func channelArchiveAndJoinPublishTheLegacyBytes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001220011"
    let guestlessId = "11111111-1111-4111-8111-000001220012"
    let serverId = "33333333-3333-4333-8333-000001220011"
    for (id, email) in [(ownerId, "tl-arch-owner@slock.test"), (guestlessId, "tl-arch-member@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "tl-arch", name: "TL Arch", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: guestlessId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "tl-arch", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "tl-arch")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let ownerToken = accounts.mintAccessTokenForTesting(userId: ownerId)
    let memberToken = accounts.mintAccessTokenForTesting(userId: guestlessId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }

            let anonymous = try await client.send(.post, headers: HTTPFields(), to: "/api/channels/\(channelId)/archive")
            #expect(anonymous.status == .unauthorized)
            assertJSONHeaders(anonymous, body: "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
            #expect(anonymous.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
            let stale = try await client.send(.post, headers: headers("bad-token"), to: "/api/channels/\(channelId)/archive")
            #expect(stale.body.string == "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")

            let forbidden = try await client.send(.post, headers: headers(memberToken), to: "/api/channels/\(channelId)/archive")
            #expect(forbidden.status == .forbidden)
            assertJSONHeaders(forbidden, body: "{\"error\":\"Forbidden\"}")

            let archived = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/\(channelId)/archive")
            #expect(archived.status == .ok)
            let stamp = jsonField(archived, ["archivedAt"])
            #expect(stamp.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/) != nil)
            assertJSONHeaders(archived, body: "{\"archivedAt\":\"\(stamp)\"}")

            // An archived channel refuses a join with the coded 409.
            let blocked = try await client.send(.post, headers: headers(memberToken), to: "/api/channels/\(channelId)/join")
            #expect(blocked.status == .conflict)
            assertJSONHeaders(blocked, body: "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")

            let unarchived = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/\(channelId)/unarchive")
            assertJSONHeaders(unarchived, body: "{\"archivedAt\":null}")
            let joined = try await client.send(.post, headers: headers(memberToken), to: "/api/channels/\(channelId)/join")
            #expect(joined.status == .ok)
            assertJSONHeaders(joined, body: "{\"ok\":true}")
            let again = try await client.send(.post, headers: headers(memberToken), to: "/api/channels/\(channelId)/join")
            assertJSONHeaders(again, body: "{\"ok\":true}")
        }
    }
}

@Test func agentChannelAndServerRoutesPublishTheLegacyBytes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001220021"
    let serverId = "33333333-3333-4333-8333-000001220021"
    accounts.addAccount(id: ownerId, email: "tl-agent-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "tl-agent", name: "TL Agent", ownerId: ownerId)
    let alpha = accounts.oauth.createChannel(serverId: serverId, name: "alpha", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: alpha, memberId: ownerId, name: "alpha")
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "ByteBot", creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.setAgentRole(serverId: serverId, agentId: agentId, role: "admin")
    accounts.oauth.addChannelAgent(channelId: alpha, agentId: agentId)
    let memberAgent = accounts.oauth.createAgent(serverId: serverId, name: "PlainBot", creatorUserId: ownerId, runtime: "claude")
    let adminKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "channels", "server", "send", "tasks"], name: "admin")
    let plainKey = accounts.mintAgentCredential(agentId: memberAgent, scopes: ["read", "channels", "server"], name: "plain")
    let taskIds = accounts.taskCatalog.addTasks(channelId: alpha, titles: ["Amend me"])
    #expect(taskIds.count == 1)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func headers(_ key: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(key)"
                fields[.contentType] = "application/json"
                return fields
            }
            let admin = headers(adminKey)
            var rawAdmin = HTTPFields()
            rawAdmin[.authorization] = "Bearer \(adminKey)"

            // `GET /server`: the runtime context, role, channels and agents in order.
            // Agent rows follow the ledger's own (hash) order, so the expectation reads it.
            let agentRows = [
                agentId: "{\"id\":\"\(agentId)\",\"name\":\"ByteBot\",\"role\":\"admin\",\"status\":\"inactive\",\"activity\":\"offline\",\"activityDetail\":\"\"}",
                memberAgent: "{\"id\":\"\(memberAgent)\",\"name\":\"PlainBot\",\"role\":\"member\",\"status\":\"inactive\",\"activity\":\"offline\",\"activityDetail\":\"\"}",
            ]
            let infoAgents = accounts.oauth.activeAgentIds(serverId: serverId)
                .compactMap { agentRows[$0] }.joined(separator: ",")
            let info = try await client.send(.get, headers: admin, to: "/internal/agent-api/server")
            #expect(info.status == .ok)
            assertJSONHeaders(
                info,
                body: "{\"id\":\"\(serverId)\",\"name\":\"TL Agent\",\"slug\":\"tl-agent\",\"runtimeContext\":{\"agentId\":\"\(agentId)\",\"runtime\":\"claude\",\"model\":\"external\",\"reasoningEffort\":null,\"serverId\":\"\(serverId)\",\"machineId\":null,\"machineName\":null,\"machineDescription\":null,\"machineHostname\":null,\"machineOs\":null,\"daemonVersion\":null,\"workspacePath\":null},\"serverRole\":\"admin\",\"serverCapabilities\":{\"addChannelMembers\":true,\"createChannels\":true},\"channels\":[{\"id\":\"\(alpha)\",\"name\":\"alpha\",\"type\":\"channel\",\"joined\":true,\"activityMuted\":false,\"muteFromSeq\":null}],\"agents\":[\(infoAgents)]}"
            )

            let badToken = try await client.send(.get, headers: headers("sk_agent_nope"), to: "/internal/agent-api/server")
            #expect(badToken.status == .unauthorized)
            assertJSONHeaders(badToken, body: "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")

            // `POST /channels`: create, in the published order.
            let created = try await client.send(.post, headers: admin, to: "/internal/agent-api/channels") { request in
                request.body = .init(string: "{\"name\":\"#beta\",\"description\":\"Beta room\"}")
            }
            #expect(created.status == .ok)
            let beta = jsonField(created, ["id"])
            assertJSONHeaders(
                created,
                body: "{\"id\":\"\(beta)\",\"name\":\"beta\",\"type\":\"channel\",\"description\":\"Beta room\",\"joined\":true,\"createdByAgentId\":\"\(agentId)\"}"
            )
            let invalidName = try await client.send(.post, headers: admin, to: "/internal/agent-api/channels") { request in
                request.body = .init(string: "{\"name\":\"Bad Name\"}")
            }
            assertJSONHeaders(invalidName, body: "{\"error\":\"Invalid channel\"}")
            let noBody = try await client.send(.post, headers: admin, to: "/internal/agent-api/channels")
            assertJSONHeaders(noBody, body: "{\"error\":\"Invalid channel\"}")

            // `PATCH /channels/:id`: no body is `{}`, so the channel round-trips unchanged;
            // a body without a JSON Content-Type is accepted.
            let unchanged = try await client.send(.patch, headers: rawAdmin, to: "/internal/agent-api/channels/\(beta)")
            assertJSONHeaders(
                unchanged,
                body: "{\"id\":\"\(beta)\",\"name\":\"beta\",\"description\":\"Beta room\",\"type\":\"channel\"}"
            )
            let renamed = try await client.send(.patch, headers: rawAdmin, to: "/internal/agent-api/channels/\(beta)") { request in
                request.body = .init(string: "{\"name\":\"#gamma\",\"visibility\":\"private\"}")
            }
            assertJSONHeaders(
                renamed,
                body: "{\"id\":\"\(beta)\",\"name\":\"gamma\",\"description\":\"Beta room\",\"type\":\"private\"}"
            )
            let notObject = try await client.send(.patch, headers: admin, to: "/internal/agent-api/channels/\(beta)") { request in
                request.body = .init(string: "[1]")
            }
            assertJSONHeaders(notObject, body: "{\"error\":\"Invalid channel update\"}")
            let badVisibility = try await client.send(.patch, headers: admin, to: "/internal/agent-api/channels/\(beta)") { request in
                request.body = .init(string: "{\"visibility\":\"secret\"}")
            }
            assertJSONHeaders(badVisibility, body: "{\"error\":\"Invalid channel visibility\"}")

            // A member role cannot update: the ordered capability refusal.
            let denied = try await client.send(.patch, headers: headers(plainKey), to: "/internal/agent-api/channels/\(alpha)") { request in
                request.body = .init(string: "{\"name\":\"nope\"}")
            }
            #expect(denied.status == .forbidden)
            assertJSONHeaders(
                denied,
                body: "{\"error\":\"Agent requires editChannelMetadata or changeChannelVisibility capability to update channels\",\"code\":\"server_role_required\",\"currentRole\":\"member\",\"suggestedNextAction\":\"Ask a server owner or admin to grant the capability; your role is member.\"}"
            )

            // Member write: remove with the attention block, then add back.
            let remove = try await client.send(.delete, headers: admin, to: "/internal/agent-api/channels/\(alpha)/members") { request in
                request.body = .init(string: "{\"user\":\"@\(ownerId)\"}")
            }
            assertJSONHeaders(
                remove,
                body: "{\"ok\":true,\"wasMember\":true,\"member\":{\"type\":\"human\",\"name\":\"\(ownerId)\"},\"attention\":{\"stillArrives\":[\"Followed threads still notify this member unless they unfollow them.\"],\"threadBoundary\":\"Removing this member does not unfollow existing thread follows. Private channel/thread content still requires current parent access.\",\"manageCommand\":\"Use raft thread unfollow to manage thread follows.\"}}"
            )
            let add = try await client.send(.post, headers: admin, to: "/internal/agent-api/channels/\(alpha)/members") { request in
                request.body = .init(string: "{\"user\":\"\(ownerId)\"}")
            }
            assertJSONHeaders(add, body: "{\"ok\":true,\"alreadyMember\":false,\"member\":{\"type\":\"human\",\"name\":\"\(ownerId)\"}}")
            let addAgent = try await client.send(.post, headers: admin, to: "/internal/agent-api/channels/\(alpha)/members") { request in
                request.body = .init(string: "{\"agent\":\"PlainBot\"}")
            }
            assertJSONHeaders(addAgent, body: "{\"ok\":true,\"alreadyMember\":false,\"member\":{\"type\":\"agent\",\"name\":\"PlainBot\"}}")
            let noMember = try await client.send(.post, headers: admin, to: "/internal/agent-api/channels/\(alpha)/members") { request in
                request.body = .init(string: "{}")
            }
            assertJSONHeaders(noMember, body: "{\"error\":\"Invalid channel member\"}")
            let noUser = try await client.send(.post, headers: admin, to: "/internal/agent-api/channels/\(alpha)/members") { request in
                request.body = .init(string: "{\"user\":\"ghost\"}")
            }
            #expect(noUser.status == .notFound)
            assertJSONHeaders(noUser, body: "{\"error\":\"User not found\"}")

            // `GET /channel-members`.
            let memberNames = [agentId: "ByteBot", memberAgent: "PlainBot"]
            let memberRows = accounts.oauth.channelAgentIds(channelId: alpha).map {
                "{\"id\":\"\($0)\",\"name\":\"\(memberNames[$0] ?? "")\",\"status\":\"inactive\"}"
            }.joined(separator: ",")
            let members = try await client.send(.get, headers: admin, to: "/internal/agent-api/channel-members?channel=%23alpha")
            #expect(members.status == .ok)
            assertJSONHeaders(
                members,
                body: "{\"channel\":{\"ref\":\"#alpha\",\"type\":\"channel\"},\"humans\":[{\"id\":\"\(ownerId)\",\"name\":\"tl-agent-owner\",\"role\":\"owner\"}],\"agents\":[\(memberRows)]}"
            )
            let noRef = try await client.send(.get, headers: admin, to: "/internal/agent-api/channel-members")
            assertJSONHeaders(noRef, body: "{\"error\":\"channel is required\"}")

            // `POST /resolve-channel`.
            let resolved = try await client.send(.post, headers: admin, to: "/internal/agent-api/resolve-channel") { request in
                request.body = .init(string: "{\"target\":\"#alpha\"}")
            }
            assertJSONHeaders(resolved, body: "{\"channelId\":\"\(alpha)\",\"type\":\"channel\"}")
            let badTarget = try await client.send(.post, headers: admin, to: "/internal/agent-api/resolve-channel") { request in
                request.body = .init(string: "{\"target\":\"alpha\"}")
            }
            assertJSONHeaders(badTarget, body: "{\"error\":\"Invalid target\"}")

            // `PATCH /server`.
            let renamedServer = try await client.send(.patch, headers: admin, to: "/internal/agent-api/server") { request in
                request.body = .init(string: "{\"name\":\"TL Renamed\"}")
            }
            assertJSONHeaders(renamedServer, body: "{\"ok\":true,\"id\":\"\(serverId)\",\"name\":\"TL Renamed\"}")
            let badServer = try await client.send(.patch, headers: admin, to: "/internal/agent-api/server") { request in
                request.body = .init(string: "{\"name\":5}")
            }
            assertJSONHeaders(badServer, body: "{\"error\":\"Invalid server update\"}")

            // `POST /tasks/amend`.
            let amended = try await client.send(.post, headers: admin, to: "/internal/agent-api/tasks/amend") { request in
                request.body = .init(string: "{\"channel\":\"#alpha\",\"task_number\":1,\"title\":\"  Amended  \"}")
            }
            #expect(amended.status == .ok)
            let messageId = jsonField(amended, ["messageId"])
            assertJSONHeaders(
                amended,
                body: "{\"id\":\"\(taskIds[0])\",\"channelId\":\"\(alpha)\",\"messageId\":\"\(messageId)\",\"title\":\"Amended\",\"status\":\"todo\",\"taskNumber\":1,\"claimedById\":null,\"claimedByType\":null,\"claimedAt\":null,\"revision\":1}"
            )
            let badAmend = try await client.send(.post, headers: admin, to: "/internal/agent-api/tasks/amend") { request in
                request.body = .init(string: "{\"channel\":\"#alpha\",\"task_number\":1,\"title\":\"   \"}")
            }
            assertJSONHeaders(badAmend, body: "{\"error\":\"Invalid task request\"}")
            let missingTask = try await client.send(.post, headers: admin, to: "/internal/agent-api/tasks/amend") { request in
                request.body = .init(string: "{\"channel\":\"#alpha\",\"task_number\":9,\"title\":\"Ghost\"}")
            }
            #expect(missingTask.status == .notFound)
            assertJSONHeaders(missingTask, body: "{\"error\":\"Task not found\"}")

            // `POST /channels/:id/join` for an agent.
            let joinTarget = accounts.oauth.createChannel(serverId: serverId, name: "delta", creatorUserId: ownerId)
            accounts.addPostableChannel(serverId: serverId, channelId: joinTarget, memberId: ownerId, name: "delta")
            let joined = try await client.send(.post, headers: headers(plainKey), to: "/internal/agent-api/channels/\(joinTarget)/join")
            #expect(joined.status == .ok)
            assertJSONHeaders(joined, body: "{\"ok\":true}")
            let noAuth = try await client.send(.post, headers: HTTPFields(), to: "/internal/agent-api/channels/\(joinTarget)/join")
            #expect(noAuth.status == .unauthorized)
            assertJSONHeaders(noAuth, body: "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
    }
}
