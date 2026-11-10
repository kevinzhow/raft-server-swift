import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

private struct ReadSecurityFixture {
    let accounts = EmailLoginDirectory()
    let server = UUID().uuidString.lowercased()
    let otherServer = UUID().uuidString.lowercased()
    let owner = UUID().uuidString.lowercased()
    let member = UUID().uuidString.lowercased()
    let guest = UUID().uuidString.lowercased()
    let outsider = UUID().uuidString.lowercased()

    init(guestEnabled: Bool = true) {
        for (id, name) in [(owner, "owner"), (member, "member"), (guest, "guest"), (outsider, "outsider")] {
            accounts.addAccount(id: id, email: "read-security-\(name)@example.test", password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: server, slug: "read-security-primary", name: "Read security", ownerId: owner)
        accounts.oauth.addOwnedServer(id: otherServer, slug: "read-security-other", name: "Other server", ownerId: outsider)
        accounts.oauth.addMember(serverId: server, userId: member, role: "member")
        accounts.oauth.addMember(serverId: server, userId: guest, role: "guest")
        if guestEnabled {
            accounts.createFeatureFlagForTesting(key: "server_guest_v0")
            accounts.addFeatureFlagRuleForTesting(key: "server_guest_v0", stage: "server", decision: "allow", values: [server])
        }
    }

    func headers(_ user: String, scope: String? = nil, omitScope: Bool = false) -> HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: user))"
        if !omitScope { headers[HTTPField.Name("X-Server-Id")!] = scope ?? server }
        return headers
    }

    func channel(_ name: String, kind: String = "channel", joined: Bool = false, visible: Bool = false) -> (id: String, message: String) {
        let id: String
        if name == "all", let existing = accounts.oauth.allChannelId(serverId: server) { id = existing }
        else { id = accounts.oauth.createChannel(serverId: server, name: name, creatorUserId: owner, type: kind) }
        accounts.addPostableChannel(serverId: server, channelId: id, memberId: owner, kind: kind, name: name)
        accounts.oauth.addChannelHuman(channelId: id, userId: owner)
        accounts.setChannelGuestVisibleForTesting(channelId: id, visible: visible)
        if joined {
            accounts.oauth.addChannelHuman(channelId: id, userId: guest)
            accounts.addPostableChannel(serverId: server, channelId: id, memberId: guest, kind: kind)
        }
        let message = accounts.addHumanMessageForTesting(channelId: id, senderId: owner, content: "read-security-secret-\(name)")
        return (id, message)
    }
}

private func readSecurityJSON(_ response: ClientResponse) throws -> Any {
    try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))
}

private func readSecurityPaths(_ channel: (id: String, message: String)) -> [String] {
    ["/api/messages/channel/\(channel.id)", "/api/messages/sync?channel_id=\(channel.id)",
     "/api/messages/context/\(channel.message)?channelId=\(channel.id)",
     "/api/messages/search?q=read-security&channelId=\(channel.id)"]
}

@Test func messageContextAndSearchRequireActualServerMembershipBeforeCatalogOrStoredRows() async throws {
    let f = ReadSecurityFixture()
    let channel = f.channel("scope")
    let catalogMessage = UUID().uuidString.lowercased()
    let catalog = MessageContextCatalog(messages: [.init(id: catalogMessage, channelId: channel.id, content: "private catalog sentinel", seq: 1)])
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, messageContext: catalog, emailAccounts: f.accounts))
        try await app.testing { client in
            for path in readSecurityPaths(channel) + ["/api/messages/context/\(catalogMessage)?channelId=\(channel.id)", "/api/messages/search?q=read-security"] {
                let response = try await client.get(URI(string: path), headers: f.headers(f.outsider))
                #expect(response.status == .forbidden)
                #expect(response.body.string == #"{"error":"Not a member of this server"}"#)
            }
            for path in ["/api/messages/context/\(channel.message)?channelId=\(channel.id)", "/api/messages/search?q=read-security"] {
                let missing = try await client.get(URI(string: path), headers: f.headers(f.member, omitScope: true))
                #expect(missing.status == .badRequest)
                #expect(missing.body.string == #"{"error":"Missing X-Server-Id header"}"#)
                let foreign = try await client.get(URI(string: path), headers: f.headers(f.outsider, scope: f.otherServer))
                let expectedStatus: HTTPResponse.Status = path.contains("search") ? .ok : .notFound
                #expect(foreign.status == expectedStatus)
                #expect(!(foreign.body.string ?? "").contains("read-security-secret"))
            }
            for path in readSecurityPaths(channel) {
                let regular = try await client.get(URI(string: path), headers: f.headers(f.member))
                #expect(regular.status == .ok)
                #expect((regular.body.string ?? "").contains("read-security-secret-scope"))
            }
            f.accounts.oauth.removeMember(serverId: f.server, userId: f.member)
            for path in readSecurityPaths(channel) {
                let removed = try await client.get(URI(string: path), headers: f.headers(f.member))
                #expect(removed.status == .forbidden)
                #expect(removed.body.string == #"{"error":"Not a member of this server"}"#)
            }
            f.accounts.oauth.deleteServer(id: f.server)
            let deleted = try await client.get(URI(string: "/api/messages/search?q=read-security"), headers: f.headers(f.owner))
            #expect(deleted.status == .forbidden)
            #expect(deleted.body.string == #"{"error":"Not a member of this server"}"#)
        }
    }
}

