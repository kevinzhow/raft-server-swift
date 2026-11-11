import Foundation
import Synchronization
import NIOCore
import RaftConnectAuth

/// One Engine.IO session. It outlives a single HTTP request or TCP connection
/// while polling, and can switch its transport to WebSocket after the probe.
/// Mutable state is guarded by one mutex; output is serialized by a single
/// drainer so frames and the close packet keep their order. Timers run on the
/// session's owner loop.
final class EngineIOSession: Sendable {
    let id: String
    let heartbeat: RealtimeHeartbeatConfiguration

    private let ownerLoop: any EventLoop
    private let cors: EngineIOCORS
    private let onClose: @Sendable (SocketIOSession?) -> Void
    private let socketIOHandler: @Sendable (String) -> Void

    private enum Transport: Sendable {
        case polling
        case websocket(any Channel)
    }

    private struct PendingPoll: Sendable {
        var connectionID: UUID
        /// The exact HTTP request this poll owns. The connection sequences its
        /// bytes; the session never writes an arbitrary channel position.
        var writer: EngineIOPollResponseWriter
        var origin: String?
        var userAgent: String?
        var keepAlive: Bool
    }

    private enum HeartbeatDeadline: Sendable {
        case ping
        case pong
    }

    private enum DrainAction: Sendable {
        case websocket(packets: [String], close: Bool, channel: any Channel)
        case poll(PendingPoll, body: String)
        case websocketClose(any Channel)
    }

    private struct State: Sendable {
        var transport: Transport = .polling
        var wsConnectionID: UUID?
        var upgrading = false
        var upgradeConnectionID: UUID?
        var upgradeChannel: (any Channel)?
        var probeReceived = false
        var upgraded = false
        var upgradeTimer: Scheduled<Void>?

        var pendingPoll: PendingPoll?
        var postConnectionID: UUID?
        var queue: [String] = []
        var closeWhenFlushed = false
        var terminalWritten = false
        var closed = false
        var finalized = false
        var draining = false
        var socketIO: SocketIOSession?

        var awaitingPong = false
        var pongDeadlineExtended = false
        var heartbeatStarted = false
        var heartbeatGeneration = 0
        var heartbeatTimer: Scheduled<Void>?
    }

    private let state = Mutex(State())

    init(
        id: String,
        heartbeat: RealtimeHeartbeatConfiguration,
        ownerLoop: any EventLoop,
        cors: EngineIOCORS,
        onClose: @escaping @Sendable (SocketIOSession?) -> Void,
        socketIOHandler: @escaping @Sendable (String) -> Void
    ) {
        self.id = id
        self.heartbeat = heartbeat
        self.ownerLoop = ownerLoop
        self.cors = cors
        self.onClose = onClose
        self.socketIOHandler = socketIOHandler
    }

    var isClosed: Bool {
        state.withLock { $0.closed || $0.finalized }
    }

    // MARK: - Opening

    func startPolling() {
        state.withLock { state in
            guard !state.closed else { return }
            state.transport = .polling
        }
        enqueue(engineIOOpenFrame(sid: id, upgrades: ["websocket"], heartbeat: heartbeat))
        startHeartbeat()
    }

    func startWebSocket(_ channel: any Channel, connectionID: UUID) {
        state.withLock { state in
            guard !state.closed else { return }
            state.transport = .websocket(channel)
            state.wsConnectionID = connectionID
        }
        enqueue(engineIOOpenFrame(sid: id, upgrades: [], heartbeat: heartbeat))
        startHeartbeat()
    }

    // MARK: - Socket.IO layer attachment

    func adopt(_ session: SocketIOSession) {
        state.withLock { state in
            state.socketIO = session
        }
    }

    // MARK: - HTTP polling

    enum PollAttachResult: Sendable {
        case accepted
        case overlap
        case unknownSid
        case wrongTransport
    }

