import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

private struct ChannelCreateContractAccounts {
    let accounts = EmailLoginDirectory()
    let owner = UUID().uuidString.lowercased()
    let server = UUID().uuidString.lowercased()
    let actor: String
    let headers: HTTPFields

    init(role: String) {
        accounts.addAccount(id: owner, email: "create-envelope-owner@slock.test", password: "password123")
        accounts.markEmailVerified(userId: owner)
        accounts.oauth.addOwnedServer(id: server, slug: "create-envelope", name: "Create Envelope", ownerId: owner)
        actor = role == "owner" ? owner : UUID().uuidString.lowercased()
        if role != "owner" {
            accounts.addAccount(id: actor, email: "create-envelope-actor@slock.test", password: "password123")
            accounts.markEmailVerified(userId: actor)
            accounts.oauth.addMember(serverId: server, userId: actor, role: role)
        }
        var fields = HTTPFields()
        fields[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: actor))"
        fields[HTTPField.Name("X-Server-Id")!] = server
        fields[.contentType] = "application/json"
        headers = fields
    }
}

private let channelCreateRequiredFields: Set<String> = [
    "id", "serverId", "name", "description", "type", "guestVisible", "guestJoinable",
    "parentMessageId", "parentChannelId", "createdAt", "archivedAt", "archivedByUserId",
    "archivedByAgentId", "deletedAt", "joined", "jointChannelId", "jointRole", "jointPeerServerId",
    "jointPeerServerName", "jointPeerServerSlug", "jointPeerStatus", "jointServers", "jointPendingInvites",
    "jointBillingLocked", "channelRole", "channelAdminBasis", "channelCapabilities", "channelAuthorityRevision",
    "activityMuted", "muteFromSeq", "prefsVersion", "maxReadSeq", "readStateVersion", "readState",
    "activityMuteSupported", "jointInvites", "jointInvite",
]

private func channelCreateObject(_ response: ClientResponse) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: response.body.data ?? Data()) as? [String: Any])
}

