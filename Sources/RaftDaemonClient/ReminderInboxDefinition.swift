import Foundation
import Synchronization

/// The system.reminder app inbox definition: OS-minted identity/action for
/// "due" notifications, strict source-ref validation, and a visibly bounded
/// single-line preview. Ported from the upstream daemon reminder app.
public enum ReminderInboxDefinition {
    public static let appId = "system.reminder"
    public static let dueNotificationClass = "due"
    public static let previewMaxChars = 120
    public static let truncationMarker = "\u{2026}"
    public static let retention = "until_explicit_ack"
    public static let ackCommandId = "reminder.ack"

    public struct SourceRef: Sendable, Equatable {
        public var kind: String
        public var id: String
        public var revision: String
    }

    public enum NormalizeResult: Sendable, Equatable {
        case ok(SourceRef)
        case invalid(String)
    }

    static let sourceRefKeys: Set<String> = ["kind", "id", "revision"]

    static func isUUID(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isPositiveInteger(_ value: String) -> Bool {
        value.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil
    }

    public static func normalizeDueSourceRef(_ raw: Any?) -> NormalizeResult {
        guard let value = raw as? [String: Any] else {
            return .invalid("reminder sourceRef must be {kind,id,revision}")
        }
        if value.keys.contains(where: { !sourceRefKeys.contains($0) }) {
            return .invalid("reminder sourceRef contains unknown fields")
        }
        guard value["kind"] as? String == "reminder" else {
            return .invalid("reminder sourceRef.kind must be reminder")
        }
        guard let id = value["id"] as? String, isUUID(id) else {
            return .invalid("reminder sourceRef.id must be a UUID")
        }
        guard let revision = value["revision"] as? String, isPositiveInteger(revision) else {
            return .invalid("reminder sourceRef.revision must be a positive integer")
        }
        return .ok(SourceRef(kind: "reminder", id: id, revision: revision))
    }

    public static func itemId(for ref: SourceRef) -> String? {
        guard ref.kind == "reminder" else { return nil }
        return "reminder:\(ref.id):\(ref.revision)"
    }

    static func shortId(_ id: String) -> String {
        String(id.replacingOccurrences(of: "-", with: "").prefix(8))
    }

    /// Collapses control/whitespace runs, trims, and bounds the preview with a
    /// visible marker that never splits a surrogate pair.
    public static func projectTitle(_ title: String) -> String? {
        let scalars = Array(title.unicodeScalars)
        var collapsed: [UnicodeScalar] = []
        var pendingSpace = false
        for scalar in scalars {
            let isControl = (scalar.value <= 0x1F) || scalar.value == 0x7F
            let isSpace = isControl || CharacterSet.whitespaces.contains(scalar)
            if isSpace {
                pendingSpace = !collapsed.isEmpty
                continue
            }
            if pendingSpace {
                collapsed.append(" ")
                pendingSpace = false
            }
            collapsed.append(scalar)
        }
        if collapsed.isEmpty { return nil }
        if collapsed.count <= previewMaxChars { return String(String.UnicodeScalarView(collapsed)) }
        let limit = previewMaxChars - truncationMarker.unicodeScalars.count
        var used = 0
        var cut = 0
        while cut < collapsed.count {
            let width = collapsed[cut].value > 0xFFFF ? 2 : 1
            if used + width > limit { break }
            used += width
            cut += 1
        }
        let prefix = String(String.UnicodeScalarView(collapsed.prefix(cut)))
        return prefix + truncationMarker
    }

    public struct MintItem: Sendable, Equatable {
        public var itemId: String
        public var appId: String
        public var notificationClass: String
        public var sourceRef: SourceRef
        public var title: String?
        public var retention: String
        public var actionCli: String
        public var primaryActionKind: String
        public var primaryActionCommandId: String
    }

    public enum MintResult: Sendable, Equatable {
        case ok(MintItem)
        case invalidSourceRef
        case invalidPrimaryAction
    }

    static func itemIdString(_ ref: SourceRef) -> String {
        "reminder:\(ref.id):\(ref.revision)"
    }

    public static func mint(
        appId: String,
        notificationClass: String,
        sourceRef: Any?,
        title: String? = nil,
        requestedPrimaryAction: [String: Any]? = nil
    ) -> MintResult {
        guard appId == self.appId, notificationClass == dueNotificationClass else {
            return .invalidSourceRef
        }
        switch normalizeDueSourceRef(sourceRef) {
        case .invalid:
            return .invalidSourceRef
        case .ok(let ref):
            if let requested = requestedPrimaryAction {
                guard requested["kind"] as? String == "run_command",
                      requested["commandId"] as? String == ackCommandId
                else { return .invalidPrimaryAction }
            }
            let item = MintItem(
                itemId: itemIdString(ref), appId: appId, notificationClass: notificationClass,
                sourceRef: ref, title: title,
                retention: retention,
                actionCli: "raft reminder ack --id \(shortId(ref.id)) --revision \(ref.revision)",
                primaryActionKind: "run_command", primaryActionCommandId: ackCommandId
            )
            return .ok(item)
        }
    }

    public static func isDueInboxItem(_ item: MintItem) -> Bool {
        item.appId == appId && item.notificationClass == dueNotificationClass
            && item.sourceRef.kind == "reminder"
    }
}

/// The app-inbox store for the reminder registry: mints items and lists them.
public final class ReminderInboxStore: Sendable {
    private struct State: Sendable {
        var items: [String: ReminderInboxDefinition.MintItem] = [:]
        var order: [String] = []
    }
    private let state = Mutex(State())

    public init() {}

    public func mint(
        appId: String = ReminderInboxDefinition.appId,
        notificationClass: String = ReminderInboxDefinition.dueNotificationClass,
        sourceRef: Any?,
        title: String? = nil,
        requestedPrimaryAction: [String: Any]? = nil
    ) -> ReminderInboxDefinition.MintResult {
        let result = ReminderInboxDefinition.mint(
            appId: appId, notificationClass: notificationClass,
            sourceRef: sourceRef, title: title, requestedPrimaryAction: requestedPrimaryAction
        )
        if case .ok(let item) = result {
            state.withLock {
                if $0.items[item.itemId] == nil { $0.order.append(item.itemId) }
                $0.items[item.itemId] = item
            }
        }
        return result
    }

    public func list() -> [ReminderInboxDefinition.MintItem] {
        state.withLock { snapshot in
            snapshot.order.compactMap { snapshot.items[$0] }
        }
    }
}
