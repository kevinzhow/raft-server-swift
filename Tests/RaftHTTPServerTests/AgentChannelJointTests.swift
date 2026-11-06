import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct JointFixture {
    let accounts = EmailLoginDirectory()
    let hostServerId = "33333333-3333-4333-8333-000001101001"
    let targetServerId = "33333333-3333-4333-8333-000001101002"
    let hostOwnerId = "11111111-1111-4111-8111-000001101001"
    let targetOwnerId = "11111111-1111-4111-8111-000001101002"
    let hostSlug = "joint-host"
    let targetSlug = "joint-target"
    var agentId = ""
    var hostProjectionId = ""
    var targetProjectionId = ""
    var agentKey = ""
    var hostToken = ""
    var targetToken = ""

    mutating func seed() {
        for (id, email) in [(hostOwnerId, "joint-host-owner"), (targetOwnerId, "joint-target-owner")] {
            accounts.addAccount(id: id, email: "\(email)@joint.test", password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: hostServerId, slug: hostSlug, name: "Joint Host", ownerId: hostOwnerId)
        accounts.oauth.addOwnedServer(id: targetServerId, slug: targetSlug, name: "Joint Target", ownerId: targetOwnerId)
        agentId = accounts.oauth.createAgent(serverId: hostServerId, name: "JointBot", creatorUserId: hostOwnerId, runtime: "codex")
        accounts.oauth.setAgentRole(serverId: hostServerId, agentId: agentId, role: "admin")
        agentKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["channels", "read"], name: "joint")
        hostToken = accounts.mintAccessTokenForTesting(userId: hostOwnerId)
        targetToken = accounts.mintAccessTokenForTesting(userId: targetOwnerId)
    }

    func headers(_ token: String, server: String) -> HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[.contentType] = "application/json"
        headers[HTTPField.Name("X-Server-Id")!] = server
        return headers
    }

    func agentHeaders() -> HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(agentKey)"
        headers[.contentType] = "application/json"
        return headers
    }
}