    func attachPoll(
        connectionID: UUID, writer: EngineIOPollResponseWriter, origin: String?,
        userAgent: String?, keepAlive: Bool
    ) -> PollAttachResult {
        var result: PollAttachResult = .accepted
        var shouldDrain = false
        var probeNoop: PendingPoll?
        state.withLock { state in
            if state.closed || state.finalized {
                result = .unknownSid
                return
            }
            if case .websocket = state.transport {
                result = .wrongTransport
                return
            }
            if state.pendingPoll != nil {
                result = .overlap
                return
            }
            let poll = PendingPoll(
                connectionID: connectionID, writer: writer, origin: origin,
                userAgent: userAgent, keepAlive: keepAlive
            )
            if state.upgrading, state.probeReceived, state.queue.isEmpty, !state.closeWhenFlushed {
                // engine.io releases the polling cycle during an upgrade as
                // soon as the probe pong was written (the 100 ms fast-upgrade
                // loop checks `polling && writable`). A GET can arrive after
                // the probe because it is a different TCP connection, so the
                // probe itself cannot rely on a poll being attached already.
                probeNoop = poll
            } else {
                state.pendingPoll = poll
                if !state.queue.isEmpty || state.closeWhenFlushed {
                    shouldDrain = true
                }
            }
        }
        if result == .overlap {
            close()
            return result
        }
        if let probeNoop { writePollResponse(engineIONoopPacket, to: probeNoop) }
        if shouldDrain { startDrain() }
        return result
    }

    func pollConnectionClosed(_ connectionID: UUID) {
        var shouldClose = false
        state.withLock { state in
            guard let pending = state.pendingPoll, pending.connectionID == connectionID else { return }
            state.pendingPoll = nil
            shouldClose = !state.closed
        }
        if shouldClose { close() }
    }

    enum PostStartResult: Sendable {
        case accepted
        case overlap
        case unknownSid
        case wrongTransport
    }

    func beginPost(connectionID: UUID) -> PostStartResult {
        var result: PostStartResult = .accepted
        state.withLock { state in
            if state.closed || state.finalized {
                result = .unknownSid
                return
            }
            if case .websocket = state.transport {
                result = .wrongTransport
                return
            }
            if state.postConnectionID != nil {
                result = .overlap
                return
            }
            state.postConnectionID = connectionID
        }
        if result == .overlap { close() }
        return result
    }

    func endPost(connectionID: UUID) {
        state.withLock { state in
            if state.postConnectionID == connectionID { state.postConnectionID = nil }
        }
    }

    /// Processes the decoded payload of a polling POST. Returns only after the
    /// packets were handed to the same engine state machine the WebSocket
    /// transport uses.
    func receivePostPackets(_ packets: [String]) {
        for packet in packets {
            if !handleEnginePacket(packet) { break }
        }
    }

    // MARK: - WebSocket upgrade

    func startUpgrade(_ channel: any Channel, connectionID: UUID) {
        var accepted = true
        state.withLock { state in
            guard !state.closed, !state.upgrading, !state.upgraded else {
                accepted = false
                return
            }
            if case .websocket = state.transport {
                accepted = false
                return
            }
            state.upgrading = true
            state.upgradeConnectionID = connectionID
            state.upgradeChannel = channel
            state.probeReceived = false
        }
        guard accepted else {
            channel.close(promise: nil)
            return
        }
        scheduleUpgradeTimeout(connectionID: connectionID)
    }

    func handleWebSocketText(_ text: String, connectionID: UUID) {
        var upgrading = false
        var upgradeChannel: (any Channel)?
        var currentTransport = false
        state.withLock { state in
            if state.upgrading, state.upgradeConnectionID == connectionID {
                upgrading = true
                upgradeChannel = state.upgradeChannel
            } else if case .websocket = state.transport, state.wsConnectionID == connectionID {
                currentTransport = true
            }
        }
        if upgrading {
            guard let upgradeChannel else { return }
            if text == engineIOProbePingPacket {
                // engine.io@6.6.11 socket.js:249-256 answers every probe ping
                // on the upgrading transport with a probe pong. A repeated
                // probe is not an upgrade failure; it keeps the same
                // upgrading state and does not restart the upgrade timeout.
                state.withLock { state in
                    guard state.upgrading, state.upgradeConnectionID == connectionID else { return }
                    state.probeReceived = true
                }
                engineIOWrite(websocketTextFrame(engineIOProbePongPacket), to: upgradeChannel, closeAfterWrite: false)
                sendNoopToPendingPoll()
                return
            }
            if text == engineIOUpgradePacket {
                completeUpgrade(connectionID: connectionID)
                return
            }
            failUpgrade(connectionID: connectionID)
            return
        }
        if currentTransport {
            _ = handleEnginePacket(text)
        }
    }