@Test func registeredGuestReadsUseActualRolloutVisibilityAndOAuthMembership() async throws {
    for enabled in [false, true] {
        let f = ReadSecurityFixture(guestEnabled: enabled)
        let cases = [
            (f.channel("hidden"), false, false), (f.channel("joined", joined: true), true, true),
            (f.channel("visible", visible: true), true, true), (f.channel("all", joined: true), false, false),
            (f.channel("private", kind: "private", joined: true), true, true),
            (f.channel("dm", kind: "dm", joined: true), true, false), (f.channel("stranger-private", kind: "private"), false, false),
        ]
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
            try await app.testing { client in
                for (channel, permitted, searchable) in cases {
                    for (index, path) in readSecurityPaths(channel).enumerated() {
                        let response = try await client.get(URI(string: path), headers: f.headers(f.guest))
                        if enabled && permitted {
                            #expect(response.status == .ok)
                            if index == 3 && !searchable {
                                let object = try #require(try readSecurityJSON(response) as? [String: Any])
                                #expect((object["results"] as? [[String: Any]])?.isEmpty == true)
                                #expect(!(response.body.string ?? "").contains("read-security-secret"))
                            } else { #expect((response.body.string ?? "").contains("read-security-secret")) }
                        } else {
                            #expect(response.status == .notFound)
                            let error = index < 2 ? "Channel not found or not visible" : (index == 2 ? "Message not found" : "Channel not found")
                            #expect(response.body.string == "{\"error\":\"\(error)\"}")
                        }
                    }
                }
                let searched = try await client.get("/api/messages/search?q=read-security", headers: f.headers(f.guest))
                #expect(searched.status == .ok)
                let searchObject = try #require(try readSecurityJSON(searched) as? [String: Any])
                let results = try #require(searchObject["results"] as? [[String: Any]])
                let expectedSearchIds = Set(cases.filter { enabled && $0.2 }.map { $0.0.message })
                #expect(Set(results.compactMap { $0["id"] as? String }) == expectedSearchIds)
                let all = cases[3].0
                f.accounts.setChannelGuestVisibleForTesting(channelId: all.id, visible: true)
                let visibleAll = try await client.get(URI(string: "/api/messages/channel/\(all.id)"), headers: f.headers(f.guest))
                #expect(visibleAll.status == (enabled ? .ok : .notFound))
                // A zero cursor is real prior relationship; membership alone was not.
                f.accounts.oauth.setChannelReadCursor(channelId: all.id, userId: f.guest, seq: 0)
                f.accounts.setChannelGuestVisibleForTesting(channelId: all.id, visible: false)
                for (path, error) in [("/api/messages/channel/\(all.id)", "You do not have access to this channel"),
                                      ("/api/messages/sync?channel_id=\(all.id)", "Access denied")] {
                    let known = try await client.get(URI(string: path), headers: f.headers(f.guest))
                    #expect(known.status == .forbidden)
                    #expect(known.body.string == "{\"error\":\"\(error)\"}")
                }
            }
        }
    }
}

