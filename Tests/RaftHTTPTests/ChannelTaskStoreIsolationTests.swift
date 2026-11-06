import Foundation
import Testing
@testable import RaftHTTP

@Suite("Channel and task store isolation")
struct ChannelTaskStoreIsolationTests {
    @Test func concurrentTaskNumbersKeepEachBatchTogether() async {
        let store = TasksAndRemindersStore()
        let batches = await withTaskGroup(of: [TaskRecord].self) { group in
            for writer in 0..<32 {
                group.addTask {
                    store.appendTaskBatch(channelId: "c", titles: ["a-\(writer)", "b-\(writer)"], creatorId: "agent", now: Date())
                }
            }
            var batches: [[TaskRecord]] = []
            for await batch in group { batches.append(batch) }
            return batches
        }
        #expect(batches.count == 32)
        #expect(batches.allSatisfy { $0.count == 2 && $0[1].taskNumber == $0[0].taskNumber + 1 })
        #expect(Set(batches.flatMap { $0.map(\.taskNumber) }) == Set(1...64))
        #expect(store.taskRows(channelId: "c").count == 64)
    }

    @Test func concurrentTaskClaimsHaveOneWinnerAndOneRevision() async {
        let store = TasksAndRemindersStore()
        _ = store.appendTaskBatch(channelId: "c", titles: ["claim"], creatorId: "creator", now: Date())
        let winners = await withTaskGroup(of: Bool.self) { group in
            for writer in 0..<32 {
                group.addTask {
                    let result = store.claimTasks(channelId: "c", agentId: "agent-\(writer)", taskNumbers: [1], messageIds: [], now: Date())
                    if case .claimed = result.first { return true }
                    return false
                }
            }
            var winners = 0
            for await won in group where won { winners += 1 }
            return winners
        }
        #expect(winners == 1)
        let row = store.task(channelId: "c", taskNumber: 1)
        #expect(row?.revision == 1)
        #expect(row?.status == "in_progress")
        #expect(row?.claimedAt != nil)
    }

    @Test func reminderCASKeepsVersionAndEventInOneTransaction() async {
        let store = TasksAndRemindersStore()
        let id = store.createReminder(serverId: "s", ownerAgentId: "agent", title: "scheduled", fireAt: Date())
        let winners = await withTaskGroup(of: Bool.self) { group in
            for writer in 0..<32 {
                group.addTask {
                    let outcome = store.updateReminder(reminderId: id, ownerAgentId: "agent", expectedVersion: 1, title: "title-\(writer)", fireAt: nil, notes: nil)
                    switch outcome {
                    case .ok(let version):
                        #expect(version == 2)
                        return true
                    case .conflict(let version):
                        #expect(version == 2)
                        return false
                    default:
                        Issue.record("unexpected reminder result")
                        return false
                    }
                }
            }
            var winners = 0
            for await won in group where won { winners += 1 }
            return winners
        }
        #expect(winners == 1)
        let snapshot = store.state
        #expect(snapshot.reminderRecords.first?.version == 2)
        #expect(snapshot.reminderEvents.count == 2)
        #expect(Set(snapshot.reminderEvents.map(\.version)) == Set([1, 2]))
        #expect(Set(snapshot.reminderEvents.map(\.type)) == Set(["scheduled", "updated"]))
    }

    @Test func concurrentJoinLimitSpendsAndAuditsOnlyAcceptedUses() async {
        let store = ServersAndChannelsStore()
        let now = Date()
        let agreement = ServerAgreementDTO(id: "agreement", version: 3, title: "Terms", bodyMarkdown: "Agree", enabled: true)
        store.insertJoinLink(JoinLinkRecord(id: "link", token: "token", serverId: "s", role: "member", createdAt: now, expiresAt: nil, maxUses: 5, useCount: 0, revokedAt: nil))
        let winners = await withTaskGroup(of: Bool.self) { group in
            for writer in 0..<32 {
                group.addTask {
                    let result = store.acceptJoinLink(token: "TOKEN", userId: "user-\(writer)", requestedAgreementId: agreement.id, now: now, usedSeats: { _ in 0 }, activeAgreement: { _ in agreement })
                    if case .accepted = result { return true }
                    #expect(result == .invalid)
                    return false
                }
            }
            var winners = 0
            for await won in group where won { winners += 1 }
            return winners
        }
        #expect(winners == 5)
        let snapshot = store.state
        #expect(snapshot.joinLinks["token"]?.useCount == 5)
        #expect(snapshot.membershipAgreementAudits.count == 5)
        #expect(Set(snapshot.membershipAgreementAudits.map(\.subjectId)).count == 5)
        #expect(snapshot.membershipAgreementAudits.allSatisfy { $0.agreementId == agreement.id && $0.agreementVersion == 3 })
    }

    @Test func memberRemovalSnapshotsKeepStatusMarkerAndEventTogether() async {
        let store = ServersAndChannelsStore()
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<32 {
                group.addTask {
                    store.markMemberRemoved(serverId: "s", userId: "user-\(writer)", provenanceJSON: "{}")
                    let snapshot = store.state
                    for event in snapshot.serverMemberEvents {
                        let key = "s\n\(event.subjectId)"
                        #expect(snapshot.serverMemberStatuses[key] == "removed")
                        #expect(snapshot.removedServerMembers.contains(key))
                    }
                }
            }
        }
        let final = store.state
        #expect(final.serverMemberEvents.count == 32)
        #expect(final.serverMemberStatuses.count == 32)
        #expect(final.removedServerMembers.count == 32)
    }

    @Test func compatibilitySettersPreserveConcurrentWritesToOtherFields() async {
        for _ in 0..<64 {
            let channels = ServersAndChannelsStore()
            let tasks = TasksAndRemindersStore()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { channels.threadOrder = ["thread"] }
                group.addTask { channels.guestRoleServers = ["server"] }
                group.addTask { channels.proSeats = ["server": 3] }
                group.addTask { tasks.lastTaskServerWarning = "warning" }
                group.addTask { tasks.taskWriteHolds = ["key": (seen: 1, latest: 2)] }
            }
            #expect(channels.threadOrder == ["thread"])
            #expect(channels.guestRoleServers == ["server"])
            #expect(channels.proSeats["server"] == 3)
            #expect(tasks.lastTaskServerWarning == "warning")
            #expect(tasks.taskWriteHolds["key"]?.latest == 2)
        }
    }
}