    func websocketClosed(_ connectionID: UUID) {
        var wasUpgrade = false
        var wasCurrent = false
        state.withLock { state in
            if state.upgrading, state.upgradeConnectionID == connectionID {
                wasUpgrade = true
            } else if case .websocket = state.transport, state.wsConnectionID == connectionID {
                wasCurrent = true
            }
        }
        if wasUpgrade {
            failUpgrade(connectionID: connectionID)
        } else if wasCurrent {
            close()
        }
    }

    private func completeUpgrade(connectionID: UUID) {
        var pending: PendingPoll?
        var timer: Scheduled<Void>?
        var shouldDrain = false
        state.withLock { state in
            guard state.upgrading, state.upgradeConnectionID == connectionID,
                  state.probeReceived, let upgradeChannel = state.upgradeChannel else { return }
            pending = state.pendingPoll
            state.pendingPoll = nil
            state.transport = .websocket(upgradeChannel)
            state.wsConnectionID = connectionID
            state.upgrading = false
            state.upgraded = true
            state.probeReceived = false
            state.upgradeConnectionID = nil
            state.upgradeChannel = nil
            timer = state.upgradeTimer
            state.upgradeTimer = nil
            if !state.queue.isEmpty {
                shouldDrain = true
            }
        }
        timer?.cancel()
        if let pending {
            writePollResponse(engineIONoopPacket, to: pending)
        }
        if shouldDrain { startDrain() }
    }

    private func failUpgrade(connectionID: UUID) {
        var channel: (any Channel)?
        var timer: Scheduled<Void>?
        state.withLock { state in
            guard state.upgrading, state.upgradeConnectionID == connectionID else { return }
            channel = state.upgradeChannel
            timer = state.upgradeTimer
            state.upgrading = false
            state.upgradeConnectionID = nil
            state.upgradeChannel = nil
            state.probeReceived = false
            state.upgradeTimer = nil
        }
        timer?.cancel()
        channel?.close(promise: nil)
    }

    private func scheduleUpgradeTimeout(connectionID: UUID) {
        let task = ownerLoop.scheduleTask(in: .milliseconds(10_000)) { [weak self] in
            guard let self else { return }
            var channel: (any Channel)?
            var timer: Scheduled<Void>?
            self.state.withLock { state in
                guard state.upgrading, state.upgradeConnectionID == connectionID else { return }
                channel = state.upgradeChannel
                timer = state.upgradeTimer
                state.upgrading = false
                state.upgradeConnectionID = nil
                state.upgradeChannel = nil
                state.probeReceived = false
                state.upgradeTimer = nil
            }
            timer?.cancel()
            channel?.close(promise: nil)
        }
        state.withLock { state in
            guard state.upgrading, state.upgradeConnectionID == connectionID else {
                task.cancel()
                return
            }
            state.upgradeTimer = task
        }
    }

    private func sendNoopToPendingPoll() {
        var pending: PendingPoll?
        var shouldDrain = false
        state.withLock { state in
            guard state.upgrading, state.probeReceived else { return }
            guard let poll = state.pendingPoll else { return }
            guard state.queue.isEmpty, !state.closeWhenFlushed else {
                // A queued business frame or the terminal close packet is
                // already the polling cycle's response. Releasing that poll
                // with a noop would hold the frame until another GET.
                shouldDrain = true
                return
            }
            pending = poll
            state.pendingPoll = nil
        }
        if let pending { writePollResponse(engineIONoopPacket, to: pending) }
        if shouldDrain { startDrain() }
    }

    // MARK: - Engine packet handling

