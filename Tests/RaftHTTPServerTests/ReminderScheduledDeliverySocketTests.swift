import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import RaftRealtime
import Testing
import TestSupport
import Vapor
import VaporTesting

enum ReminderEntry: String, CaseIterable, Sendable {
    case machine, agent

    func path(agentId: String) -> String {
        switch self {
        case .machine: "/internal/agent/\(agentId)/reminders"
        case .agent: "/internal/agent-api/reminders"
        }
    }
}

private struct ReminderSocketAuth: RealtimeAuthorizing {
    let auth: AuthCoreService
    let membership: SocketMembershipService

    func userId(forAccessToken token: String) -> String? {
        auth.sessionIdentity(accessToken: token)?.userId
    }
    func sessionFamilyId(forAccessToken token: String) -> String? {
        auth.sessionIdentity(accessToken: token)?.familyId
    }
    func serverRole(serverId: String, userId: String) -> String? {
        membership.serverRole(serverId: serverId, userId: userId)
    }
    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        membership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }
    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String? {
        membership.syncMessages(serverId: serverId, userId: userId, lastSeq: lastSeq, limit: limit)?.jsonBody()
    }
}

private struct ReminderWireFixture: Sendable {
    let accounts = EmailLoginDirectory()
    let serverId = UUID().uuidString.lowercased()
    let otherServerId = UUID().uuidString.lowercased()
    let ownerId = UUID().uuidString.lowercased()
    let adminId = UUID().uuidString.lowercased()
    let creatorId = UUID().uuidString.lowercased()
    let memberId = UUID().uuidString.lowercased()
    let guestId = UUID().uuidString.lowercased()
    let otherOwnerId = UUID().uuidString.lowercased()
    let agentId: String
    let externalAgentId: String
    let machineKey: String
    let otherMachineKey: String
    let agentKey: String
    let readOnlyKey: String
    let externalKey: String

    init(creatorIsAdmin: Bool = false) throws {
        for userId in [ownerId, adminId, creatorId, memberId, guestId, otherOwnerId] {
            accounts.addAccount(id: userId, email: "\(userId)@reminder-wire.test", password: "password123")
            accounts.markEmailVerified(userId: userId)
        }
        accounts.oauth.addOwnedServer(id: serverId, slug: "reminder-wire", name: "Reminder Wire", ownerId: ownerId)
        accounts.oauth.addOwnedServer(id: otherServerId, slug: "other-reminder-wire", name: "Other Server", ownerId: otherOwnerId)
        for (userId, role) in [(adminId, "admin"), (creatorId, creatorIsAdmin ? "admin" : "member"), (memberId, "member"), (guestId, "guest")] {
            accounts.oauth.addMember(serverId: serverId, userId: userId, role: role)
        }
        let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "reminder-writer")
        machineKey = try #require(accounts.machineAPIKey(machineId: machineId))
        let otherMachine = accounts.registerMachine(serverId: otherServerId, userId: otherOwnerId, name: "other-writer")
        otherMachineKey = try #require(accounts.machineAPIKey(machineId: otherMachine))
        agentId = accounts.oauth.createAgent(serverId: serverId, name: "wire-agent", creatorUserId: creatorId, runtime: "claude")
        externalAgentId = accounts.oauth.createAgent(serverId: serverId, name: "external-wire-agent", creatorUserId: creatorId, runtime: "external")
        agentKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "tasks"], name: "wire-tasks")
        readOnlyKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "wire-read")
        externalKey = accounts.mintAgentCredential(agentId: externalAgentId, scopes: ["read", "tasks"], name: "external-tasks")
    }

    var auth: ReminderSocketAuth {
        ReminderSocketAuth(auth: accounts.authCore, membership: accounts.socketMembership)
    }
    func headers(_ entry: ReminderEntry) -> HTTPFields {
        headers(key: entry == .machine ? machineKey : agentKey)
    }
    func headers(key: String?) -> HTTPFields {
        var value = HTTPFields()
        value[.contentType] = "application/json"
        if let key { value[.authorization] = "Bearer \(key)" }
        return value
    }
}

private struct ReminderObserver {
    let userId: String
    let client: SocketIOTestClient
    var startIndex: Int
}

private func observeReminderUser(_ fixture: ReminderWireFixture, realtime: RealtimeServer, userId: String, serverId: String) async throws -> ReminderObserver {
    let client = try await SocketIOTestClient(port: realtime.port)
    _ = try #require(await client.waitForText { $0.hasPrefix("0") })
    let token = fixture.accounts.mintAccessTokenForTesting(userId: userId)
    client.send("40{\"token\":\"\(token)\",\"serverId\":\"\(serverId)\"}")
    _ = try #require(await client.waitForText { $0 == "42[\"rooms:joined\"]" })
    return ReminderObserver(userId: userId, client: client, startIndex: client.textFrames.count)
}

