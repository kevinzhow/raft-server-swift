import NIOCore
import Synchronization

/// One completion gate for DNS/connect, command deadline and task cancellation.
/// No command is resubmitted when any of these races finishes the operation.
final class RedisSDKLifetime: Sendable {
    let promise: EventLoopPromise<RedisReply>
    private let eventLoop: any EventLoop
    private let commandTimeout: TimeAmount
    private let state = Mutex(State())

    private struct State {
        var finished = false
        var channel: (any Channel)?
        var connectTimer: Scheduled<Void>?
        var commandTimer: Scheduled<Void>?
    }

    init(eventLoop: any EventLoop, commandTimeout: TimeAmount) {
        self.eventLoop = eventLoop
        self.commandTimeout = commandTimeout
        promise = eventLoop.makePromise(of: RedisReply.self)
    }

    var isPending: Bool { state.withLock { !$0.finished } }

    func begin(connectTimeout: TimeAmount) {
        let timer = eventLoop.scheduleTask(in: connectTimeout) {
            self.finish(.failure(RedisError.connectionTimedOut))
        }
        let keep = state.withLock { owned in
            guard !owned.finished else { return false }
            owned.connectTimer = timer
            return true
        }
        if !keep { timer.cancel() }
    }

    func register(_ channel: any Channel) {
        let keep = state.withLock { owned in
            guard !owned.finished else { return false }
            owned.channel = channel
            return true
        }
        if !keep { channel.close(promise: nil) }
    }

    func connected() {
        let previous = state.withLock { owned -> Scheduled<Void>? in
            let previous = owned.connectTimer
            owned.connectTimer = nil
            return previous
        }
        previous?.cancel()
        let timer = eventLoop.scheduleTask(in: commandTimeout) {
            self.finish(.failure(RedisError.commandTimedOut))
        }
        let keep = state.withLock { owned in
            guard !owned.finished else { return false }
            owned.commandTimer = timer
            return true
        }
        if !keep { timer.cancel() }
    }

    func finish(_ result: Result<RedisReply, any Error>) {
        let resources = state.withLock { owned -> (Bool, (any Channel)?, Scheduled<Void>?, Scheduled<Void>?) in
            guard !owned.finished else { return (false, nil, nil, nil) }
            owned.finished = true
            let result = (true, owned.channel, owned.connectTimer, owned.commandTimer)
            owned.channel = nil
            owned.connectTimer = nil
            owned.commandTimer = nil
            return result
        }
        guard resources.0 else { return }
        resources.2?.cancel()
        resources.3?.cancel()
        if case .failure = result { resources.1?.close(promise: nil) }
        promise.completeWith(result)
    }
}

/// Limits aggregate received bytes before forwarding them to RediStack's decoder.
/// RediStack itself still owns declared-length allocations and protocol parsing.
final class RedisSDKByteBudget: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private var remaining: Int
    private let lifetime: RedisSDKLifetime

    init(maximumBytes: Int, lifetime: RedisSDKLifetime) {
        remaining = maximumBytes
        self.lifetime = lifetime
    }

    func channelActive(context: ChannelHandlerContext) {
        guard lifetime.isPending else {
            context.close(promise: nil)
            return
        }
        lifetime.connected()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard lifetime.isPending else {
            context.close(promise: nil)
            return
        }
        let buffer = unwrapInboundIn(data)
        guard buffer.readableBytes <= remaining else {
            lifetime.finish(.failure(RedisError.responseTooLarge))
            context.fireErrorCaught(RedisError.responseTooLarge)
            context.close(promise: nil)
            return
        }
        remaining -= buffer.readableBytes
        context.fireChannelRead(data)
    }
}