    /// Returns false when the transport is now closed and remaining packets in
    /// the same POST payload must not be interpreted.
    private func handleEnginePacket(_ packet: String) -> Bool {
        let type = packet.first
        switch type {
        case "3":
            receivePong()
            return true
        case "2":
            // engine.io 6.6.11 protocol v4: the server owns the ping direction.
            close()
            return false
        case "1":
            close()
            return false
        case "4":
            extendPongDeadlineOnce()
            let socketPacket = String(packet.dropFirst())
            socketIOHandler(socketPacket)
            return true
        case "b":
            // The application's realtime contract carries JSON text. A binary
            // engine message cannot be handed to the text Socket.IO layer.
            close()
            return false
        case "0", "5", "6":
            return true
        default:
            close()
            return false
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        var started = false
        state.withLock { state in
            guard !state.closed, !state.heartbeatStarted else { return }
            state.heartbeatStarted = true
            started = true
        }
        guard started else { return }
        armHeartbeat(afterMilliseconds: heartbeat.pingIntervalMilliseconds, deadline: .ping)
    }

    private func armHeartbeat(afterMilliseconds milliseconds: Int, deadline: HeartbeatDeadline) {
        var generation = 0
        state.withLock { state in
            guard !state.closed else { return }
            state.heartbeatGeneration += 1
            generation = state.heartbeatGeneration
            state.heartbeatTimer?.cancel()
            state.heartbeatTimer = nil
        }
        guard generation != 0 else { return }
        let scheduledGeneration = generation
        let task = ownerLoop.scheduleTask(in: .milliseconds(Int64(max(1, milliseconds)))) { [weak self] in
            guard let self else { return }
            self.heartbeatFired(generation: scheduledGeneration, deadline: deadline)
        }
        state.withLock { state in
            if state.closed || state.heartbeatGeneration != generation || state.finalized {
                task.cancel()
            } else {
                state.heartbeatTimer = task
            }
        }
    }

    private func heartbeatFired(generation: Int, deadline: HeartbeatDeadline) {
        var sendPing = false
        var timedOut = false
        state.withLock { state in
            guard !state.closed, state.heartbeatGeneration == generation, state.heartbeatStarted else { return }
            state.heartbeatTimer = nil
            switch deadline {
            case .ping:
                state.awaitingPong = true
                state.pongDeadlineExtended = false
                sendPing = true
            case .pong:
                state.awaitingPong = false
                timedOut = true
            }
        }
        if sendPing {
            enqueue(engineIOPingPacket)
            armHeartbeat(afterMilliseconds: heartbeat.pingTimeoutMilliseconds, deadline: .pong)
        } else if timedOut {
            close()
        }
    }

    private func receivePong() {
        var rearm = false
        state.withLock { state in
            guard !state.closed, state.heartbeatStarted else { return }
            state.awaitingPong = false
            state.pongDeadlineExtended = false
            rearm = true
        }
        if rearm {
            armHeartbeat(afterMilliseconds: heartbeat.pingIntervalMilliseconds, deadline: .ping)
        }
    }

    private func extendPongDeadlineOnce() {
        var rearm = false
        state.withLock { state in
            guard !state.closed, state.awaitingPong, !state.pongDeadlineExtended else { return }
            state.pongDeadlineExtended = true
            rearm = true
        }
        if rearm {
            armHeartbeat(afterMilliseconds: heartbeat.pingTimeoutMilliseconds, deadline: .pong)
        }
    }

    // MARK: - Output

    func enqueue(_ packet: String) {
        let accepted = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.queue.append(packet)
            return true
        }
        if accepted { startDrain() }
    }

