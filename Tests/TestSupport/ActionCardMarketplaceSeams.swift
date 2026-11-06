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
            directory.messagesAndThreadsStore.appendMessage(message, ledger: .init(oauth: directory.oauth))
        },
        serializeReceipt: { payload in
            guard case .object = payload else { return "{}" }
            return LegacySortedJSON.render(payload) ?? "{}"
        },
        now: now,
        makeId: makeId
    )
}
