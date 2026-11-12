import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

private struct TypedMembershipAccounts {
    let accounts = EmailLoginDirectory()
    let owner = UUID().uuidString.lowercased()
    let server = UUID().uuidString.lowercased()
    let sharedId: String
    let ownerHeaders: HTTPFields
    let humanHeaders: HTTPFields
    let agentHeaders: HTTPFields
    let adminHeaders: HTTPFields

    init() {
        accounts.addAccount(id: owner, email: "typed-owner@slock.test", password: "password123")
        accounts.markEmailVerified(userId: owner)
        accounts.oauth.addOwnedServer(id: server, slug: "typed-members", name: "Typed Members", ownerId: owner)
        sharedId = accounts.oauth.createAgent(serverId: server, name: "shared-agent")
        accounts.addAccount(id: sharedId, email: "typed-human@slock.test", password: "password123")
        accounts.markEmailVerified(userId: sharedId)
        accounts.oauth.addMember(serverId: server, userId: sharedId, role: "member")
        let admin = accounts.oauth.createAgent(serverId: server, name: "typed-admin")
        accounts.oauth.setAgentRole(serverId: server, agentId: admin, role: "admin")
        let serverID = server
        func headers(_ key: String) -> HTTPFields {
            var result = HTTPFields()
            result[.authorization] = "Bearer \(key)"
            result[.contentType] = "application/json"
            result[HTTPField.Name("X-Server-Id")!] = serverID
            return result
        }
        ownerHeaders = headers(accounts.mintAccessTokenForTesting(userId: owner))
        humanHeaders = headers(accounts.mintAccessTokenForTesting(userId: sharedId))
        agentHeaders = headers(accounts.mintAgentCredential(agentId: sharedId, scopes: ["read", "send", "channels"], name: "typed-agent"))
        adminHeaders = headers(accounts.mintAgentCredential(agentId: admin, scopes: ["channels"], name: "typed-admin"))
    }
}

private func typedMembershipJSON(_ response: ClientResponse) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: response.body.data ?? Data()) as? [String: Any])
}

private func createTypedPrivateChannel(_ client: any Client, _ f: TypedMembershipAccounts, includeHuman: Bool = true) async throws -> String {
    let bytes = try JSONSerialization.data(withJSONObject: [
        "name": "typed-private", "visibility": "private", "agentIds": [f.sharedId],
        "userIds": includeHuman ? [f.sharedId] : [],
    ])
    let response = try await client.send(.post, headers: f.ownerHeaders, to: "/api/channels") { $0.body = .init(data: bytes) }
    #expect(response.status == .ok)
    return try #require(typedMembershipJSON(response)["id"] as? String)
}

/// channelService.ts:6650-6676 uses separate channel_humans/channel_agents.
/// Removing either entity must preserve the other entity's projected UUID.
@Test(arguments: ["human", "agent", "leave"], ["agent", "human"])
func attachmentTypedMembershipRemovalPreservesTheOtherEntity(remover: String, removedKind: String) async throws {
    let f = TypedMembershipAccounts()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let channel = try await createTypedPrivateChannel(client, f)
            let attachment = UUID().uuidString.lowercased()
            let bytes = Data("typed private attachment".utf8)
            f.accounts.addAgentAttachmentForTesting(channelId: channel, id: attachment, uploaderId: f.owner,
                filename: "typed.bin", mimeType: "application/octet-stream", sizeBytes: bytes.count, bytes: bytes)
            let detailPath = URI(string: "/api/channels/\(channel)")
            let humanPath = URI(string: "/api/attachments/\(attachment)")
            let agentPath = URI(string: "/internal/agent-api/attachments/\(attachment)")
            #expect(try await client.get(detailPath, headers: f.humanHeaders).status == .ok)
            #expect(try await client.get(humanPath, headers: f.humanHeaders).body.data == bytes)
            #expect(try await client.get(agentPath, headers: f.agentHeaders).body.data == bytes)
            let removed: ClientResponse
            if remover == "agent" {
                let body = try JSONSerialization.data(withJSONObject: [removedKind == "agent" ? "agent" : "user": f.sharedId])
                removed = try await client.send(.delete, headers: f.adminHeaders, to: URI(string: "/internal/agent-api/channels/\(channel)/members")) { $0.body = .init(data: body) }
            } else if remover == "leave" {
                let prefix = removedKind == "agent" ? "/internal/agent-api" : "/api"
                removed = try await client.post(URI(string: "\(prefix)/channels/\(channel)/leave"), headers: removedKind == "agent" ? f.agentHeaders : f.humanHeaders)
            } else {
                let kind = removedKind == "agent" ? "agent" : "user"
                removed = try await client.delete(URI(string: "/api/channels/\(channel)/members/\(kind)/\(f.sharedId)"), headers: f.ownerHeaders)
            }
            #expect(removed.status == .ok)
            let humanDetail = try await client.get(detailPath, headers: f.humanHeaders)
            let humanBytes = try await client.get(humanPath, headers: f.humanHeaders)
            let agentBytes = try await client.get(agentPath, headers: f.agentHeaders)
            if removedKind == "agent" {
                #expect(humanDetail.status == .ok)
                #expect(humanBytes.status == .ok)
                #expect(humanBytes.body.data == bytes)
                #expect(agentBytes.status == .notFound)
            } else {
                #expect(humanDetail.status == .notFound)
                #expect(humanBytes.status == .notFound)
                #expect(agentBytes.status == .ok)
                #expect(agentBytes.body.data == bytes)
                let sent = try await client.send(.post, headers: f.agentHeaders, to: "/internal/agent-api/send") {
                    $0.body = .init(string: ##"{"target":"#typed-private","content":"Agent remains a posting member"}"##)
                }
                #expect(sent.status == .ok)
            }
        }
    }
}

/// Human canUserAccessChannel (channelService.ts:4921-5025) checks human
/// membership, including when an Agent with the same UUID is a selected member.
@Test(arguments: [false, true])
func attachmentHumanReadDoesNotInheritAgentOnlyMembership(includeHuman: Bool) async throws {
    let f = TypedMembershipAccounts()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let channel = try await createTypedPrivateChannel(client, f, includeHuman: includeHuman)
            let attachment = UUID().uuidString.lowercased()
            let bytes = Data("typed read authority".utf8)
            f.accounts.addAgentAttachmentForTesting(channelId: channel, id: attachment, uploaderId: f.owner,
                filename: "typed.bin", mimeType: "application/octet-stream", sizeBytes: bytes.count, bytes: bytes)
            let detail = try await client.get(URI(string: "/api/channels/\(channel)"), headers: f.humanHeaders)
            #expect(detail.status == (includeHuman ? .ok : .notFound))
            let raw = try await client.get(URI(string: "/api/attachments/\(attachment)"), headers: f.humanHeaders)
            #expect(raw.status == (includeHuman ? .ok : .notFound))
            let comments = try await client.get(URI(string: "/api/attachments/\(attachment)/comments"), headers: f.humanHeaders)
            #expect(comments.status == (includeHuman ? .ok : .notFound))
            if includeHuman { #expect(raw.body.data == bytes) }
            else { #expect(raw.body.data?.range(of: bytes) == nil) }
        }
    }
}
