import Dispatch
import Foundation
import Synchronization
import Testing
@testable import RaftHTTP

@Suite struct MessagingStoreConcurrencyTests {
    @Test func transactionsKeepCursorAndVersionSnapshotsTogether() {
        let store = MessagesAndThreadsStore()
        let failures = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            store.withState { state in
                let next = (state.userChannelReadCursors["u\nc"] ?? 0) + 1
                state.userChannelReadCursors["u\nc"] = next
                state.channelReadVersions["c\nu"] = next
            }
            let snapshot = store.state
            if snapshot.userChannelReadCursors["u\nc"] != snapshot.channelReadVersions["c\nu"] {
                failures.withLock { $0 += 1 }
            }
        }
        #expect(failures.withLock { $0 } == 0)
        #expect(store.state.userChannelReadCursors["u\nc"] == 200)
    }

    @Test func concurrentMutationAdmissionHasOneWinnerAndOneAuthoritySequence() {
        let store = MessagesAndThreadsStore()
        let admitted = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 80) { _ in
            let result = store.admitReadMutation(key: "same", sequenceKey: "s\nu", userId: "u", fingerprint: "fp") { sequence in
                ReadMutationRecord(
                    mutationId: "same", serverId: "s", principalId: "u", kind: "channel_read_all",
                    scopeId: "c", fingerprint: "fp", authoritySeq: sequence, state: "admitted"
                )
            }
            if case .admitted = result { admitted.withLock { $0 += 1 } }
        }
        #expect(admitted.withLock { $0 } == 1)
        #expect(store.readMutationAuthoritySeq["s\nu"] == 1)
        #expect(store.readMutationOrder == ["same"])
        #expect(store.readMutationReplay(key: "same", fingerprint: "different", userId: "u") == .payloadMismatch)
        store.withState { $0.userChannelReadCursors["u\nc"] = 19 }
        #expect(store.readMutationReplay(key: "same", fingerprint: "fp", userId: "u") == .alreadyTerminal(scopeId: "c", cursor: 19))
    }

    @Test func independentPropertyWritesCannotOverwriteReactionTransactions() {
        let store = MessagesAndThreadsStore()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index.isMultiple(of: 2) {
                store.readPositionSettleMs = index
            } else {
                _ = store.applyUserReaction(messageId: "m", userId: "u-\(index)", emoji: "🔥", remove: false)
            }
        }
        let discussion = store.reactionDiscussionSnapshot(messageId: "m", emoji: "🔥")
        #expect(discussion.rows.count == 100)
        #expect(discussion.discussionVersion == 100)
        #expect(Set(discussion.rows.map(\.reactorId)).count == 100)
    }

    @Test func pendingMentionAndNotifyClaimAreIdempotentAcrossWriters() throws {
        let store = MessagesAndThreadsStore()
        store.humanMessageRows = [StoredHumanMessage(id: "m", channelId: "c", senderId: "u", content: "hello", randomId: nil)]
        let identifiers = Mutex(Set<String>())
        DispatchQueue.concurrentPerform(iterations: 80) { _ in
            let ids = store.resolvePendingMentionRows(
                messageId: "m", channelId: "c", candidates: [PendingMentionCandidate(type: "agent", id: "a", name: "agent")]
            )
            identifiers.withLock { $0.formUnion(ids) }
        }
        let ids = identifiers.withLock { Array($0) }
        #expect(ids.count == 1)
        #expect(store.storedMentions.count == 1)
        let resolutionId = try #require(ids.first)
        let claims = Mutex([MentionActionClaim]())
        DispatchQueue.concurrentPerform(iterations: 80) { _ in
            if let claim = store.claimMentionGroup(
                resolutionId: resolutionId, action: "notify", actorType: "user", actorId: "u", now: Date()
            ) {
                claims.withLock { $0.append(claim) }
            }
        }
        let results = claims.withLock { $0 }
        #expect(results.count == 80)
        // This is the real owner's atomic claim; actual cross-owner delivery is
        // verified through the public HTTP/BPR PostgreSQL acceptance case.
        #expect(results.filter(\.newlyClaimed).count == 1)
        #expect(results.filter { $0.result.reason == "already_queued" }.count == 79)
        #expect(results.allSatisfy {
            $0.result.status == "queued" && $0.result.resolutionId == resolutionId
                && $0.result.messageId == "m" && $0.result.channelId == "c"
                && $0.result.targetType == "agent" && $0.result.targetId == "a"
        })
        #expect(store.storedMentions.first?.notifiedAction == "notify_only")
        #expect(store.storedMentions.first?.notifiedByType == "user")
        #expect(store.storedMentions.first?.notifiedById == "u")
    }

    @Test func concurrentFollowWritesNeverExposeFollowAndSuppressionTogether() {
        let store = MessagesAndThreadsStore()
        let inconsistent = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 120) { index in
            store.applyThreadFollow(
                serverId: "s", userId: "u", threadChannelId: "t", parentMessageId: "m",
                follow: index.isMultiple(of: 2), now: Date()
            )
            let snapshot = store.threadFollowSnapshot()
            if snapshot.follows.contains("s\nu\nt") == snapshot.unfollows.contains("s\nu\nt") {
                inconsistent.withLock { $0 += 1 }
            }
        }
        #expect(inconsistent.withLock { $0 } == 0)
    }
}