@Test func aggregateGuestSyncKeepsItsDistinctAllAndPublicBroadcastRules() async throws {
    for enabled in [false, true] {
        let f = ReadSecurityFixture(guestEnabled: enabled)
        _ = f.channel("all", joined: true, visible: true)
        _ = f.channel("joined-hidden", joined: true)
        let visible = f.channel("visible-unjoined", visible: true)
        let privateChannel = f.channel("joined-private", kind: "private", joined: true)
        _ = f.channel("other-private", kind: "private")
        let dm = f.channel("joined-dm", kind: "dm", joined: true)
        let thread = UUID().uuidString.lowercased()
        f.accounts.addThreadChannel(serverId: f.server, threadChannelId: thread, parentChannelId: visible.id, parentMessageId: visible.message, memberId: f.owner)
        f.accounts.addThreadFollowForTesting(serverId: f.server, userId: f.guest, threadChannelId: thread, parentMessageId: visible.message)
        let reply = f.accounts.addHumanMessageForTesting(channelId: thread, senderId: f.owner, content: "aggregate thread reply")
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
            try await app.testing { client in
                let response = try await client.get("/api/messages/sync", headers: f.headers(f.guest))
                #expect(response.status == .ok)
                let rows = try #require(try readSecurityJSON(response) as? [[String: Any]])
                let ids = Set(rows.compactMap { $0["id"] as? String })
                let expected = enabled ? Set([visible.message, privateChannel.message, dm.message, reply]) : Set<String>()
                #expect(ids == expected)
            }
        }
    }
}

@Test func threadReadsFollowTheActualLiveParentMessageInsteadOfRetainedThreadMembership() async throws {
    let f = ReadSecurityFixture()
    let parent = f.channel("thread-public", visible: true)
    let privateParent = f.channel("thread-private", kind: "private")
    let thread = UUID().uuidString.lowercased()
    f.accounts.addThreadChannel(serverId: f.server, threadChannelId: thread, parentChannelId: parent.id, parentMessageId: parent.message, memberId: f.guest)
    f.accounts.oauth.addChannelHuman(channelId: thread, userId: f.guest)
    let reply = f.accounts.addHumanMessageForTesting(channelId: thread, senderId: f.owner, content: "read-security-secret-thread")
    let stale = UUID().uuidString.lowercased()
    f.accounts.addThreadChannel(serverId: f.server, threadChannelId: stale, parentChannelId: parent.id, parentMessageId: privateParent.message, memberId: f.member)
    let staleReply = f.accounts.addHumanMessageForTesting(channelId: stale, senderId: f.owner, content: "read-security-secret-stale-parent")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for path in readSecurityPaths((thread, reply)) {
                #expect(try await client.get(URI(string: path), headers: f.headers(f.guest)).status == .ok)
            }
            for path in readSecurityPaths((stale, staleReply)) {
                let denied = try await client.get(URI(string: path), headers: f.headers(f.member))
                #expect(denied.status == .notFound)
                #expect(!(denied.body.string ?? "").contains("read-security-secret"))
            }
            f.accounts.serversAndChannelsStore.markChannelDeleted(channelId: parent.id, now: Date())
            for path in readSecurityPaths((thread, reply)) {
                let denied = try await client.get(URI(string: path), headers: f.headers(f.guest))
                #expect(denied.status == .notFound)
                #expect(!(denied.body.string ?? "").contains("read-security-secret"))
            }
            let token = f.accounts.mintAccessTokenForTesting(userId: f.owner)
            let accountKey = try #require(f.accounts.authProfileStore.accounts.first { $0.value.id == f.owner }?.key)
            let removedAccount = f.accounts.authProfileStore.accounts.removeValue(forKey: accountKey)
            let removed = try #require(removedAccount)
            #expect(removed.id == f.owner)
            var headers = HTTPFields(); headers[.authorization] = "Bearer \(token)"; headers[HTTPField.Name("X-Server-Id")!] = f.server
            let retired = try await client.get("/api/messages/search?q=read-security", headers: headers)
            #expect(retired.status == .unauthorized)
        }
    }
}