    func enqueueFinal(_ packet: String) {
        let accepted = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.queue.append(packet)
            state.closeWhenFlushed = true
            state.heartbeatStarted = false
            state.heartbeatGeneration += 1
            state.heartbeatTimer?.cancel()
            state.heartbeatTimer = nil
            return true
        }
        if accepted { startDrain() }
    }

    func close() {
        var upgradeChannel: (any Channel)?
        state.withLock { state in
            guard !state.closed else { return }
            state.closed = true
            state.closeWhenFlushed = false
            state.queue.removeAll()
            state.postConnectionID = nil
            state.upgrading = false
            state.upgradeConnectionID = nil
            upgradeChannel = state.upgradeChannel
            state.upgradeChannel = nil
            state.probeReceived = false
            state.heartbeatStarted = false
            state.heartbeatGeneration += 1
            state.heartbeatTimer?.cancel()
            state.heartbeatTimer = nil
            state.upgradeTimer?.cancel()
            state.upgradeTimer = nil
        }
        upgradeChannel?.close(promise: nil)
        startDrain()
    }

    private func startDrain() {
        let shouldDrain = state.withLock { state in
            guard !state.draining, !state.finalized else { return false }
            state.draining = true
            return true
        }
        if shouldDrain {
            // All transport writes run on the session's owner loop. The
            // mutex above only claims the single drainer.
            ownerLoop.execute { [weak self] in
                self?.drainLoop()
            }
        }
    }

    private func drainLoop() {
        var action: DrainAction?
        var finalize = false
        state.withLock { state in
            if state.finalized {
                state.draining = false
                return
            }
            if state.closed {
                if state.terminalWritten {
                    state.draining = false
                    finalize = true
                    return
                }
                if let poll = state.pendingPoll {
                    state.pendingPoll = nil
                    state.terminalWritten = true
                    action = .poll(poll, body: engineIOClosePacket)
                    return
                }
                if case .websocket(let channel) = state.transport {
                    state.terminalWritten = true
                    action = .websocketClose(channel)
                    return
                }
                state.terminalWritten = true
                state.draining = false
                finalize = true
                return
            }
            switch state.transport {
            case .polling:
                guard let poll = state.pendingPoll else {
                    state.draining = false
                    return
                }
                guard !state.queue.isEmpty || state.closeWhenFlushed else {
                    state.draining = false
                    return
                }
                let body = state.queue.joined(separator: "\u{1e}")
                state.queue.removeAll()
                state.pendingPoll = nil
                if state.closeWhenFlushed {
                    state.terminalWritten = true
                    state.closed = true
                }
                action = .poll(poll, body: body)
            case .websocket(let channel):
                guard !state.queue.isEmpty || state.closeWhenFlushed else {
                    state.draining = false
                    return
                }
                let packets = Array(state.queue.prefix(64))
                state.queue.removeFirst(packets.count)
                let close = state.closeWhenFlushed && state.queue.isEmpty
                if close {
                    state.terminalWritten = true
                    state.closed = true
                }
                action = .websocket(packets: packets, close: close, channel: channel)
            }
        }
        if finalize {
            finalizeIfNeeded()
            return
        }
        guard let action else { return }
        perform(action)
        if state.withLock({ $0.closed && $0.terminalWritten }) {
            finalizeIfNeeded()
            return
        }
        // Yield to the selector between batches. A busy channel room would
        // otherwise keep one synchronous write loop from accepting another
        // socket's handshake.
        let more = state.withLock { state -> Bool in
            guard !state.finalized else {
                state.draining = false
                return false
            }
            if state.closed { return true }
            guard case .websocket = state.transport else {
                state.draining = false
                return false
            }
            if state.queue.isEmpty {
                state.draining = false
                return false
            }
            return true
        }
        if more {
            _ = ownerLoop.scheduleTask(in: .milliseconds(1)) { [weak self] in
                self?.drainLoop()
            }
        }
    }

    /// A polling response is one HTTP exchange. `Connection: close` means the
    /// response's TCP connection ends after the body, but the Engine.IO
    /// session continues (or closes) on its own state, not on this channel.
    private func writePollResponse(_ body: String, to pending: PendingPoll) {
        let bytes = engineIOPollResponseBytes(
            body: body, cors: cors, origin: pending.origin,
            userAgent: pending.userAgent, keepAlive: pending.keepAlive
        )
        pending.writer.write(bytes: bytes, closeAfter: !pending.keepAlive)
    }

    private func perform(_ action: DrainAction) {
        switch action {
        case .websocket(let packets, let close, let channel):
            var bytes: [UInt8] = []
            for packet in packets {
                bytes.append(contentsOf: websocketTextFrame(packet))
            }
            if close {
                engineIOWrite(bytes, to: channel, closeAfterWrite: true)
            } else if !bytes.isEmpty {
                engineIOWrite(bytes, to: channel, closeAfterWrite: false)
            }
        case .poll(let pending, let body):
            writePollResponse(body, to: pending)
        case .websocketClose(let channel):
            channel.close(promise: nil)
        }
    }

    private func finalizeIfNeeded() {
        var socketIO: SocketIOSession?
        var heartbeatTimer: Scheduled<Void>?
        var upgradeTimer: Scheduled<Void>?
        var upgradeChannel: (any Channel)?
        let shouldFinalize = state.withLock { state in
            guard state.closed, !state.finalized else { return false }
            state.finalized = true
            state.draining = false
            socketIO = state.socketIO
            state.socketIO = nil
            heartbeatTimer = state.heartbeatTimer
            state.heartbeatTimer = nil
            upgradeTimer = state.upgradeTimer
            state.upgradeTimer = nil
            // A terminal Socket.IO frame can arrive while the WebSocket probe
            // is still in flight. The session is gone, so the probe transport
            // must not outlive it waiting for an upgrade packet.
            upgradeChannel = state.upgradeChannel
            state.upgradeChannel = nil
            state.upgrading = false
            state.upgradeConnectionID = nil
            state.probeReceived = false
            return true
        }
        guard shouldFinalize else { return }
        heartbeatTimer?.cancel()
        upgradeTimer?.cancel()
        upgradeChannel?.close(promise: nil)
        socketIO?.markClosed()
        onClose(socketIO)
    }
}