/// channels.ts:1033-1067 spreads the complete created row, joint metadata,
/// channel authorization and read state. The v2 Node HTTP witness has 37 keys.
@Test(arguments: ["public-owner", "private-owner", "public-admin", "private-admin", "public-member", "private-member"])
func channelCreatePublishesTheCompletePinnedEnvelope(profile: String) async throws {
    let pieces = profile.split(separator: "-")
    let visibility = String(pieces[0])
    let role = String(pieces[1])
    let f = ChannelCreateContractAccounts(role: role)
    let selected = f.accounts.oauth.createAgent(serverId: f.server, name: "initial-agent")
    let payload = try JSONSerialization.data(withJSONObject: [
        "name": "complete-created-room", "visibility": visibility,
        "description": "complete create envelope", "agentIds": [selected],
    ])
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await client.send(.post, headers: f.headers, to: "/api/channels") { $0.body = .init(data: payload) }
            #expect(response.status == .ok)
            let body = try channelCreateObject(response)
            #expect(Set(body.keys) == channelCreateRequiredFields)
            #expect(body["serverId"] as? String == f.server)
            #expect(body["name"] as? String == "complete-created-room")
            #expect(body["description"] as? String == "complete create envelope")
            #expect(body["type"] as? String == (visibility == "private" ? "private" : "channel"))
            #expect(body["joined"] as? Bool == true)
            for key in ["guestVisible", "guestJoinable", "activityMuted"] { #expect(body[key] as? Bool == false) }
            #expect(body["activityMuteSupported"] as? Bool == true)
            for key in ["parentMessageId", "parentChannelId", "archivedAt", "archivedByUserId", "archivedByAgentId",
                        "deletedAt", "jointChannelId", "jointRole", "jointPeerServerId", "jointPeerServerName",
                        "jointPeerServerSlug", "jointPeerStatus", "jointBillingLocked", "muteFromSeq", "jointInvite"] {
                #expect(body[key] is NSNull)
            }
            for key in ["jointServers", "jointPendingInvites", "jointInvites"] { #expect((body[key] as? [Any])?.isEmpty == true) }
            for key in ["prefsVersion", "maxReadSeq", "readStateVersion"] { #expect(body[key] as? Int == 0) }
            #expect(body["readState"] as? [String: String] == ["kind": "absent"])
            #expect(body["channelRole"] as? String == "admin")
            #expect(body["channelAdminBasis"] as? String == (role == "member" ? "channel_role" : "both"))
            #expect(body["channelAuthorityRevision"] as? Int == 1)
            let expectedCapabilities: [String: Bool] = [
                "editChannelMetadata": true, "archiveChannels": true, "deleteChannels": role != "member",
                "changeChannelVisibility": role != "member", "manageGuestAccess": true,
                "federateChannels": role != "member", "addChannelMembers": true,
                "removeChannelMembers": true, "changeChannelMemberRoles": true,
            ]
            #expect(body["channelCapabilities"] as? [String: Bool] == expectedCapabilities)
            let id = try #require(body["id"] as? String)
            let createdAt = try #require(body["createdAt"] as? String)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            #expect(formatter.date(from: createdAt) != nil)
            let detail = try await client.get(URI(string: "/api/channels/\(id)"), headers: f.headers)
            #expect(detail.status == .ok)
            let detailed = try channelCreateObject(detail)
            #expect(detailed["createdAt"] as? String == createdAt)
            #expect(detailed["channelCapabilities"] as? [String: Bool] == expectedCapabilities)
            #expect(detailed["channelAdminBasis"] as? String == body["channelAdminBasis"] as? String)
            let listed = try await client.get("/api/channels", headers: f.headers)
            #expect(listed.status == .ok)
            let rows = try #require(try JSONSerialization.jsonObject(with: listed.body.data ?? Data()) as? [[String: Any]])
            let listedChannel = try #require(rows.first { $0["id"] as? String == id })
            #expect(listedChannel["channelCapabilities"] as? [String: Bool] == expectedCapabilities)
            #expect(listedChannel["channelAdminBasis"] as? String == body["channelAdminBasis"] as? String)
        }
    }
}

/// channels.ts:2501-2517 authorizes every requested field before mutation;
/// channelPermissions.ts:188-193 grants guest management to a current local admin.
@Test func channelCreatorCapabilitiesAuthorizeEachRequestedMutation() async throws {
    let f = ChannelCreateContractAccounts(role: "member")
    let other = UUID().uuidString.lowercased()
    f.accounts.addAccount(id: other, email: "ordinary-channel-member@slock.test", password: "password123")
    f.accounts.markEmailVerified(userId: other)
    f.accounts.oauth.addMember(serverId: f.server, userId: other, role: "member")
    var ordinary = f.headers
    ordinary[.authorization] = "Bearer \(f.accounts.mintAccessTokenForTesting(userId: other))"
    let ordinaryHeaders = ordinary
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let created = try await client.send(.post, headers: f.headers, to: "/api/channels") {
                $0.body = .init(string: #"{"name":"creator-managed","visibility":"public"}"#)
            }
            #expect(created.status == .ok)
            let body = try channelCreateObject(created)
            let id = try #require(body["id"] as? String)
            #expect((body["channelCapabilities"] as? [String: Bool])?["manageGuestAccess"] == true)
            let path = URI(string: "/api/channels/\(id)")
            let accepted = try await client.send(.patch, headers: f.headers, to: path) {
                $0.body = .init(string: #"{"guestVisible":true,"guestJoinable":true}"#)
            }
            #expect(accepted.status == .ok)
            #expect(try channelCreateObject(accepted)["guestVisible"] as? Bool == true)
            #expect(try channelCreateObject(accepted)["guestJoinable"] as? Bool == true)
            let rejected = try await client.send(.patch, headers: f.headers, to: path) {
                $0.body = .init(string: #"{"guestVisible":false,"visibility":"private"}"#)
            }
            #expect(rejected.status == .forbidden)
            #expect(rejected.body.string == #"{"error":"You do not have permission to update channels"}"#)
            let unchanged = try await client.send(.patch, headers: f.headers, to: path) {
                $0.body = .init(string: #"{"guestJoinable":true}"#)
            }
            #expect(unchanged.status == .ok)
            #expect(try channelCreateObject(unchanged)["guestVisible"] as? Bool == true)
            let detail = try await client.get(path, headers: f.headers)
            let detailBody = try channelCreateObject(detail)
            #expect(detailBody["type"] as? String == "channel")
            #expect((detailBody["channelCapabilities"] as? [String: Bool])?["manageGuestAccess"] == true)
            let outsider = try await client.send(.patch, headers: ordinaryHeaders, to: path) {
                $0.body = .init(string: #"{"guestVisible":false}"#)
            }
            #expect(outsider.status == .forbidden)
            #expect(outsider.body.string == #"{"error":"You do not have permission to update channels"}"#)
            let renamed = try await client.send(.patch, headers: f.headers, to: path) {
                $0.body = .init(string: #"{"name":"creator-renamed"}"#)
            }
            #expect(renamed.status == .ok)
            #expect(try channelCreateObject(renamed)["name"] as? String == "creator-renamed")
            #expect(try await client.delete(path, headers: f.headers).status == .forbidden)
        }
    }
}

/// readReceiptService.ts:133-164 adds exactly one conditional peer projection;
/// only Agent peers are exposed, with a summary above the 50-peer limit.
@Test(arguments: [0, 2, 51])
func channelCreateHydratesEnabledAgentReadReceipts(agentCount: Int) async throws {
    let f = ChannelCreateContractAccounts(role: "owner")
    f.accounts.createFeatureFlagForTesting(key: "read_receipts_v0", defaultEnabled: true)
    let agents = (0..<agentCount).map { f.accounts.oauth.createAgent(serverId: f.server, name: "peer-\($0)") }
    let payload = try JSONSerialization.data(withJSONObject: ["name": "receipt-created-room", "visibility": "private", "agentIds": agents])
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await client.send(.post, headers: f.headers, to: "/api/channels") { $0.body = .init(data: payload) }
            #expect(response.status == .ok)
            let body = try channelCreateObject(response)
            if agentCount > 50 {
                #expect(Set(body.keys) == channelCreateRequiredFields.union(["peerReadSummary"]))
                let summary = try #require(body["peerReadSummary"] as? [String: Any])
                #expect(Set(summary.keys) == ["peerCount", "readCountAtSeq"])
                #expect(summary["peerCount"] as? Int == agentCount)
                let buckets = try #require(summary["readCountAtSeq"] as? [[String: Int]])
                #expect(buckets == [["seq": 0, "count": agentCount]])
            } else {
                #expect(Set(body.keys) == channelCreateRequiredFields.union(["peerReadStates"]))
                let peers = try #require(body["peerReadStates"] as? [[String: Any]])
                #expect(Set(peers.compactMap { $0["peerId"] as? String }) == Set(agents))
                for peer in peers {
                    #expect(Set(peer.keys) == ["peerKind", "peerId", "maxReadSeq"])
                    #expect(peer["peerKind"] as? String == "agent")
                    #expect(peer["maxReadSeq"] as? Int == 0)
                }
            }
        }
    }
}