@Test func messageReadDenialsKeepRouteSpecificValidationOrder() async throws {
    let f = ReadSecurityFixture()
    let hidden = f.channel("order-private", kind: "private")
    let visible = f.channel("order-readable", visible: true)
    let unknown = UUID().uuidString.lowercased()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for (id, error) in [(unknown, "Channel not found or not visible"), ("not-a-uuid", "Channel not found")] {
                let denied = try await client.get(URI(string: "/api/messages/channel/\(id)?before=bad"), headers: f.headers(f.guest))
                #expect(denied.status == .notFound)
                #expect(denied.body.string == "{\"error\":\"\(error)\"}")
            }
            for prior in [false, true] {
                if prior { f.accounts.oauth.setChannelReadCursor(channelId: hidden.id, userId: f.guest, seq: 0) }
                let page = try await client.get(URI(string: "/api/messages/channel/\(hidden.id)?before=bad"), headers: f.headers(f.guest))
                #expect(page.status == (prior ? .forbidden : .notFound))
                #expect(page.body.string == (prior ? #"{"error":"You do not have access to this channel"}"# : #"{"error":"Channel not found or not visible"}"#))
                let sync = try await client.get(URI(string: "/api/messages/sync?channel_id=\(hidden.id)&since_seq=bad"), headers: f.headers(f.guest))
                #expect(sync.status == .badRequest)
            }
            let context = try await client.get(URI(string: "/api/messages/context/not-a-uuid?channelId=\(hidden.id)"), headers: f.headers(f.guest))
            #expect(context.status == .badRequest)
            #expect(context.body.string == #"{"error":"Invalid message id"}"#)
            let search = try await client.get(URI(string: "/api/messages/search?channelId=\(hidden.id)&sort=bad"), headers: f.headers(f.guest))
            #expect(search.status == .notFound)
            #expect(search.body.string == #"{"error":"Channel not found"}"#)
            let readable = try await client.get(URI(string: "/api/messages/channel/\(visible.id)?before=bad"), headers: f.headers(f.guest))
            #expect(readable.status == .badRequest)
            f.accounts.markChannelDeleted(channelId: hidden.id)
            for path in ["/api/messages/channel/\(hidden.id)?before=bad", "/api/messages/sync?channel_id=\(hidden.id)&since_seq=0"] {
                let deleted = try await client.get(URI(string: path), headers: f.headers(f.guest))
                #expect(deleted.status == .notFound)
                #expect(deleted.body.string == #"{"error":"Channel not found or not visible"}"#)
            }
        }
    }
}

@Test func messageGuestReadRolloutUsesRetainedFlagsForTheActualServerAndUser() async throws {
    for scenario in ["missing", "disabled", "kill", "server-allow", "user-deny", "other-server", "default-allow", "user-allow"] {
        let f = ReadSecurityFixture(guestEnabled: false)
        let channel = f.channel("flag-visible", visible: true)
        let allowed = ["server-allow", "default-allow", "user-allow"].contains(scenario)
        // Deliberate contradiction: legacy set presence must never enable a
        // denied/missing flag; real flag allow must work without that set.
        if !allowed { f.accounts.enableGuestRoleTransitions(serverId: f.server) }
        if scenario != "missing" {
            f.accounts.createFeatureFlagForTesting(key: "server_guest_v0", defaultEnabled: ["disabled", "kill", "default-allow"].contains(scenario), enabled: scenario != "disabled", killSwitch: scenario == "kill")
        }
        switch scenario {
        case "server-allow", "user-deny":
            f.accounts.addFeatureFlagRuleForTesting(key: "server_guest_v0", stage: "server", decision: "allow", values: [f.server])
            if scenario == "user-deny" {
                f.accounts.addFeatureFlagRuleForTesting(key: "server_guest_v0", stage: "user", decision: "deny", values: [f.guest])
            }
        case "other-server":
            f.accounts.addFeatureFlagRuleForTesting(key: "server_guest_v0", stage: "server", decision: "allow", values: [f.otherServer])
        case "user-allow":
            f.accounts.addFeatureFlagRuleForTesting(key: "server_guest_v0", stage: "server", decision: "deny", values: [f.server])
            f.accounts.addFeatureFlagRuleForTesting(key: "server_guest_v0", stage: "user", decision: "allow", values: [f.guest])
        default: break
        }
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
            try await app.testing { client in
                for path in readSecurityPaths(channel) {
                    let response = try await client.get(URI(string: path), headers: f.headers(f.guest))
                    #expect(response.status == (allowed ? .ok : .notFound), "\(scenario): \(path)")
                    #expect((response.body.string ?? "").contains("read-security-secret-flag-visible") == allowed)
                }
                for path in ["/api/messages/search?q=read-security", "/api/messages/sync?since_seq=0"] {
                    let response = try await client.get(URI(string: path), headers: f.headers(f.guest))
                    #expect(response.status == .ok)
                    #expect((response.body.string ?? "").contains("read-security-secret-flag-visible") == allowed)
                }
            }
        }
    }
}

