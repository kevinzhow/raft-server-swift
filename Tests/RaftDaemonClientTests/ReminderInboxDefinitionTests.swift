import Foundation
import Testing
import RaftDaemonClient

private let reminderId = "12345678-1234-4123-8123-123456789abc"

@Test func dueItemHasExactOSMintedIdentityAndActionAndNoMessageIdentity() throws {
    let store = ReminderInboxStore()
    let result = store.mint(
        sourceRef: ["kind": "reminder", "id": reminderId, "revision": "7"],
        title: "Follow up"
    )
    guard case .ok(let item) = result else {
        Issue.record("expected mint to succeed")
        return
    }
    #expect(item.itemId == "reminder:\(reminderId):7")
    #expect(item.retention == "until_explicit_ack")
    #expect(item.actionCli == "raft reminder ack --id 12345678 --revision 7")
    #expect(item.primaryActionKind == "run_command")
    #expect(item.primaryActionCommandId == "reminder.ack")
    for field in ["msgId", "seq", "sender", "latestMsgId", "latestSenderName"] {
        #expect(!String(describing: item).contains(field))
    }
}

@Test func sourceIdentityRejectsExtraFieldsAndAppSuppliedAction() {
    let store = ReminderInboxStore()
    let extra = store.mint(sourceRef: [
        "kind": "reminder", "id": reminderId, "revision": "7", "command": "rm -rf /",
    ])
    guard case .invalidSourceRef = extra else {
        Issue.record("extra fields must be rejected")
        return
    }
    let action = store.mint(
        sourceRef: ["kind": "reminder", "id": reminderId, "revision": "7"],
        requestedPrimaryAction: ["kind": "run_command", "commandId": "shell"]
    )
    guard case .invalidPrimaryAction = action else {
        Issue.record("app-supplied action must be rejected")
        return
    }
}

@Test func sourceIdentityRejectsMalformedUUIDAndRevisionShapes() {
    let store = ReminderInboxStore()
    for sourceRef in [
        ["kind": "reminder", "id": "12345678-1234-4123-8123-123456789ab-", "revision": "7"],
        ["kind": "reminder", "id": reminderId, "revision": "0"],
        ["kind": "reminder", "id": reminderId, "revision": "01"],
    ] as [[String: String]] {
        let result = store.mint(sourceRef: sourceRef)
        guard case .invalidSourceRef = result else {
            Issue.record("expected invalid source ref for \(sourceRef)")
            continue
        }
    }
}

@Test func titlesProjectIntoOneBoundedPreviewLine() throws {
    let long = String(repeating: "x", count: 500)
    #expect(ReminderInboxDefinition.projectTitle(long) == String(repeating: "x", count: 119) + "\u{2026}")
    #expect(ReminderInboxDefinition.projectTitle(String(repeating: "x", count: 120)) == String(repeating: "x", count: 120), "exactly at the bound: no marker")
    #expect(ReminderInboxDefinition.projectTitle(String(repeating: "x", count: 121)) == String(repeating: "x", count: 119) + "\u{2026}")

    let padded = "check  CLI < 0.0.28 ".padding(toLength: 130, withPad: "y", startingAt: 0)
    let collapsedExpected = "check CLI < 0.0.28 ".padding(toLength: 119, withPad: "y", startingAt: 0) + "\u{2026}"
    #expect(ReminderInboxDefinition.projectTitle(padded) == collapsedExpected, "whitespace is collapsed before the bound is applied")

    let emojiAtCut = String(repeating: "x", count: 118) + "\u{1F600}" + String(repeating: "y", count: 10)
    #expect(ReminderInboxDefinition.projectTitle(emojiAtCut) == String(repeating: "x", count: 118) + "\u{2026}")
    #expect(ReminderInboxDefinition.projectTitle("first\nsecond\r\nthird") == "first second third")

    let store = ReminderInboxStore()
    for (revision, title) in [("8", long), ("9", "first\nsecond")] {
        let projected = try #require(ReminderInboxDefinition.projectTitle(title))
        let result = store.mint(
            sourceRef: ["kind": "reminder", "id": reminderId, "revision": revision],
            title: projected
        )
        guard case .ok(let item) = result else {
            Issue.record("expected mint")
            continue
        }
        #expect((item.title?.count ?? 0) <= 120)
        #expect(item.title?.rangeOfCharacter(from: CharacterSet.newlines.union(.controlCharacters)) == nil)
    }
    #expect(store.list().count == 2, "both legal Reminder titles mint exactly one item")
}

@Test func reminderInboxReplacementKeepsFirstOrderAcrossConcurrentMintAndList() async throws {
    let store = ReminderInboxStore()
    for (revision, title) in [("7", "first"), ("8", "second"), ("7", "replacement")] {
        guard case .ok = store.mint(sourceRef: ["kind": "reminder", "id": reminderId, "revision": revision], title: title) else {
            Issue.record("expected a valid reminder item")
            return
        }
    }
    let expected = ["reminder:\(reminderId):7", "reminder:\(reminderId):8"]
    #expect(store.list().map(\.itemId) == expected)
    #expect(store.list().map(\.title) == ["replacement", "second"])
    let snapshots = await withTaskGroup(of: [String].self, returning: [[String]].self) { group in
        for index in 0..<128 {
            group.addTask {
                let revision = index.isMultiple(of: 2) ? "7" : "8"
                _ = store.mint(sourceRef: ["kind": "reminder", "id": reminderId, "revision": revision], title: "update \(index)")
                return store.list().map(\.itemId)
            }
        }
        var snapshots: [[String]] = []
        for await snapshot in group { snapshots.append(snapshot) }
        return snapshots
    }
    #expect(snapshots.count == 128)
    #expect(snapshots.allSatisfy { $0 == expected })
    #expect(store.list().map(\.itemId) == expected)
}
