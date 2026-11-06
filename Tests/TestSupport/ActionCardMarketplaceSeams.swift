import Foundation
import RaftShared
@testable import RaftHTTP

/// Builds the marketplace service against a directory's real stores with a
/// deterministic clock/id sequence. The two unmigrated bridges (message append
/// and receipt serialization) are wired the way the production accessor does.
public func makeActionCardMarketplaceService(
    directory: EmailLoginDirectory,
    idempotency: ActionCardTaskIdempotency = .disabled,
    now: @escaping @Sendable () -> Date = { Date() },
    makeId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
) -> ActionCardMarketplaceService {
    ActionCardMarketplaceService(
        tasks: directory.tasksAndRemindersStore,
        messages: directory.messagesAndThreadsStore,
        inboxFacts: directory.inboxFactStore,
        channels: directory.serversAndChannelsStore,
        accounts: directory.authProfileStore,
        agents: directory.agentsRuntimeStore,
        machines: directory.machinesAndComputersStore,
        cards: directory.managedMCPAndCardsStore,
        oauth: directory.oauth,
        locator: FeedbackLocatorService(directory: directory),
        idempotency: idempotency,
        appendHumanMessage: { message in
            directory.lock.lock()
            let seq = directory.appendHumanMessageLocked(message)
            directory.lock.unlock()
            return seq
        },
        serializeReceipt: { payload in
            guard let object = marketplaceLegacyJSONObject(payload) as? [String: Any] else { return "{}" }
            return EmailLoginDirectory.serializeJSON(object)
        },
        now: now,
        makeId: makeId
    )
}

private func marketplaceLegacyJSONObject(_ value: JSONValue) -> Any {
    switch value {
    case .object(let members):
        return members.mapValues(marketplaceLegacyJSONObject)
    case .array(let values):
        return values.map(marketplaceLegacyJSONObject)
    case .string(let string):
        return string
    case .number(let number):
        return number
    case .integer(let integer):
        return integer
    case .bool(let boolean):
        return boolean
    case .null:
        return NSNull()
    }
}
