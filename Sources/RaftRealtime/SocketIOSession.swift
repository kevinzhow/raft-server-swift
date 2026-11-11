import Foundation
import Synchronization

/// The Socket.IO namespace connection. It owns rooms and admission state; the
/// engine session owns transport output and close ordering. The output
/// closures capture the engine weakly, so the transport can keep the session
/// for hub fanout without a retain cycle.
final class SocketIOSession: Sendable {
    let id: String
    let userId: String
    let serverId: String?
    let clientKind: SocketClientKind
    let familyId: String?

    private struct State: Sendable {
        var rooms: Set<String> = []
        var admitted = true
        var closed = false
    }

    private let state = Mutex(State())
    // Serializes the admission check and the enqueue. `sendAndClose` must
    // observe the closed flag before any later `send` appends a frame after
    // the terminal one.
    private let delivery = Mutex(())
    private let sendPacket: @Sendable (String) -> Void
    private let sendFinalPacket: @Sendable (String) -> Void
    private let closeTransport: @Sendable () -> Void

    init(
        id: String,
        userId: String,
        serverId: String?,
        clientKind: SocketClientKind,
        familyId: String?,
        pending: Bool = false,
        send: @escaping @Sendable (String) -> Void,
        sendAndClose: @escaping @Sendable (String) -> Void,
        close: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.userId = userId
        self.serverId = serverId
        self.clientKind = clientKind
        self.familyId = familyId
        self.sendPacket = send
        self.sendFinalPacket = sendAndClose
        self.closeTransport = close
        if pending { state.withLock { $0.admitted = false } }
    }

    /// Transport phase only; the actual auth and visibility reads already ran.
    func admit() -> Bool {
        state.withLock { state in
            guard !state.closed else { return false }
            state.admitted = true
            return true
        }
    }

    var isClosed: Bool { state.withLock { $0.closed } }

    func hasRoom(_ room: String) -> Bool {
        state.withLock { $0.admitted && !$0.closed && $0.rooms.contains(room) }
    }

    func join(_ newRooms: [String]) {
        guard !newRooms.isEmpty else { return }
        state.withLock { state in
            guard !state.closed else { return }
            state.rooms.formUnion(newRooms)
        }
    }

    func leave(_ room: String) {
        _ = state.withLock { $0.rooms.remove(room) }
    }

    func leave(_ leavingRooms: [String]) {
        guard !leavingRooms.isEmpty else { return }
        state.withLock { $0.rooms.subtract(leavingRooms) }
    }

    func markClosed() {
        state.withLock { $0.closed = true }
    }

    func send(_ text: String) {
        delivery.withLock { _ in
            let canSend = state.withLock { $0.admitted && !$0.closed }
            if canSend { sendPacket(text) }
        }
    }

    func close() {
        delivery.withLock { _ in
            let shouldClose = state.withLock { state in
                guard !state.closed else { return false }
                state.closed = true
                return true
            }
            if shouldClose { closeTransport() }
        }
    }

    func sendAndClose(_ text: String) {
        delivery.withLock { _ in
            let action = state.withLock { state -> UInt8 in
                guard !state.closed else { return 0 }
                guard state.admitted else {
                    state.closed = true
                    return 1
                }
                state.closed = true
                return 2
            }
            switch action {
            case 2: sendFinalPacket(text)
            case 1: closeTransport()
            default: break
            }
        }
    }
}
