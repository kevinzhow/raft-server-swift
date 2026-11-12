import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

private struct AttachmentAuthorityAccounts {
    let accounts = EmailLoginDirectory()
    let owner = UUID().uuidString.lowercased()
    let server = UUID().uuidString.lowercased()
    var headers: HTTPFields {
        var fields = HTTPFields()
        fields[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: owner))"
        fields[HTTPField.Name("X-Server-Id")!] = server
        fields[.contentType] = "application/json"
        return fields
    }
    init() {
        accounts.addAccount(id: owner, email: "attachment-authority@slock.test", password: "password123")
        accounts.markEmailVerified(userId: owner)
        accounts.oauth.addOwnedServer(id: server, slug: "attachment-authority", name: "Attachment Authority", ownerId: owner)
    }
}

/// Upstream channelService.ts:6697-6758 authorizes channel_agents, never a
/// retained posting projection or a human row with the same UUID. This is the
/// readable shape of an older persisted stale projection before any new remove.
@Test(arguments: [false, true], [false, true])
func attachmentCanonicalAuthorityRejectsRetainedPostingMembership(humanUUIDCollision: Bool, postingRowPresent: Bool) async throws {
    let f = AttachmentAuthorityAccounts()
    let agent = f.accounts.oauth.createAgent(serverId: f.server, name: "former-member")
    let channel = f.accounts.oauth.createChannel(serverId: f.server, name: "canonical-private", creatorUserId: f.owner, type: "private")
    f.accounts.oauth.addChannelHuman(channelId: channel, userId: f.owner)
    if postingRowPresent {
        f.accounts.addPostableChannel(serverId: f.server, channelId: channel, memberId: f.owner, kind: "private", name: "canonical-private")
        f.accounts.addPostableChannel(serverId: f.server, channelId: channel, memberId: agent, kind: "private", name: "canonical-private")
    }
    if humanUUIDCollision {
        f.accounts.addAccount(id: agent, email: "same-uuid-human@slock.test", password: "password123")
        f.accounts.markEmailVerified(userId: agent)
        f.accounts.oauth.addMember(serverId: f.server, userId: agent, role: "member")
        f.accounts.oauth.addChannelHuman(channelId: channel, userId: agent)
    }
    let id = UUID().uuidString.lowercased()
    let bytes = Data("canonical private bytes".utf8)
    f.accounts.addAgentAttachmentForTesting(channelId: channel, id: id, uploaderId: f.owner,
        filename: "secret.bin", mimeType: "application/octet-stream", sizeBytes: bytes.count, bytes: bytes)
    let credential = f.accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "former-member")
    let current = f.accounts.oauth.createAgent(serverId: f.server, name: "current-member")
    f.accounts.oauth.addChannelAgent(channelId: channel, agentId: current)
    let currentCredential = f.accounts.mintAgentCredential(agentId: current, scopes: ["read"], name: "current-member")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(credential)"
            for suffix in ["", "/url"] {
                let denied = try await client.get(URI(string: "/internal/agent-api/attachments/\(id)\(suffix)"), headers: agentHeaders)
                #expect(denied.status == .notFound)
                if denied.status == .notFound {
                    let body = try JSONSerialization.jsonObject(with: denied.body.data ?? Data()) as? [String: Any]
                    #expect(body?["code"] as? String == "ATTACHMENT_UNAVAILABLE")
                }
                #expect(denied.body.data?.range(of: bytes) == nil)
            }
            let history = try await client.get("/internal/agent-api/history?channel=%23canonical-private&consume=false", headers: agentHeaders)
            #expect(history.status == .notFound)
            var currentHeaders = HTTPFields()
            currentHeaders[.authorization] = "Bearer \(currentCredential)"
            let witness = try await client.get(URI(string: "/internal/agent-api/attachments/\(id)"), headers: currentHeaders)
            #expect(witness.status == .ok)
            #expect(witness.body.data == bytes)
            if postingRowPresent {
                let human = try await client.get(URI(string: "/api/attachments/\(id)"), headers: f.headers)
                #expect(human.status == .ok)
                #expect(human.body.data == bytes)
            }
        }
    }
}

/// Upstream channels.ts:941-998 validates all initial selections before any
/// channel is published. A failed selection must leave no partial room behind.
@Test(arguments: ["visibility", "null-visibility", "agent", "user"])
func attachmentPrivateCreationRejectsInvalidInitialSelectionsAtomically(invalid: String) async throws {
    let f = AttachmentAuthorityAccounts()
    var body: [String: Any] = ["name": "atomic-private", "visibility": "private"]
    switch invalid {
    case "visibility": body["visibility"] = "unrecognized"
    case "null-visibility": body["visibility"] = NSNull()
    case "agent": body["agentIds"] = [UUID().uuidString.lowercased()]
    default: body["userIds"] = [UUID().uuidString.lowercased()]
    }
    let payload = try JSONSerialization.data(withJSONObject: body)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let refused = try await client.send(.post, headers: f.headers, to: "/api/channels") { $0.body = .init(data: payload) }
            #expect(refused.status == .badRequest)
            let reply = try JSONSerialization.jsonObject(with: refused.body.data ?? Data()) as? [String: Any]
            let expected = invalid.contains("visibility") ? "visibility must be one of: public, private, joint"
                : invalid == "agent" ? "Agent not found in this server" : "User is not a member of this server"
            #expect(reply?["error"] as? String == expected)
            let list = try await client.get("/api/channels", headers: f.headers)
            #expect(list.status == .ok)
            let channels = try #require(try JSONSerialization.jsonObject(with: list.body.data ?? Data()) as? [[String: Any]])
            #expect(!channels.contains { $0["name"] as? String == "atomic-private" })
        }
    }
}