/// The fence is a real Socket.IO frame on the same session queues. There is no
/// producer-side recorder: every assertion below observes RFC6455 network data.
private func reminderFramesThroughFence(_ observers: [ReminderObserver], hub: RealtimeHub) async throws -> [[String]] {
    let nonce = UUID().uuidString.lowercased()
    let fence = "42[\"test:reminder-fence\",{\"nonce\":\"\(nonce)\"}]"
    for userId in Set(observers.map(\.userId)) {
        hub.emit(room: "user:\(userId)", event: "test:reminder-fence", payloadJSON: "{\"nonce\":\"\(nonce)\"}")
    }
    var result: [[String]] = []
    for observer in observers {
        _ = try #require(await observer.client.waitForText { $0 == fence })
        let frames = observer.client.textFrames
        let end = try #require(frames.indices.first { $0 >= observer.startIndex && frames[$0] == fence })
        result.append(Array(frames[observer.startIndex..<end].filter { $0.hasPrefix("42") }))
    }
    return result
}

private func reminderIdAndAssertResponse(_ body: String, title: String) throws -> String {
    let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    let reminder = try #require(object["reminder"] as? [String: Any])
    let id = try #require(reminder["id"] as? String)
    #expect(body == "{\"reminder\":{\"id\":\"\(id)\",\"reminderId\":\"\(id)\",\"ownerAgentId\":null,\"status\":\"scheduled\",\"version\":1,\"title\":\"\(title)\",\"fireAt\":null}}")
    return id
}

private func reminderExpectedFrame(id: String, agentId: String) -> String {
    "42[\"reminder:scheduled\",{\"reminderId\":\"\(id)\",\"ownerAgentId\":\"\(agentId)\"}]"
}