private func json(_ text: String?) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((text ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func jointChannelAgentLeaveMembershipRenameArchiveAndBadges() async throws {
    var fixture = JointFixture()
    fixture.seed()
    let accounts = fixture.accounts
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let created = try await client.send(.post, headers: fixture.headers(fixture.hostToken, server: fixture.hostServerId), to: URI(string: "/api/channels")) { request in
                request.body = .init(string: "{\"name\":\"joint-room\",\"visibility\":\"joint\",\"targetServerSlug\":\"\(fixture.targetSlug)\",\"invitedPeople\":[\"@joint-target-owner\"]}")
            }
            #expect(created.status == .ok, Comment(rawValue: created.body.string ?? ""))
            let createdBody = json(created.body.string)
            fixture.hostProjectionId = try #require(createdBody["id"] as? String)
            let inviteId = try #require((createdBody["jointInvite"] as? [String: Any])?["id"] as? String)
            let accepted = try await client.send(.post, headers: fixture.headers(fixture.targetToken, server: fixture.targetServerId), to: URI(string: "/api/channels/joint-invites/\(inviteId)/accept"))
            #expect(accepted.status == .ok, Comment(rawValue: accepted.body.string ?? ""))
            fixture.targetProjectionId = try #require(json(accepted.body.string)["id"] as? String)

            accounts.oauth.addChannelAgent(channelId: fixture.hostProjectionId, agentId: fixture.agentId)

            // 1. Agent leaves the host projection only.
            let leave = try await client.send(.post, headers: fixture.agentHeaders(), to: URI(string: "/internal/agent-api/channels/\(fixture.hostProjectionId)/leave"))
            #expect(leave.status == .ok)
            #expect(accounts.oauth.channelAgentIds(channelId: fixture.hostProjectionId).contains(fixture.agentId) == false)
            #expect(accounts.oauth.channelHumanIds(channelId: fixture.targetProjectionId).contains(fixture.targetOwnerId))

            // 2. Admin agent adds/removes a host member, and cannot address the peer server's owner.
            let memberId = "11111111-1111-4111-8111-000001101003"
            accounts.addAccount(id: memberId, email: "joint-member@joint.test", password: "password123")
            accounts.markEmailVerified(userId: memberId)
            accounts.oauth.addMember(serverId: fixture.hostServerId, userId: memberId, role: "member")
            for (path, verb) in [("members", "POST"), ("members", "DELETE")] {
                let headers = fixture.agentHeaders()
                let body = "{\"user\":\"@joint-member\"}"
                let response = try await client.send(verb == "POST" ? .post : .delete, headers: headers, to: URI(string: "/internal/agent-api/channels/\(fixture.hostProjectionId)/\(path)")) { request in
                    request.body = .init(string: body)
                }
                #expect(response.status == .ok, Comment(rawValue: response.body.string ?? ""))
            }
            let crossServer = try await client.send(.post, headers: fixture.agentHeaders(), to: URI(string: "/internal/agent-api/channels/\(fixture.hostProjectionId)/members")) { request in
                request.body = .init(string: "{\"user\":\"@joint-target-owner\"}")
            }
            #expect(crossServer.status == .notFound)

            // 3. Rename and archive propagate to both projections; visibility is refused.
            let renamed = try await client.send(.patch, headers: fixture.agentHeaders(), to: URI(string: "/internal/agent-api/channels/\(fixture.hostProjectionId)")) { request in
                request.body = .init(string: "{\"name\":\"joint-renamed\"}")
            }
            #expect(renamed.status == .ok)
            #expect(accounts.oauth.channelInfo(id: fixture.targetProjectionId)?.name == "joint-renamed")
            let visibility = try await client.send(.patch, headers: fixture.agentHeaders(), to: URI(string: "/internal/agent-api/channels/\(fixture.hostProjectionId)")) { request in
                request.body = .init(string: "{\"visibility\":\"private\"}")
            }
            #expect(visibility.status == .forbidden)
            let archived = try await client.send(.patch, headers: fixture.agentHeaders(), to: URI(string: "/internal/agent-api/channels/\(fixture.hostProjectionId)")) { request in
                request.body = .init(string: "{\"archived\":true}")
            }
            #expect(archived.status == .ok)
            #expect(accounts.oauth.channelArchivedAt(id: fixture.targetProjectionId) != nil)
            let unarchived = try await client.send(.patch, headers: fixture.agentHeaders(), to: URI(string: "/internal/agent-api/channels/\(fixture.hostProjectionId)")) { request in
                request.body = .init(string: "{\"archived\":false}")
            }
            #expect(unarchived.status == .ok)
            #expect(accounts.oauth.channelArchivedAt(id: fixture.targetProjectionId) == nil)

            let plainAgentId = accounts.oauth.createAgent(serverId: fixture.hostServerId, name: "JointPlain", creatorUserId: fixture.hostOwnerId, runtime: "codex")
            let plainKey = accounts.mintAgentCredential(agentId: plainAgentId, scopes: ["channels"], name: "joint-plain")
            accounts.oauth.addChannelAgent(channelId: fixture.hostProjectionId, agentId: plainAgentId)
            var plainHeaders = HTTPFields()
            plainHeaders[.authorization] = "Bearer \(plainKey)"
            plainHeaders[.contentType] = "application/json"
            let plainArchive = try await client.send(.patch, headers: plainHeaders, to: URI(string: "/internal/agent-api/channels/\(fixture.hostProjectionId)")) { request in
                request.body = .init(string: "{\"archived\":true}")
            }
            #expect(plainArchive.status == .forbidden, "an ordinary agent cannot archive a joint channel")

            // 4. Member listing names host first with yours, then the peer.
            let dualId = "11111111-1111-4111-8111-000001101004"
            accounts.addAccount(id: dualId, email: "joint-dual@joint.test", password: "password123")
            accounts.markEmailVerified(userId: dualId)
            accounts.oauth.addMember(serverId: fixture.hostServerId, userId: dualId, role: "member")
            accounts.oauth.addMember(serverId: fixture.targetServerId, userId: dualId, role: "member")
            accounts.oauth.addChannelHuman(channelId: fixture.hostProjectionId, userId: dualId)
            accounts.oauth.addChannelHuman(channelId: fixture.targetProjectionId, userId: dualId)
            let members = try await client.get(URI(string: "/internal/agent-api/channel-members?channel=%23joint-renamed"), headers: fixture.agentHeaders())
            #expect(members.status == .ok, Comment(rawValue: members.body.string ?? ""))
            let humans = json(members.body.string)["humans"] as? [[String: Any]] ?? []
            let byName = Dictionary(uniqueKeysWithValues: humans.compactMap { human -> (String, [String: Any])? in
                guard let name = human["name"] as? String else { return nil }
                return (name, human)
            })
            let dualServers = byName["joint-dual"]?["servers"] as? [[String: Any]] ?? []
            #expect(dualServers.compactMap { $0["slug"] as? String } == [fixture.hostSlug, fixture.targetSlug])
            #expect(dualServers.first?["yours"] as? Bool == true)
            let targetServers = byName["joint-target-owner"]?["servers"] as? [[String: Any]] ?? []
            #expect(targetServers.compactMap { $0["slug"] as? String } == [fixture.targetSlug])
            #expect(byName["joint-host-owner"]?["servers"] == nil, "a person only on the agent's server is listed as before")
        }
    }
}