@Test func guestSearchExcludesJoinedDMRootsAndTheirThreadsWhileRegularSearchKeepsThem() async throws {
    let f = ReadSecurityFixture()
    let dm = f.channel("search-dm", kind: "dm", joined: true)
    f.accounts.oauth.addChannelHuman(channelId: dm.id, userId: f.member)
    let thread = UUID().uuidString.lowercased()
    f.accounts.addThreadChannel(serverId: f.server, threadChannelId: thread, parentChannelId: dm.id, parentMessageId: dm.message, memberId: f.owner)
    let reply = f.accounts.addHumanMessageForTesting(channelId: thread, senderId: f.owner, content: "read-security-dm-thread-sentinel")
    let scopes: [(id: String, message: String)] = [dm, (id: thread, message: reply)]
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for scope in scopes {
                for path in readSecurityPaths(scope).prefix(3) {
                    let leaf = try await client.get(URI(string: path), headers: f.headers(f.guest))
                    #expect(leaf.status == .ok)
                    #expect((leaf.body.string ?? "").contains("read-security"))
                }
                let searched = try await client.get(URI(string: "/api/messages/search?q=read-security&channelId=\(scope.id)"), headers: f.headers(f.guest))
                #expect(searched.status == .ok)
                let object = try #require(try readSecurityJSON(searched) as? [String: Any])
                #expect((object["results"] as? [[String: Any]])?.isEmpty == true)
                #expect(object["hasMore"] as? Bool == false)
            }
            for user in [f.guest, f.member] {
                let response = try await client.get("/api/messages/search?q=read-security", headers: f.headers(user))
                #expect(response.status == .ok)
                let object = try #require(try readSecurityJSON(response) as? [String: Any])
                let rows = try #require(object["results"] as? [[String: Any]])
                #expect(Set(rows.compactMap { $0["id"] as? String }) == (user == f.guest ? Set<String>() : Set([dm.message, reply])))
            }
            let regular = try await client.get(URI(string: "/api/messages/search?channelId=\(dm.id)&q=read-security"), headers: f.headers(f.member))
            let object = try #require(try readSecurityJSON(regular) as? [String: Any])
            let rows = try #require(object["results"] as? [[String: Any]])
            #expect(Set(rows.compactMap { $0["id"] as? String }) == Set([dm.message, reply]))
            #expect(rows.allSatisfy { $0["parentChannelId"] as? String == dm.id })
        }
    }
}