@Suite(.serialized)
struct ReminderScheduledDeliverySocketTests {
    @Test(arguments: ReminderEntry.allCases, [false, true])
    func bothPostRoutesDeliverExactlyOnceToCreatorAndServerAuthorities(entry: ReminderEntry, creatorIsAdmin: Bool) async throws {
        let fixture = try ReminderWireFixture(creatorIsAdmin: creatorIsAdmin)
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        var observers: [ReminderObserver] = []
        defer {
            for observer in observers { observer.client.close() }
            Task { try? await realtime.close() }
        }
        for userId in [fixture.ownerId, fixture.adminId, fixture.creatorId, fixture.creatorId, fixture.memberId, fixture.guestId, fixture.otherOwnerId] {
            observers.append(try await observeReminderUser(fixture, realtime: realtime, userId: userId, serverId: userId == fixture.otherOwnerId ? fixture.otherServerId : fixture.serverId))
        }
        // No relay is installed: the existing route's fixed Fallback Hub owns
        // this delivery, independently of the root's replaceable emitter slot.
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts, realtime: realtime.hub))
            try await app.testing { client in
                let response = try await client.send(.post, headers: fixture.headers(entry), to: URI(string: entry.path(agentId: fixture.agentId))) {
                    $0.body = .init(string: "{\"title\":\"Wire reminder\",\"msgId\":\"source-message\",\"delaySeconds\":3600}")
                }
                #expect(response.status == .ok)
                let id = try reminderIdAndAssertResponse(response.body.string ?? "", title: "Wire reminder")
                let expected = reminderExpectedFrame(id: id, agentId: fixture.agentId)
                let recipientIds: Set<String> = [fixture.ownerId, fixture.adminId, fixture.creatorId]
                let windows = try await reminderFramesThroughFence(observers, hub: realtime.hub)
                for (observer, frames) in zip(observers, windows) {
                    #expect(frames == (recipientIds.contains(observer.userId) ? [expected] : []))
                }
                let list = try await client.get(URI(string: entry.path(agentId: fixture.agentId)), headers: fixture.headers(entry))
                #expect(list.status == .ok)
                #expect(list.body.string?.contains(id) == true)
            }
        }
    }

    @Test(arguments: ReminderEntry.allCases, [false, true])
    func optionalFallbackHubAndReplacementRelayStayIndependent(entry: ReminderEntry, hasFallbackHub: Bool) async throws {
        let fixture = try ReminderWireFixture()
        let fixed = try await RealtimeServer.start(auth: fixture.auth)
        let replacement = try await RealtimeServer.start(auth: fixture.auth)
        let fixedObserver = try await observeReminderUser(fixture, realtime: fixed, userId: fixture.ownerId, serverId: fixture.serverId)
        let replacementObserver = try await observeReminderUser(fixture, realtime: replacement, userId: fixture.ownerId, serverId: fixture.serverId)
        defer {
            fixedObserver.client.close()
            replacementObserver.client.close()
            Task { try? await fixed.close(); try? await replacement.close() }
        }
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts, realtime: hasFallbackHub ? fixed.hub : nil))
            // Install AFTER route registration, like a replacement of an
            // existing live connection sink. It is a real second Hub, no spy.
            let replacementHub = replacement.hub
            fixture.accounts.realtimeRelay.install { room, event, payload in
                replacementHub.emit(room: room, event: event, payloadJSON: payload)
            }
            try await app.testing { client in
                let response = try await client.send(.post, headers: fixture.headers(entry), to: URI(string: entry.path(agentId: fixture.agentId))) {
                    $0.body = .init(string: "{\"title\":\"Hub boundary\",\"msgId\":\"boundary-message\",\"delaySeconds\":3600}")
                }
                #expect(response.status == .ok)
                let id = try reminderIdAndAssertResponse(response.body.string ?? "", title: "Hub boundary")
                let actualFixed = try await reminderFramesThroughFence([fixedObserver], hub: fixed.hub)
                let actualReplacement = try await reminderFramesThroughFence([replacementObserver], hub: replacement.hub)
                #expect(actualFixed == [hasFallbackHub ? [reminderExpectedFrame(id: id, agentId: fixture.agentId)] : []])
                #expect(actualReplacement == [[]])
            }
        }
    }

    @Test(arguments: ReminderEntry.allCases)
    func rejectedCreateNeverPublishesAnApplicationFrame(entry: ReminderEntry) async throws {
        let fixture = try ReminderWireFixture()
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        var observers = [
            try await observeReminderUser(fixture, realtime: realtime, userId: fixture.ownerId, serverId: fixture.serverId),
            try await observeReminderUser(fixture, realtime: realtime, userId: fixture.creatorId, serverId: fixture.serverId),
        ]
        defer {
            for observer in observers { observer.client.close() }
            Task { try? await realtime.close() }
        }
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts, realtime: realtime.hub))
            try await app.testing { client in
                let validBody = "{\"title\":\"Refused reminder\",\"msgId\":\"refused-message\",\"delaySeconds\":3600}"
                var cases: [(path: String, headers: HTTPFields, body: String, status: Int)] = [
                    (entry.path(agentId: fixture.agentId), fixture.headers(key: nil), validBody, 401),
                    (entry.path(agentId: fixture.agentId), fixture.headers(entry), "{\"title\":\"No message\",\"delaySeconds\":3600}", 400),
                    (entry.path(agentId: fixture.externalAgentId), fixture.headers(key: entry == .machine ? fixture.machineKey : fixture.externalKey), validBody, 409),
                ]
                if entry == .machine {
                    cases.append((entry.path(agentId: fixture.agentId), fixture.headers(key: fixture.otherMachineKey), validBody, 404))
                } else {
                    cases.append((entry.path(agentId: fixture.agentId), fixture.headers(key: fixture.readOnlyKey), validBody, 403))
                }
                for testCase in cases {
                    for index in observers.indices { observers[index].startIndex = observers[index].client.textFrames.count }
                    let response = try await client.send(.post, headers: testCase.headers, to: URI(string: testCase.path)) {
                        $0.body = .init(string: testCase.body)
                    }
                    #expect(response.status.code == testCase.status)
                    #expect(try await reminderFramesThroughFence(observers, hub: realtime.hub) == [[], []])
                }
                let list = try await client.get(URI(string: entry.path(agentId: fixture.agentId)), headers: fixture.headers(entry))
                #expect(list.status == .ok)
                #expect(list.body.string == "{\"reminders\":[]}")
            }
        }
    }

    @Test func omittingDeliveryStillCommitsAListableReminder() throws {
        let fixture = try ReminderWireFixture()
        let body = try JSONDecoder().decode(ReminderCreateRequest.self, from: Data(
            "{\"title\":\"Completion contract\",\"msgId\":\"completion-message\",\"delaySeconds\":3600}".utf8
        ))
        let created = try fixture.accounts.managedMCPAgentCatalog.legacyReminderCreate(
            authorization: "Bearer \(fixture.machineKey)", agentId: fixture.agentId,
            body: body, delivery: .omit
        )
        #expect(created.scheduledDelivery == nil)
        #expect(created.response.reminder.status == "scheduled")
        #expect(created.response.reminder.version == 1)
        let listed = try fixture.accounts.managedMCPAgentCatalog.legacyReminderList(
            authorization: "Bearer \(fixture.machineKey)", agentId: fixture.agentId, status: "scheduled"
        )
        #expect(listed.jsonBody.render().contains(created.response.reminder.id))
    }
}
