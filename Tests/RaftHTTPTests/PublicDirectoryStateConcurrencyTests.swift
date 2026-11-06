import Foundation
import Testing
@testable import RaftHTTP

private let publicStateNow = Date(timeIntervalSince1970: 1_800_000_000)
private let publicStateServer = "33333333-3333-4333-8333-333333339001"
private let publicStateChannel = "22222222-2222-4222-8222-222222229001"
private let publicStateVisitor = "11111111-1111-4111-8111-111111119001"

private func racePublicState<T: Sendable>(
    count: Int = 64,
    _ operation: @escaping @Sendable (Int) -> T
) async -> [T] {
    await withTaskGroup(of: T.self) { group in
        for index in 0..<count { group.addTask { operation(index) } }
        var results: [T] = []
        for await result in group { results.append(result) }
        return results
    }
}

private func publicStateDirectory() -> PublicServerDirectory {
    let directory = PublicServerDirectory()
    _ = directory.addServer(
        id: "srv", name: "State/中", slug: "state", ownerId: "owner", ownerToken: "owner-token",
        channels: [(id: "channel", name: "general", description: nil, guestVisible: true, publicId: nil,
                    threads: [(id: "thread", publicId: nil, parent: "parent", replies: [])])]
    )
    return directory
}

@Test func publicDirectoryStateConcurrentVisibilityBackfillsEachIDOnce() async throws {
    let directory = publicStateDirectory()
    let outcomes = await racePublicState { _ in
        try? directory.patchVisibility(serverId: "srv", authorization: "Bearer owner-token", body: #"{"publiclyVisible":false,"publiclyVisible":1.0}"#)
            .jsonBody.render()
    }
    #expect(outcomes.allSatisfy { $0 == #"{"publiclyVisible":true,"publicGuestJoinEnabled":false,"publicSearchEnabled":true}"# })
    let ids = directory.publicIds(serverId: "srv")
    #expect(ids.count == 2)
    #expect(Set(ids).count == 2)
    #expect(ids.allSatisfy { $0.count == 32 })
    _ = try directory.patchVisibility(serverId: "srv", authorization: "Bearer owner-token", body: #"{"publiclyVisible":true}"#)
    #expect(directory.publicIds(serverId: "srv") == ids)
    #expect(directory.projectedCatalog().servers.count == 1)
}

@Test func publicDirectoryStateConcurrentServerSeedsHaveUniquePublicIDs() async {
    let directory = PublicServerDirectory()
    let ids = await racePublicState { index -> [String] in
        guard let seed = directory.addServer(
            id: "server-\(index)", name: "server", slug: "server-\(index)", ownerId: "owner", ownerToken: "token",
            publiclyVisible: true,
            channels: [(id: "channel-\(index)", name: "general", description: nil, guestVisible: true, publicId: nil,
                        threads: [(id: "thread-\(index)", publicId: nil, parent: "parent", replies: [])])]
        ) else { return [] }
        return [seed.serverPublicId, seed.openPublicId, seed.threadPublicId]
    }.flatMap { $0 }
    #expect(ids.count == 192)
    #expect(Set(ids).count == 192)
    #expect(directory.projectedCatalog().servers.count == 64)
}

@Test func publicDirectoryStateConcurrentInviteAcceptanceConsumesOnePendingInvite() async {
    let directory = publicStateDirectory()
    directory.addAccount(id: "invitee", email: "invitee@slock.test", token: "invitee-token")
    directory.addEmailInvite(serverId: "srv", email: "invitee@slock.test", role: "guest", rawToken: "invite", expiresAt: publicStateNow.addingTimeInterval(60))
    let accepted = await racePublicState { _ in
        try? directory.acceptInvite(authorization: "Bearer invitee-token", body: #"{"token":"wrong","token":"invite"}"#, now: publicStateNow).jsonBody.render()
    }.compactMap { $0 }
    #expect(accepted == [#"{"serverId":"srv","serverName":"State/中"}"#])
    #expect(directory.memberRole(serverId: "srv", userId: "invitee") == "guest")
}

@Test func publicVisitStateConcurrentDuplicateVisitsCommitOneEventAndVisitor() async {
    let directory = PublicVisitDirectory()
    directory.addServer(id: publicStateServer, slug: "visits", visitorIdEnabled: true)
    let source = #"{"uuid":"invalid","uuid":"11111111-1111-4111-8111-111111119002","event":"invalid","event":"public_page_viewed","entry":"landing","anonymous_id":"11111111-1111-4111-8111-111111119001"}"#
    _ = await racePublicState { _ in
        directory.record(slug: "visits", site: "same-site", authorization: nil, body: source, now: publicStateNow)
    }
    #expect(directory.rows == [PublicVisitRow(
        event: "public_page_viewed", visitor: "anonymous", serverId: publicStateServer, source: "server",
        analyticsId: nil, clientSessionId: nil, channelId: nil, entry: "landing",
        browser: "other", os: "other", deviceType: "other"
    )])
    #expect(directory.visitors == [PublicVisitorRow(
        uuid: "11111111-1111-4111-8111-111111119002", event: "public_page_viewed", serverId: publicStateServer,
        anonymousId: publicStateVisitor
    )])
}

