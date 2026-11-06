import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The service/store contract behind the join-link routes. The HTTP tests lock
/// the wire shape; these lock the atomic decision the routes now depend on.

@Test func joinLinkAcceptanceSpendsTheLastUseExactlyOnce() async {
    let directory = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001130001"
    let serverId = "33333333-3333-4333-8333-000001130001"
    directory.oauth.addOwnedServer(id: serverId, slug: "atomic", name: "Atomic", ownerId: ownerId)
    let store = directory.serversAndChannelsStore
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    store.insertJoinLink(JoinLinkRecord(
        id: "atomic-link",
        token: "one-use-token",
        serverId: serverId,
        role: "member",
        createdAt: now,
        expiresAt: nil,
        maxUses: 1,
        useCount: 0,
        revokedAt: nil
    ))
    let usedSeats: @Sendable (String) -> Int = { _ in 1 }
    let noAgreement: @Sendable (String) -> ServerAgreementDTO? = { _ in nil }

    let acceptances = await withTaskGroup(of: ServersAndChannelsStore.JoinLinkAcceptance.self) { group in
        for index in 0..<8 {
            group.addTask {
                store.acceptJoinLink(
                    token: "one-use-token",
                    userId: "\(ownerId)-\(index)",
                    requestedAgreementId: nil,
                    now: now,
                    usedSeats: usedSeats,
                    activeAgreement: noAgreement
                )
            }
        }
        var results: [ServersAndChannelsStore.JoinLinkAcceptance] = []
        for await result in group { results.append(result) }
        return results
    }

    let accepted = acceptances.filter {
        if case .accepted = $0 { return true }
        return false
    }
    #expect(accepted.count == 1)
    #expect(acceptances.filter { $0 == .invalid }.count == 7)
    #expect(store.joinLink(token: "one-use-token")?.useCount == 1)
}

@Test func joinLinkSeatLimitRefusalDoesNotSpendTheUse() {
    let directory = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001130002"
    let serverId = "33333333-3333-4333-8333-000001130002"
    directory.oauth.addOwnedServer(id: serverId, slug: "atomic-seat", name: "Atomic Seat", ownerId: ownerId)
    let store = directory.serversAndChannelsStore
    let oauth = directory.oauth
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    store.insertJoinLink(JoinLinkRecord(
        id: "seat-link",
        token: "seat-token",
        serverId: serverId,
        role: "member",
        createdAt: now,
        expiresAt: nil,
        maxUses: nil,
        useCount: 0,
        revokedAt: nil
    ))
    let usedSeats: @Sendable (String) -> Int = { serverId in
        oauth.memberIdsWithRoles(serverId: serverId).filter { $0.role != "guest" }.count
    }
    let noAgreement: @Sendable (String) -> ServerAgreementDTO? = { _ in nil }

    store.setSeats(serverId: serverId, seats: 1)
    let refused = store.acceptJoinLink(
        token: "seat-token",
        userId: "11111111-1111-4111-8111-000001130099",
        requestedAgreementId: nil,
        now: now,
        usedSeats: usedSeats,
        activeAgreement: noAgreement
    )
    #expect(refused == .seatLimit("Seat limit reached (1/1 on Pro plan)"))
    // The refusal happens before the use-count write, exactly like the
    // retired directory critical section.
    #expect(store.joinLink(token: "seat-token")?.useCount == 0)

    store.setSeats(serverId: serverId, seats: 2)
    let accepted = store.acceptJoinLink(
        token: "seat-token",
        userId: "11111111-1111-4111-8111-000001130099",
        requestedAgreementId: nil,
        now: now,
        usedSeats: usedSeats,
        activeAgreement: noAgreement
    )
    #expect(accepted == .accepted(serverId: serverId, role: "member"))
    #expect(store.joinLink(token: "seat-token")?.useCount == 1)
}

@Test func joinLinkInviteInfoKeepsTheUpstreamMemberOrder() throws {
    let directory = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001130003"
    let serverId = "33333333-3333-4333-8333-000001130003"
    directory.oauth.addOwnedServer(id: serverId, slug: "exact-body", name: "Exact Body", ownerId: ownerId)
    let store = directory.serversAndChannelsStore
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    store.insertJoinLink(JoinLinkRecord(
        id: "exact-link",
        token: "exact-token",
        serverId: serverId,
        role: "member",
        createdAt: now,
        expiresAt: nil,
        maxUses: 3,
        useCount: 1,
        revokedAt: nil
    ))

    let response = try directory.joinLinksAndInvites.inviteInfo(token: "exact-token")
    let expected = "{\"serverId\":\"\(serverId)\",\"serverName\":\"Exact Body\",\"serverSlug\":\"exact-body\",\"humanSeatLimitReached\":false,\"humanSeatLimitMessage\":null,\"memberCount\":1,\"agentCount\":0,\"insideCountsHidden\":false,\"agreement\":null}"
    #expect(response.jsonBody.render() == expected)
}

@Test func joinLinkCreateDecodesTheLegacyFieldTolerance() throws {
    // A wrong-typed `expiresAt` is ignored, `maxUses` keeps the NSNumber
    // integral reading, and a non-empty string is the published 400.
    let ignored = try JSONDecoder().decode(
        CreateJoinLinkRequest.self,
        from: Data("{\"expiresAt\":5,\"maxUses\":2.0}".utf8)
    )
    #expect(ignored.expiresAt == nil)
    #expect(ignored.maxUses == .limited(2))

    let limited = try JSONDecoder().decode(
        CreateJoinLinkRequest.self,
        from: Data("{\"expiresAt\":\"2026-01-01T00:00:00.000Z\",\"maxUses\":true}".utf8)
    )
    #expect(limited.expiresAt == "2026-01-01T00:00:00.000Z")
    #expect(limited.maxUses == .limited(1))

    let string = try JSONDecoder().decode(
        CreateJoinLinkRequest.self,
        from: Data("{\"maxUses\":\"2\"}".utf8)
    )
    #expect(string.maxUses == .invalid)

    let unlimited = try JSONDecoder().decode(
        CreateJoinLinkRequest.self,
        from: Data("{\"maxUses\":\"\"}".utf8)
    )
    #expect(unlimited.maxUses == .unlimited)

    let zero = try JSONDecoder().decode(
        CreateJoinLinkRequest.self,
        from: Data("{\"maxUses\":0}".utf8)
    )
    #expect(zero.maxUses == .invalid)
}
