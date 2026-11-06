import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The service/store contract behind the server-member, sidebar, labs and task
/// metric routes. The HTTP tests lock the wire shape; these lock the single
/// critical section each decision now runs in.

private func membersFixture(
    ownerId: String,
    serverId: String,
    slug: String
) -> EmailLoginDirectory {
    let directory = EmailLoginDirectory()
    directory.addAccount(id: ownerId, email: "\(slug)@slock.test", password: "password123")
    directory.markEmailVerified(userId: ownerId)
    directory.oauth.addOwnedServer(id: serverId, slug: slug, name: slug, ownerId: ownerId)
    return directory
}

@Test func labsAccessVersionCASAcceptsExactlyOneConcurrentWriter() async {
    let ownerId = "11111111-1111-4111-8111-000001160001"
    let serverId = "33333333-3333-4333-8333-000001160001"
    let directory = membersFixture(ownerId: ownerId, serverId: serverId, slug: "labs-cas")
    let store = directory.serversAndChannelsStore

    let results = await withTaskGroup(of: ServersAndChannelsStore.LabsApplyResult.self) { group in
        for _ in 0..<8 {
            group.addTask {
                store.applyLabsAccess(serverId: serverId, enabled: true, expectedVersion: 0)
            }
        }
        var collected: [ServersAndChannelsStore.LabsApplyResult] = []
        for await result in group { collected.append(result) }
        return collected
    }

    let applied = results.filter {
        if case .applied = $0 { return true }
        return false
    }
    #expect(applied.count == 1)
    #expect(results.filter {
        if case .versionConflict = $0 { return true }
        return false
    }.count == 7)
    #expect(store.serverLabs(serverId: serverId).version == 1)
    #expect(store.serverLabs(serverId: serverId).accessEnabled)
}

@Test func labEnrollmentVersionCASAndStateGatesAreOneDecision() async {
    let ownerId = "11111111-1111-4111-8111-000001160002"
    let serverId = "33333333-3333-4333-8333-000001160002"
    let directory = membersFixture(ownerId: ownerId, serverId: serverId, slug: "labs-enroll")
    let store = directory.serversAndChannelsStore
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    // A closed master switch refuses before touching the version.
    #expect(
        store.applyLabEnrollment(
            serverId: serverId,
            labKey: "open_lab",
            enabled: true,
            expectedVersion: 0,
            labOpen: true,
            now: now
        ) == .accessDisabled
    )
    #expect(store.serverLabs(serverId: serverId).version == 0)

    _ = store.applyLabsAccess(serverId: serverId, enabled: true, expectedVersion: 0)
    let results = await withTaskGroup(of: ServersAndChannelsStore.LabEnrollmentApplyResult.self) { group in
        for _ in 0..<8 {
            group.addTask {
                store.applyLabEnrollment(
                    serverId: serverId,
                    labKey: "open_lab",
                    enabled: true,
                    expectedVersion: 1,
                    labOpen: true,
                    now: now
                )
            }
        }
        var collected: [ServersAndChannelsStore.LabEnrollmentApplyResult] = []
        for await result in group { collected.append(result) }
        return collected
    }
    let applied = results.filter {
        if case .applied = $0 { return true }
        return false
    }
    #expect(applied.count == 1)
    #expect(results.filter {
        if case .versionConflict = $0 { return true }
        return false
    }.count == 7)
    let state = store.serverLabs(serverId: serverId)
    #expect(state.version == 2)
    #expect(state.enrolled == ["open_lab"])
    #expect(state.updatedAt["open_lab"] == now)

    // A paused/draft lab refuses without bumping the version.
    #expect(
        store.applyLabEnrollment(
            serverId: serverId,
            labKey: "open_lab",
            enabled: false,
            expectedVersion: 2,
            labOpen: false,
            now: now
        ) == .labNotOpen
    )
    #expect(store.serverLabs(serverId: serverId).version == 2)
    #expect(store.serverLabs(serverId: serverId).enrolled == ["open_lab"])
}

@Test func sidebarSectionVersionCASAcceptsExactlyOneConcurrentPatch() async {
    let ownerId = "11111111-1111-4111-8111-000001160003"
    let serverId = "33333333-3333-4333-8333-000001160003"
    let directory = membersFixture(ownerId: ownerId, serverId: serverId, slug: "sidebar-cas")
    let token = directory.mintAccessTokenForTesting(userId: ownerId)
    let service = directory.serverMembersAndSidebar

    let successes = await withTaskGroup(of: Bool.self) { group in
        for index in 0..<8 {
            group.addTask {
                let body = SidebarOrderPatchRequest(
                    customSections: .value([
                        SidebarSectionPatchEntry(id: "section-\(index)", name: "Section \(index)"),
                    ]),
                    sectionsVersion: .value(0)
                )
                do {
                    _ = try service.patchSidebarOrder(
                        authorization: "Bearer \(token)",
                        serverId: serverId,
                        body: body
                    )
                    return true
                } catch {
                    return false
                }
            }
        }
        var accepted = 0
        for await success in group where success { accepted += 1 }
        return accepted
    }

    #expect(successes == 1)
    let snapshot = directory.serversAndChannelsStore.sidebarSnapshot(serverId: serverId, userId: ownerId)
    #expect(snapshot.sections.version == 1)
    #expect(snapshot.sections.sections.count == 1)
}

