import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelDisplayPrefsRequireChannelMembershipExceptForAll() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111286"
    let memberId = "11111111-1111-4111-8111-111111111287"
    let outsiderId = "11111111-1111-4111-8111-111111111288"
    let serverId = "33333333-3333-4333-8333-333333333471"
    for (id, email) in [
        (ownerId, "display-owner@slock.test"),
        (memberId, "display-member@slock.test"),
        (outsiderId, "display-outsider@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "channel-display", name: "Channel Display Settings", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "display-target", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: memberId)
    let allChannelId = accounts.oauth.allChannelId(serverId: serverId) ?? ""

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let memberToken = try await login("display-member@slock.test")
            let outsiderToken = try await login("display-outsider@slock.test")

            let initial = try await client.send(.get, headers: headers(memberToken), to: "/api/channels/\(channelId)/message-display-settings")
            #expect(initial.status == .ok)
            let initialBody = try JSONSerialization.jsonObject(with: Data((initial.body.string ?? "").utf8)) as? [String: Any]
            #expect(initialBody?["collapseLongMessages"] as? Bool == true)
            #expect(initialBody?["prefsVersion"] as? Int == 0)

            let invalid = try await client.send(.patch, headers: headers(memberToken), to: "/api/channels/\(channelId)/message-display-settings") { request in
                request.body = .init(string: "{\"collapseLongMessages\":\"no\"}")
            }
            #expect(invalid.status == .badRequest)

            let unjoined = try await client.send(.get, headers: headers(outsiderToken), to: "/api/channels/\(channelId)/message-display-settings")
            #expect(unjoined.status == .notFound)

            let allGet = try await client.send(.get, headers: headers(outsiderToken), to: "/api/channels/\(allChannelId)/message-display-settings")
            #expect(allGet.status == .ok)
            let allPatch = try await client.send(.patch, headers: headers(outsiderToken), to: "/api/channels/\(allChannelId)/message-display-settings") { request in
                request.body = .init(string: "{\"collapseLongMessages\":false}")
            }
            #expect(allPatch.status == .ok)
            let allBody = try JSONSerialization.jsonObject(with: Data((allPatch.body.string ?? "").utf8)) as? [String: Any]
            #expect(allBody?["collapseLongMessages"] as? Bool == false)
            #expect(allBody?["prefsVersion"] as? Int == 1)
        }
    }
}

@Test func channelDisplayPrefsBumpOnlyOnChangeAndRejectThreadTargets() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111110286"
    let memberId = "11111111-1111-4111-8111-111111110287"
    let serverId = "33333333-3333-4333-8333-333333330471"
    for (id, email) in [
        (ownerId, "display-bump-owner@slock.test"),
        (memberId, "display-bump-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "display-bump", name: "Display Bump", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "display-bump-target", creatorUserId: ownerId)
    for id in [ownerId, memberId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: id, name: "display-bump-target")
        accounts.oauth.addChannelHuman(channelId: channelId, userId: id)
    }
    let privateChannelId = accounts.oauth.createChannel(serverId: serverId, name: "display-bump-private", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannelId, memberId: ownerId, kind: "private", name: "display-bump-private")
    accounts.oauth.addChannelHuman(channelId: privateChannelId, userId: ownerId)
    let parent = UUID().uuidString.lowercased()
    accounts.insertHumanMessage(id: parent, channelId: channelId, senderId: ownerId, content: "display bump thread parent")
    let threadId = accounts.oauth.createThreadChannel(parentChannelId: channelId, parentMessageId: parent)
    accounts.addPostableChannel(
        serverId: serverId,
        channelId: threadId,
        memberId: ownerId,
        kind: "thread",
        parentChannelId: channelId,
        parentMessageId: parent,
        name: "thread"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let memberToken = try await login("display-bump-member@slock.test")
            let ownerToken = try await login("display-bump-owner@slock.test")
            func patch(_ token: String, _ body: String, _ channel: String = channelId) async throws -> (HTTPResponse.Status, [String: Any]) {
                let response = try await client.send(.patch, headers: headers(token), to: "/api/channels/\(channel)/message-display-settings") { request in
                    request.body = .init(string: body)
                }
                return (response.status, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }

            let disabled = try await patch(memberToken, "{\"collapseLongMessages\":false}")
            #expect(disabled.0 == .ok)
            #expect(disabled.1["prefsVersion"] as? Int == 1)
            let repeated = try await patch(memberToken, "{\"collapseLongMessages\":false}")
            #expect(repeated.1["prefsVersion"] as? Int == 1, "a same-value patch must not bump the version")
            let reenabled = try await patch(memberToken, "{\"collapseLongMessages\":true}")
            #expect(reenabled.1["prefsVersion"] as? Int == 2)

            let privateGetResponse = try await client.send(.get, headers: headers(memberToken), to: "/api/channels/\(privateChannelId)/message-display-settings")
            #expect(privateGetResponse.status == .notFound)
            let privatePatchEmpty = try await patch(memberToken, "{}", privateChannelId)
            #expect(privatePatchEmpty.0 == .notFound, "non-member private display prefs are cloaked before validation")
            let privatePatchValid = try await patch(memberToken, "{\"collapseLongMessages\":false}", privateChannelId)
            #expect(privatePatchValid.0 == .notFound)

            let threadTarget = try await patch(ownerToken, "{\"collapseLongMessages\":false}", threadId)
            #expect(threadTarget.0 == .badRequest)
            #expect((threadTarget.1["error"] as? String)?.contains("parent channel") == true)

            let ownerSettings = try await client.send(.get, headers: headers(ownerToken), to: "/api/channels/\(channelId)/message-display-settings")
            let ownerBody = try JSONSerialization.jsonObject(with: Data((ownerSettings.body.string ?? "").utf8)) as? [String: Any]
            #expect(ownerBody?["prefsVersion"] as? Int == 0, "display prefs stay per user")
        }
    }
}

@Test func channelDisplayPrefsProjectOntoTheListAndDetail() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111110386"
    let memberId = "11111111-1111-4111-8111-111111110387"
    let serverId = "33333333-3333-4333-8333-333333330472"
    for (id, email) in [
        (ownerId, "display-proj-owner@slock.test"),
        (memberId, "display-proj-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "display-proj", name: "Display Projection", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "display-proj-target", creatorUserId: ownerId)
    for id in [ownerId, memberId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: id, name: "display-proj-target")
        accounts.oauth.addChannelHuman(channelId: channelId, userId: id)
    }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let memberToken = try await login("display-proj-member@slock.test")
            let patched = try await client.send(.patch, headers: headers(memberToken), to: "/api/channels/\(channelId)/message-display-settings") { request in
                request.body = .init(string: "{\"collapseLongMessages\":false}")
            }
            #expect(patched.status == .ok)

            let listResponse = try await client.send(.get, headers: headers(memberToken), to: "/api/channels")
            #expect(listResponse.status == .ok)
            let list = (try? JSONSerialization.jsonObject(with: Data((listResponse.body.string ?? "").utf8))) as? [[String: Any]] ?? []
            let row = list.first { $0["id"] as? String == channelId }
            #expect(row?["collapseLongMessages"] as? Bool == false)
            #expect(row?["displayPrefsVersion"] as? Int == 1)

            let detailResponse = try await client.send(.get, headers: headers(memberToken), to: "/api/channels/\(channelId)")
            #expect(detailResponse.status == .ok)
            let detail = (try? JSONSerialization.jsonObject(with: Data((detailResponse.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(detail["collapseLongMessages"] as? Bool == false)
            #expect(detail["displayPrefsVersion"] as? Int == 1)
        }
    }
}