@Test func publicVisitStateConcurrentCapCommitsOnlyItsDailyAllowance() async {
    let directory = PublicVisitDirectory(dailyCap: 17)
    directory.addServer(id: publicStateServer, slug: "cap", visitorIdEnabled: true)
    _ = await racePublicState(count: 96) { index in
        let uuid = String(format: "11111111-1111-4111-8111-%012x", index)
        let source = "{\"uuid\":\"\(uuid)\",\"event\":\"public_page_viewed\",\"anonymous_id\":\"\(publicStateVisitor)\"}"
        directory.record(slug: "cap", site: "same-origin", authorization: nil, body: source, now: publicStateNow)
    }
    #expect(directory.rows.count == 17)
    #expect(directory.visitors.count == 17)
    #expect(Set(directory.visitors.map(\.uuid)).count == 17)
}

@Test func publicVisitStateCapRefusalsKeepTheOriginalSeenBeforeCapOrder() {
    let directory = PublicVisitDirectory(dailyCap: 1)
    directory.addServer(id: publicStateServer, slug: "cap")
    let first = #"{"uuid":"11111111-1111-4111-8111-111111119011","event":"public_page_viewed"}"#
    let refused = #"{"uuid":"11111111-1111-4111-8111-111111119012","event":"public_page_viewed"}"#
    directory.record(slug: "cap", site: "same-site", authorization: nil, body: first, now: publicStateNow)
    directory.record(slug: "cap", site: "same-site", authorization: nil, body: refused, now: publicStateNow)
    directory.record(slug: "cap", site: "same-site", authorization: nil, body: refused, now: publicStateNow.addingTimeInterval(86_400))
    #expect(directory.rows.count == 1)
}

@Test func publicVisitStateConcurrentJoinCommitsOneAgreementAuditAndAnalyticsPair() async throws {
    let directory = PublicVisitDirectory()
    directory.addServer(id: publicStateServer, slug: "join", visitorIdEnabled: true, guestJoinEnabled: true, guestRolloutEnabled: true)
    directory.addUser(PublicVisitUser(id: "user", shareUsageData: true, analyticsId: "analytics"))
    directory.addToken("token", userId: "user")
    directory.setAgreement(slug: "join", id: "agreement", title: "Terms", bodyMarkdown: "body")
    let joined = await racePublicState { _ in
        try? directory.join(slug: "join", authorization: "Bearer token", body: #"{"agreementId":"old","agreementId":"agreement","anonymous_id":"11111111-1111-4111-8111-111111119001"}"#).joined
    }.compactMap { $0 }
    #expect(joined.count == 64)
    #expect(joined.filter { $0 }.count == 1)
    #expect(directory.joinAudits(slug: "join") == [PublicJoinAudit(source: "join", agreementId: "agreement", subjectId: "user")])
    #expect(directory.serverMemberRole(slug: "join", userId: "user") == "guest")
    let event = try #require(directory.rows.first)
    #expect(directory.rows.count == 1)
    #expect(event == PublicVisitRow(
        event: "public_page_server_joined", visitor: "", serverId: publicStateServer, source: "server",
        analyticsId: "analytics", clientSessionId: nil, channelId: nil, hasVisitorId: true, uuid: event.uuid
    ))
    #expect(directory.visitors == [PublicVisitorRow(
        uuid: try #require(event.uuid), event: "public_page_server_joined", serverId: publicStateServer,
        anonymousId: publicStateVisitor
    )])
}
