import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

private func allTypeSearchObject(_ response: ClientResponse) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
}

@Test func searchUsesCurrentAllTypeAcrossPublishedServerCreateHideAndRestore() async throws {
    let accounts = EmailLoginDirectory()
    let owner = UUID().uuidString.lowercased()
    let member = UUID().uuidString.lowercased()
    let participant = UUID().uuidString.lowercased()
    for (id, name) in [(owner, "owner"), (member, "member"), (participant, "participant")] {
        accounts.addAccount(id: id, email: "all-type-\(name)@example.test", password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    let ownerToken = accounts.mintAccessTokenForTesting(userId: owner)
    let memberToken = accounts.mintAccessTokenForTesting(userId: member)
    let participantToken = accounts.mintAccessTokenForTesting(userId: participant)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var createHeaders = HTTPFields()
            createHeaders[.authorization] = "Bearer \(ownerToken)"
            createHeaders[.contentType] = "application/json"
            // This production path materializes the implicit public #all row.
            let created = try await client.send(.post, headers: createHeaders, to: "/api/servers") { request in
                request.body = .init(string: "{\"name\":\"All type search\",\"slug\":\"all-type-search\"}")
            }
            #expect(created.status == .ok)
            let object = try allTypeSearchObject(created)
            let server = try #require(object["id"] as? String)
            let all = try #require(accounts.oauth.allChannelId(serverId: server))
            accounts.oauth.addMember(serverId: server, userId: member, role: "member")
            accounts.oauth.addMember(serverId: server, userId: participant, role: "member")
            accounts.oauth.addChannelHuman(channelId: all, userId: participant)
            let rootMessage = accounts.addHumanMessageForTesting(channelId: all, senderId: owner, content: "alltypecontract all-root-private-sentinel")
            let thread = UUID().uuidString.lowercased()
            accounts.addThreadChannel(serverId: server, threadChannelId: thread, parentChannelId: all, parentMessageId: rootMessage, memberId: owner)
            for actor in [owner, member, participant] {
                accounts.addThreadFollowForTesting(serverId: server, userId: actor, threadChannelId: thread, parentMessageId: rootMessage)
            }
            let threadMessage = accounts.addHumanMessageForTesting(channelId: thread, senderId: owner, content: "alltypecontract all-thread-private-sentinel")
            let ordinary = accounts.oauth.createChannel(serverId: server, name: "public-control", creatorUserId: owner)
            accounts.addPostableChannel(serverId: server, channelId: ordinary, memberId: owner, name: "public-control")
            let publicMessage = accounts.addHumanMessageForTesting(channelId: ordinary, senderId: owner, content: "alltypecontract public-control-sentinel")
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[HTTPField.Name("X-Server-Id")!] = server
                return fields
            }
            func search(_ token: String) async throws -> ClientResponse {
                try await client.get("/api/messages/search?q=alltypecontract", headers: headers(token))
            }
            func ids(_ response: ClientResponse) throws -> Set<String> {
                let rows = try #require(try allTypeSearchObject(response)["results"] as? [[String: Any]])
                return Set(rows.compactMap { $0["id"] as? String })
            }
            func types(_ response: ClientResponse, allType: String) throws {
                let rows = try #require(try allTypeSearchObject(response)["results"] as? [[String: Any]])
                let root = try #require(rows.first { $0["id"] as? String == rootMessage })
                let reply = try #require(rows.first { $0["id"] as? String == threadMessage })
                let control = try #require(rows.first { $0["id"] as? String == publicMessage })
                #expect(root["channelType"] as? String == allType)
                #expect(root["parentChannelType"] as? String == allType)
                #expect(reply["channelType"] as? String == "thread")
                #expect(reply["parentChannelType"] as? String == allType)
                #expect(control["channelType"] as? String == "channel")
                #expect(control["parentChannelType"] as? String == "channel")
            }
            func aggregate(_ expected: Set<String>) async throws {
                for token in [memberToken, participantToken, ownerToken] {
                    let response = try await client.get("/api/messages/sync?since_seq=0", headers: headers(token))
                    #expect(response.status == .ok)
                    let rows = try #require(try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]])
                    #expect(Set(rows.compactMap { $0["id"] as? String }) == expected)
                }
            }
            let before = try await search(memberToken)
            #expect(before.status == .ok)
            #expect(try ids(before) == Set([rootMessage, threadMessage, publicMessage]))
            try types(before, allType: "channel")
            try await aggregate(Set([rootMessage, threadMessage, publicMessage]))
            let hidden = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/system/all/hide")
            #expect(hidden.status == .ok)
            #expect(try allTypeSearchObject(hidden)["visible"] as? Bool == false)
            let unjoined = try await search(memberToken)
            #expect(unjoined.status == .ok)
            #expect(try ids(unjoined) == Set([publicMessage]))
            #expect(!(unjoined.body.string ?? "").contains("all-root-private-sentinel"))
            #expect(!(unjoined.body.string ?? "").contains("all-thread-private-sentinel"))
            // Search's private-participant branch remains distinct from scoped
            // #all leaf denial, including ordinary threads under that root.
            let joined = try await search(participantToken)
            #expect(joined.status == .ok)
            #expect(try ids(joined) == Set([rootMessage, threadMessage, publicMessage]))
            try types(joined, allType: "private")
            try await aggregate(Set([publicMessage]))
            for token in [memberToken, participantToken, ownerToken] {
                for (message, channel) in [(rootMessage, all), (threadMessage, thread)] {
                    let context = try await client.get(URI(string: "/api/messages/context/\(message)?channelId=\(channel)"), headers: headers(token))
                    #expect(context.status == .notFound)
                    #expect(!(context.body.string ?? "").contains("private-sentinel"))
                }
            }
            let restored = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/system/all/restore")
            #expect(restored.status == .ok)
            #expect(try allTypeSearchObject(restored)["visible"] as? Bool == true)
            let visibleAgain = try await search(memberToken)
            #expect(visibleAgain.status == .ok)
            #expect(try ids(visibleAgain) == Set([rootMessage, threadMessage, publicMessage]))
            try types(visibleAgain, allType: "channel")
            try await aggregate(Set([rootMessage, threadMessage, publicMessage]))
        }
    }
}
