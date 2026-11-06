import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func channelRoleAndCapabilitiesProjectOntoDetailAndRoster() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111508"
    let adminId = "11111111-1111-4111-8111-111111111509"
    let peerId = "11111111-1111-4111-8111-111111111510"
    let serverAdminId = "11111111-1111-4111-8111-111111111511"
    let outsiderId = "11111111-1111-4111-8111-111111111512"
    let inviteeId = "11111111-1111-4111-8111-111111111513"
    let serverId = "33333333-3333-4333-8333-333333333602"
    for (id, email) in [
        (ownerId, "role-owner@slock.test"),
        (adminId, "role-admin@slock.test"),
        (peerId, "role-peer@slock.test"),
        (serverAdminId, "role-server-admin@slock.test"),
        (outsiderId, "role-outsider@slock.test"),
        (inviteeId, "role-invitee@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "roles", name: "Roles", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: serverAdminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: inviteeId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "role-room", creatorUserId: ownerId, type: "private")
    for id in [ownerId, adminId, peerId, serverAdminId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "role-room")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    accounts.oauth.setChannelType(id: channel, type: "private")
    accounts.setChannelHumanRoleForTesting(channelId: channel, userId: adminId, role: "admin")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"role-admin@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            let ownerLogin = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"role-owner@slock.test\",\"password\":\"password123\"}")
            }
            let ownerToken = (try JSONSerialization.jsonObject(with: Data((ownerLogin.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            var ownerHeaders = headers
            ownerHeaders[.authorization] = "Bearer \(ownerToken)"
            let detail = try await client.send(.get, headers: headers, to: "/api/channels/\(channel)")
            #expect(detail.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((detail.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(body["channelRole"] as? String == "admin")
            #expect(body["channelAdminBasis"] as? String == "channel_role")
            #expect(body["channelAuthorityRevision"] as? Int == 1)
            let caps = body["channelCapabilities"] as? [String: Any] ?? [:]
            #expect(caps["editChannelMetadata"] as? Bool == true)
            #expect(caps["archiveChannels"] as? Bool == true)
            #expect(caps["addChannelMembers"] as? Bool == true)
            #expect(caps["changeChannelMemberRoles"] as? Bool == true)
            #expect(caps["deleteChannels"] as? Bool == false)
            #expect(caps["changeChannelVisibility"] as? Bool == false)
            #expect(caps["federateChannels"] as? Bool == false)

            let roster = try await client.send(.get, headers: headers, to: "/api/channels/\(channel)/members")
            let rosterBody = try JSONSerialization.jsonObject(with: Data((roster.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let humans = rosterBody["humans"] as? [[String: Any]] ?? []
            let serverAdmin = humans.first { $0["id"] as? String == serverAdminId }
            #expect(serverAdmin?["serverRole"] as? String == "admin")
            #expect(serverAdmin?["effectiveChannelRole"] as? String == "admin")
            #expect(serverAdmin?["channelAdminBasis"] as? String == "server_role")
            #expect(serverAdmin?["canChangeChannelRole"] as? Bool == false)
            let peer = humans.first { $0["id"] as? String == peerId }
            #expect(peer?["serverRole"] as? String == "member")
            #expect(peer?["effectiveChannelRole"] as? String == "member")
            #expect(peer?["channelAdminBasis"] == nil || peer?["channelAdminBasis"] is NSNull)
            #expect(peer?["canChangeChannelRole"] as? Bool == true)

            let promote = try await client.send(.patch, headers: headers, to: "/api/channels/\(channel)/members/user/\(peerId)/role") { request in
                request.body = .init(string: "{\"role\":\"admin\"}")
            }
            #expect(promote.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((promote.body.string ?? "").utf8)) as? [String: Any])?["authorityRevision"] as? Int == 2)

            let selfDemote = try await client.send(.patch, headers: headers, to: "/api/channels/\(channel)/members/user/\(adminId)/role") { request in
                request.body = .init(string: "{\"role\":\"member\"}")
            }
            #expect(selfDemote.status == .conflict)
            #expect((try JSONSerialization.jsonObject(with: Data((selfDemote.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "channel_admin_self_demote_forbidden")

            let protectedTarget = try await client.send(.patch, headers: headers, to: "/api/channels/\(channel)/members/user/\(serverAdminId)/role") { request in
                request.body = .init(string: "{\"role\":\"admin\"}")
            }
            #expect(protectedTarget.status == .forbidden)
            #expect((try JSONSerialization.jsonObject(with: Data((protectedTarget.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "protected_server_role")

            let rename = try await client.send(.patch, headers: headers, to: "/api/channels/\(channel)") { request in
                request.body = .init(string: "{\"description\":\"managed locally\"}")
            }
            #expect(rename.status == .ok)
            let visibility = try await client.send(.patch, headers: headers, to: "/api/channels/\(channel)") { request in
                request.body = .init(string: "{\"visibility\":\"public\"}")
            }
            #expect(visibility.status == .forbidden)
            #expect(try await client.send(.delete, headers: headers, to: "/api/channels/\(channel)").status == .forbidden)

            let outsiderHeaders = headers
            var outsiderFields = outsiderHeaders
            let outsiderLogin = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"role-outsider@slock.test\",\"password\":\"password123\"}")
            }
            let outsiderToken = (try JSONSerialization.jsonObject(with: Data((outsiderLogin.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            outsiderFields[.authorization] = "Bearer \(outsiderToken)"
            let outsiderAdd = try await client.send(.post, headers: outsiderFields, to: "/api/channels/\(channel)/members") { request in
                request.body = .init(string: "{\"userId\":\"\(inviteeId)\"}")
            }
            #expect(outsiderAdd.status == .notFound)
            let adminAdd = try await client.send(.post, headers: headers, to: "/api/channels/\(channel)/members") { request in
                request.body = .init(string: "{\"userId\":\"\(inviteeId)\"}")
            }
            #expect(adminAdd.status == .ok)
            #expect(accounts.oauth.channelHumanIds(channelId: channel).contains(inviteeId))

            #expect(try await client.send(.post, headers: headers, to: "/api/channels/\(channel)/archive").status == .ok)
            let archivedRole = try await client.send(.patch, headers: headers, to: "/api/channels/\(channel)/members/user/\(peerId)/role") { request in
                request.body = .init(string: "{\"role\":\"member\"}")
            }
            #expect(archivedRole.status == .conflict)
            #expect((try JSONSerialization.jsonObject(with: Data((archivedRole.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "channel_archived")

            let frozen: [(String, HTTPRequest.Method, String, String?)] = [
                ("rename", .patch, "/api/channels/\(channel)", "{\"description\":\"must stay frozen\"}"),
                ("add", .post, "/api/channels/\(channel)/members", "{\"userId\":\"\(peerId)\"}"),
                ("remove", .delete, "/api/channels/\(channel)/members/user/\(peerId)", nil),
                ("leave", .post, "/api/channels/\(channel)/leave", nil),
            ]
            for (_, method, path, body) in frozen {
                let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                #expect(response.status == .conflict)
                #expect((try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "channel_archived")
            }
        }
    }
}
