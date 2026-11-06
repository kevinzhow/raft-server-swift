import Foundation
import Testing
@testable import RaftHTTP

private func leafStoreRace<Result: Sendable>(
    _ count: Int,
    _ operation: @escaping @Sendable (Int) -> Result
) async -> [Result] {
    await withTaskGroup(of: Result.self) { group in
        for index in 0..<count {
            group.addTask { operation(index) }
        }
        var results: [Result] = []
        for await result in group { results.append(result) }
        return results
    }
}

@Test func leafStoreInboxConcurrentAppendsKeepEveryReceiverFact() async {
    let store = InboxFactStore()
    _ = await leafStoreRace(64) { index in
        store.append(StoredInboxFact(
            messageId: "message-\(index)", receiverType: "agent", receiverId: "agent-\(index)",
            channelId: "channel", serverId: "server", personalMention: index.isMultiple(of: 2)
        ))
    }
    let facts = store.all()
    #expect(facts.count == 64)
    #expect(Set(facts.map(\.messageId)).count == 64)
    #expect(facts.allSatisfy { $0.receiverId == $0.messageId.replacingOccurrences(of: "message-", with: "agent-") })
    #expect(facts.filter(\.personalMention).count == 32)
}

@Test func leafStoreThreadConcurrentUnfollowsKeepEachFollowIdentity() async {
    let store = ThreadFollowStore()
    let followedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let unfollowedAt = followedAt.addingTimeInterval(60)
    _ = await leafStoreRace(32) { index in
        store.upsert(AgentThreadFollowRecord(
            serverId: "server", agentId: "agent-\(index)", threadChannelId: "thread",
            parentMessageId: "parent-\(index)", followedAt: followedAt, reason: "explicit"
        ))
    }
    _ = await leafStoreRace(32) { index in
        store.markUnfollowed(serverId: "server", agentId: "agent-\(index)", threadChannelId: "thread", at: unfollowedAt)
    }
    let rows = store.all()
    #expect(rows.count == 32)
    #expect(Set(rows.map(\.agentId)).count == 32)
    #expect(rows.allSatisfy { $0.followedAt == followedAt && $0.unfollowedAt == unfollowedAt && $0.reason == "explicit" })
    #expect(rows.allSatisfy { $0.parentMessageId == $0.agentId.replacingOccurrences(of: "agent-", with: "parent-") })
    store.markUnfollowed(serverId: "missing", agentId: "missing", threadChannelId: "thread", at: unfollowedAt)
    #expect(store.all().count == 32)
}

@Test func leafStoreProductAdmissionDeduplicatesOverlappingBatchesAtomically() async {
    let store = ProductEventStore()
    let record = ClientEventRecord(
        event: "open", analyticsId: "analytics", serverId: "server", source: "web",
        sessionId: "session", appVersion: nil, propertiesJSON: "{}"
    )
    let candidates = [
        ProductEventStore.ClientEventCandidate(eventId: "first", record: record),
        ProductEventStore.ClientEventCandidate(eventId: "second", record: record),
        ProductEventStore.ClientEventCandidate(eventId: "first", record: record),
    ]
    let admissions = await leafStoreRace(32) { _ in
        store.admitClientEvents(candidates, seenIDs: ["first", "second", "filtered-out"])
    }
    #expect(admissions.reduce(0, +) == 2)
    #expect(admissions.filter { $0 == 2 }.count == 1)
    #expect(store.clientEvents(serverId: "server").count == 2)
    // A validated but filtered row still spends its id in the same transaction.
    #expect(store.containsSeenClientEvent("filtered-out"))
    #expect(store.admitClientEvents([
        ProductEventStore.ClientEventCandidate(eventId: "filtered-out", record: record),
    ], seenIDs: ["filtered-out"]) == 0)
}

@Test func leafStoreNotificationsConcurrentRegistrationKeepsOneCompleteRow() async throws {
    let store = NotificationsStore()
    _ = await leafStoreRace(32) { index in
        let marker = "value-\(index)"
        store.upsertPushRegistration(EmailLoginDirectory.PushRegistration(
            installationId: "installation", provider: "fcm", env: marker, topic: marker,
            deviceToken: marker, appVersion: marker, userId: marker, serverId: marker,
            sessionFamilyId: marker, revokeCapability: marker
        ))
        store.recordWebPushSubscription(userId: "user", endpoint: "https://push.test/subscription")
    }
    let rows = store.pushRegistrations
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.env == row.topic && row.env == row.deviceToken)
    #expect(row.appVersion == row.env && row.userId == row.env && row.serverId == row.env)
    #expect(row.sessionFamilyId == row.env && row.revokeCapability == row.env)
    #expect(store.webPushSubscriptions.count == 1)
    #expect(store.isFcmActive(installationId: "installation", userId: row.env))
    #expect(store.unbindPushInstallation(installationId: "installation") == 1)
    #expect(!store.isFcmActive(installationId: "installation", userId: row.env))
}

@Test func leafStoreAnnouncementImageSnapshotNeverMixesTwoStateVersions() async {
    let store = NotificationsStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshots = await leafStoreRace(32) { index in
        let marker = "announcement-\(index)"
        var state = NotificationsStore.State()
        state.announcements = [(
            id: marker, title: marker, pages: [], startsAt: now, expiresAt: nil,
            status: "published", publishedAt: now, imageId: "image", audienceServerIds: []
        )]
        state.announcementImageAssets["image"] = AnnouncementImageAsset(
            id: "image", announcementId: marker, contentType: "image/png", bytes: Data(marker.utf8)
        )
        store.state = state
        return store.announcementImageSnapshot(imageId: "image")
    }
    #expect(snapshots.allSatisfy {
        guard let asset = $0.asset, let announcement = $0.announcement else { return false }
        return asset.announcementId == announcement.id && asset.bytes == Data(announcement.title.utf8)
    })
}

@Test func leafStoreFeedbackConcurrentBindingsChooseOneCommitment() async throws {
    let store = FeedbackStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let outcomes = await leafStoreRace(32) { index in
        store.checkRouteBinding(
            commitmentLabel: "label", commitment: Data([UInt8(index % 2)]), cacheKey: "cache", now: now
        )
    }
    #expect(outcomes.filter { $0 == .miss }.count == 16)
    #expect(outcomes.filter { $0 == .commitmentMismatch }.count == 16)
    #expect(store.routeCommitmentLabels() == ["label"])
    let winner = try #require(store.state.productFeedbackRouteCommitments["label"])
    store.recordRouteBindingSuccess(cacheKey: "cache", expiresAt: now.addingTimeInterval(60))
    #expect(store.checkRouteBinding(commitmentLabel: "label", commitment: winner, cacheKey: "cache", now: now) == .cached)
    store.clearRouteBindingCache()
    #expect(store.checkRouteBinding(commitmentLabel: "label", commitment: winner, cacheKey: "cache", now: now) == .miss)
    // Cache invalidation preserves the root commitment, including on conflicts.
    let other = winner == Data([0]) ? Data([1]) : Data([0])
    #expect(store.checkRouteBinding(commitmentLabel: "label", commitment: other, cacheKey: "cache", now: now) == .commitmentMismatch)
}