@Test func memberRemovalWritesStatusMarkerAndEventInOneSection() throws {
    let ownerId = "11111111-1111-4111-8111-000001160004"
    let memberId = "11111111-1111-4111-8111-000001160005"
    let serverId = "33333333-3333-4333-8333-000001160004"
    let directory = membersFixture(ownerId: ownerId, serverId: serverId, slug: "member-removal")
    directory.addAccount(id: memberId, email: "member-removal-peer@slock.test", password: "password123")
    directory.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let token = directory.mintAccessTokenForTesting(userId: ownerId)
    let store = directory.serversAndChannelsStore

    _ = try directory.serverMembersAndSidebar.removeServerMember(
        authorization: "Bearer \(token)",
        serverId: serverId,
        memberId: memberId
    )

    #expect(directory.oauth.memberRole(serverId: serverId, userId: memberId) == nil)
    #expect(store.serverMemberStatuses["\(serverId)\n\(memberId)"] == "removed")
    #expect(store.removedServerMembers.contains("\(serverId)\n\(memberId)"))
    let event = try #require(store.serverMemberEvents.last)
    #expect(event.serverId == serverId)
    #expect(event.eventType == "server.member_removed")
    #expect(event.subjectType == "member")
    #expect(event.subjectId == memberId)
    #expect(event.deliveryQueued)
    #expect(
        event.provenanceJSON
            == "{\"actor_type\":\"human\",\"principal_type\":\"human\",\"reason\":\"removed\",\"role\":\"member\",\"source\":\"server_service\"}"
    )
}

@Test func serverDeletionQueuesMemberAndAgentEventsInOneSection() throws {
    let ownerId = "11111111-1111-4111-8111-000001160006"
    let memberId = "11111111-1111-4111-8111-000001160007"
    let serverId = "33333333-3333-4333-8333-000001160005"
    let directory = membersFixture(ownerId: ownerId, serverId: serverId, slug: "server-delete")
    directory.addAccount(id: memberId, email: "server-delete-peer@slock.test", password: "password123")
    directory.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let agentId = directory.oauth.createAgent(serverId: serverId, name: "deleter")
    let token = directory.mintAccessTokenForTesting(userId: ownerId)
    let store = directory.serversAndChannelsStore
    let before = store.serverMemberEvents.count

    _ = try directory.serverMembersAndSidebar.deleteServer(
        authorization: "Bearer \(token)",
        serverId: serverId
    )

    #expect(store.isServerDeleted(serverId))
    let queued = store.serverMemberEvents.dropFirst(before)
    #expect(queued.contains { $0.subjectType == "member" && $0.subjectId == memberId })
    #expect(queued.contains { $0.subjectType == "agent" && $0.subjectId == agentId })
    #expect(queued.allSatisfy { $0.eventType == "server.member_removed" && $0.deliveryQueued })
    // A repeat delete is the idempotent success and queues nothing new.
    _ = try directory.serverMembersAndSidebar.deleteServer(
        authorization: "Bearer \(token)",
        serverId: serverId
    )
    #expect(store.serverMemberEvents.count == before + queued.count)
}

@Test func sidebarPatchKeepsStoredModeForAnAbsentMember() throws {
    let ownerId = "11111111-1111-4111-8111-000001160008"
    let serverId = "33333333-3333-4333-8333-000001160006"
    let directory = membersFixture(ownerId: ownerId, serverId: serverId, slug: "sidebar-lenient")
    let token = directory.mintAccessTokenForTesting(userId: ownerId)
    let service = directory.serverMembersAndSidebar

    _ = try service.patchSidebarOrder(
        authorization: "Bearer \(token)",
        serverId: serverId,
        body: SidebarOrderPatchRequest(channelSortMode: .value("recent"))
    )
    // A wrong type keeps the member-specific 400 and leaves the stored mode.
    do {
        _ = try service.patchSidebarOrder(
            authorization: "Bearer \(token)",
            serverId: serverId,
            body: SidebarOrderPatchRequest(channelSortMode: .invalid)
        )
        Issue.record("expected Invalid sidebar sort mode")
    } catch let error as ServerMembersAndSidebarError {
        #expect(error == .invalidSidebarSortMode)
    }
    let order = try service.sidebarOrder(authorization: "Bearer \(token)", serverId: serverId)
    #expect(order.channelSortMode == "recent")
}