@Test func humanSearchKeepsLocalSQLScopesWithoutCanonicalOrJointExpansion() async throws {
    let f = ReadSecurityFixture()
    let ordinary = f.channel("search-local-public")
    let local = f.accounts.oauth.createChannel(serverId: f.server, name: "search-joint", creatorUserId: f.owner, type: "joint")
    f.accounts.addPostableChannel(serverId: f.server, channelId: local, memberId: f.owner, kind: "joint", name: "search-joint")
    f.accounts.oauth.addChannelHuman(channelId: local, userId: f.owner)
    let canonical = f.accounts.oauth.createChannel(serverId: f.otherServer, name: "foreign-search-storage", creatorUserId: f.outsider)
    f.accounts.addPostableChannel(serverId: f.otherServer, channelId: canonical, memberId: f.outsider, name: "foreign-search-storage")
    f.accounts.addJointChannelProjection(localChannelId: local, canonicalChannelId: canonical, serverId: f.server)
    _ = f.accounts.addHumanMessageForTesting(channelId: canonical, senderId: f.outsider, content: "read-security-foreign-canonical-sentinel")
    _ = f.accounts.addHumanMessageForTesting(channelId: local, senderId: f.owner, content: "read-security-local-joint-sentinel")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let unscoped = try await client.get("/api/messages/search?q=read-security", headers: f.headers(f.owner))
            #expect(unscoped.status == .ok)
            let object = try #require(try readSecurityJSON(unscoped) as? [String: Any])
            let rows = try #require(object["results"] as? [[String: Any]])
            #expect(rows.compactMap { $0["id"] as? String } == [ordinary.message])
            #expect(rows.allSatisfy { $0["channelId"] as? String == ordinary.id && $0["parentChannelId"] as? String == ordinary.id })
            #expect(!(unscoped.body.string ?? "").contains(canonical))
            #expect(!(unscoped.body.string ?? "").contains("joint-sentinel"))
            let scoped = try await client.get(URI(string: "/api/messages/search?q=read-security&channelId=\(local)"), headers: f.headers(f.owner))
            #expect(scoped.status == .ok)
            let scopedObject = try #require(try readSecurityJSON(scoped) as? [String: Any])
            #expect((scopedObject["results"] as? [[String: Any]])?.isEmpty == true)
        }
    }
}

@Test func contextCatalogAndStoredReadsPreserveUUIDCaseEquivalence() async throws {
    let f = ReadSecurityFixture()
    let channel = "aabbccdd-1111-4111-8111-000000180001"
    let stored = "bbccddee-1111-4111-8111-000000180001"
    let catalogId = "ccddeeff-1111-4111-8111-000000180001"
    f.accounts.addPostableChannel(serverId: f.server, channelId: channel, memberId: f.owner, name: "case-fold-context")
    f.accounts.insertHumanMessage(id: stored, channelId: channel, senderId: f.owner, content: "stored-case-fold-sentinel")
    let catalog = MessageContextCatalog(messages: [.init(id: catalogId, channelId: channel, content: "catalog-case-fold-sentinel", seq: 1)])
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, messageContext: catalog, emailAccounts: f.accounts))
        try await app.testing { client in
            for (id, sentinel) in [(stored, "stored-case-fold-sentinel"), (catalogId, "catalog-case-fold-sentinel")] {
                for target in [id.uppercased(), String(id.prefix(8)).uppercased()] {
                    let path = URI(string: "/api/messages/context/\(target)?channelId=\(channel.uppercased())")
                    let response = try await client.get(path, headers: f.headers(f.member))
                    #expect(response.status == .ok)
                    #expect((response.body.string ?? "").contains(sentinel))
                    let foreign = try await client.get(path, headers: f.headers(f.outsider, scope: f.otherServer))
                    #expect(foreign.status == .notFound)
                    #expect(!(foreign.body.string ?? "").contains(sentinel))
                }
            }
        }
    }
}

@Test func catalogContextNeverReturnsCoordinatesDifferentFromTheCurrentStoredMessage() async throws {
    let f = ReadSecurityFixture()
    let current = f.channel("current-public-context")
    let stale = f.channel("stale-private-context", kind: "private")
    let catalog = MessageContextCatalog(messages: [.init(id: current.message, channelId: stale.id, content: "stale-private-catalog-sentinel", seq: 1)])
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, messageContext: catalog, emailAccounts: f.accounts))
        try await app.testing { client in
            // The member reads only A; even the owner who reads both cannot use
            // stale catalog B to override the current stored coordinate A.
            for user in [f.member, f.owner] {
                for suffix in ["", "?channelId=\(stale.id)"] {
                    let response = try await client.get(URI(string: "/api/messages/context/\(current.message)\(suffix)"), headers: f.headers(user))
                    #expect(response.status == .notFound)
                    #expect(response.body.string == #"{"error":"Message not found"}"#)
                    #expect(!(response.body.string ?? "").contains("stale-private-catalog-sentinel"))
                }
            }
            let actual = try await client.get(URI(string: "/api/messages/context/\(current.message)?channelId=\(current.id)"), headers: f.headers(f.member))
            #expect(actual.status == .ok)
            #expect((actual.body.string ?? "").contains("read-security-secret-current-public-context"))
            #expect(!(actual.body.string ?? "").contains("stale-private-catalog-sentinel"))
        }
    }
}
