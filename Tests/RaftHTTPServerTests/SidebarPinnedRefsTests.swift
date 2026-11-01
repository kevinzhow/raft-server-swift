import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func sidebarTypedPinsCanonicalizeDmsAndPreserveLegacyFields() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111689"
    let peerId = "11111111-1111-4111-8111-111111111690"
    let serverId = "33333333-3333-4333-8333-333333333701"
    accounts.addAccount(id: ownerId, email: "typed-pins@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "typed-pins-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "typed-pins", name: "Typed Pins", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "typed-pinned-channel", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let hidden = accounts.oauth.createChannel(serverId: serverId, name: "typed-pinned-hidden", creatorUserId: ownerId, type: "private")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "typed-pinned-agent")
    let humanDM = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: peerId)

    let eventBox = PinnedEventBox()
    accounts.realtimeEmitter = { room, event, payload in
        eventBox.append(room: room, event: event, payload: payload)
    }

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
                request.body = .init(string: "{\"email\":\"typed-pins@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func patch(_ body: String) async throws -> (ClientResponse, [String: Any]) {
                let response = try await client.send(.patch, headers: headers, to: "/api/servers/\(serverId)/sidebar-order") { request in
                    request.body = .init(string: body)
                }
                let object = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]) ?? [:]
                return (response, object)
            }

            let mixed = try await patch("{\"pinned\":[{\"kind\":\"channel\",\"id\":\"\(channel)\"}],\"pinnedChannelIds\":[\"\(channel)\"]}")
            #expect(mixed.0.status == .badRequest)
            let bogus = try await patch("{\"pinned\":[{\"kind\":\"bogus\",\"id\":\"\(channel)\"}]}")
            #expect(bogus.0.status == .badRequest)

            let update = try await patch("""
            {"pinned":[
              {"kind":"human","id":"\(peerId)"},
              {"kind":"channel","id":"\(humanDM)"},
              {"kind":"channel","id":"\(channel)"},
              {"kind":"channel","id":"\(hidden)"},
              {"kind":"agent","id":"\(agent)"},
              {"kind":"human","id":"11111111-1111-4111-8111-111111111999"}
            ]}
            """)
            #expect(update.0.status == .ok)
            let pinned = update.1["pinned"] as? [[String: Any]] ?? []
            #expect(pinned.map { $0["kind"] as? String } == ["human", "channel", "agent"])
            #expect(pinned.map { $0["id"] as? String } == [peerId, channel, agent])
            #expect(update.1["pinnedChannelIds"] as? [String] == [humanDM, channel])
            #expect(update.1["pinnedAgentIds"] as? [String] == [agent])
            #expect(update.1["pinnedOrder"] as? [String] == [humanDM, channel, agent])
            #expect(update.1["pinnedVersion"] as? Int == 1)
            let updateEvent = eventBox.events.last
            #expect(updateEvent?.room == "user:\(ownerId)")
            #expect(updateEvent?.event == "pinned:updated")
            #expect(updateEvent?.payload?.contains("\"pinnedVersion\":1") == true)
            #expect(updateEvent?.payload?.contains(peerId) == true)

            let noOp = try await patch("""
            {"pinned":[{"kind":"human","id":"\(peerId)"},{"kind":"channel","id":"\(channel)"},{"kind":"agent","id":"\(agent)"}]}
            """)
            #expect(noOp.0.status == .ok)
            #expect(noOp.1["pinnedVersion"] as? Int == 1)
            let noOpPinned = noOp.1["pinned"] as? [[String: Any]] ?? []
            let updatePinned = update.1["pinned"] as? [[String: Any]] ?? []
            #expect(noOpPinned.map { $0["id"] as? String } == updatePinned.map { $0["id"] as? String })
            #expect(eventBox.events.count == 1)

            let get = try await client.send(.get, headers: headers, to: "/api/servers/\(serverId)/sidebar-order")
            let getBody = try JSONSerialization.jsonObject(with: Data((get.body.string ?? "").utf8)) as? [String: Any]
            #expect(getBody?["pinnedVersion"] as? Int == 1)
            #expect(getBody?["pinnedOrder"] as? [String] == [humanDM, channel, agent])
        }
    }
}

private final class PinnedEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(room: String, event: String, payload: String?)] = []

    func append(room: String, event: String, payload: String?) {
        lock.lock()
        storage.append((room, event, payload))
        lock.unlock()
    }

    var events: [(room: String, event: String, payload: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
