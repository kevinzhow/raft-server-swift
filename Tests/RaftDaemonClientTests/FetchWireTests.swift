import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import RaftDaemonClient

@Suite(.serialized)
struct FetchWireSuite {
@Test func directHangIsBoundedAndDoesNotEvictTheOtherLane() async throws {
    let origin = try await ScriptedOrigin.start(slowDelayMs: 300)
    let pool = DaemonFetchPool()
    let env = ["SLOCK_DAEMON_FETCH_PRE_RESPONSE_TIMEOUT_MS": "100"]
    let target = "http://127.0.0.1:\(origin.port)"
    let lane = "agent-credential-proxy-test"
    let sibling = "daemon-backlog-test"
    let original = pool.buildIsolatedFetchDispatcher(target, isolationKey: lane, environment: env)
    let siblingPool = pool.buildIsolatedFetchDispatcher(target, isolationKey: sibling, environment: env)

    let started = ContinuousClock.now
    let failure = await #expect(throws: DaemonFetchFailure.self) {
        try await pool.perform("\(target)/hang", method: "GET", environment: env, isolationKey: lane)
    }
    let elapsed = started.duration(to: .now)
    #expect(failure?.code == "UND_ERR_HEADERS_TIMEOUT")
    #expect(elapsed < .seconds(2))
    #expect(elapsed > .milliseconds(50))
    #expect(pool.buildIsolatedFetchDispatcher(target, isolationKey: lane, environment: env) != original)
    #expect(pool.buildIsolatedFetchDispatcher(target, isolationKey: sibling, environment: env) == siblingPool)

    let slow = try await pool.perform("\(target)/slow", method: "GET", environment: env, isolationKey: lane)
    #expect(slow.status == 200)
    #expect(slow.body == "{\"ok\":true}")
    await origin.stop()
}

@Test func connectTunnelSilenceIsTheUndiciConnectTimeout() async throws {
    let sink = try await SinkProxy.start()
    let pool = DaemonFetchPool()
    let env = [
        "HTTPS_PROXY": "http://127.0.0.1:\(sink.port)",
        "SLOCK_DAEMON_FETCH_PRE_RESPONSE_TIMEOUT_MS": "300",
    ]
    let url = "https://api.slock.invalid/internal/agent-api/send"
    let before = pool.buildFetchDispatcher(url, environment: env)
    #expect(before != nil)
    let started = ContinuousClock.now
    let failure = await #expect(throws: DaemonFetchFailure.self) {
        try await pool.perform(url, method: "POST", environment: env)
    }
    let elapsed = started.duration(to: .now)
    #expect(failure?.code == "UND_ERR_CONNECT_TIMEOUT")
    #expect(elapsed < .seconds(5))
    #expect(elapsed > .milliseconds(200))
    #expect(pool.buildFetchDispatcher(url, environment: env) != before)
    await sink.stop()
}

@Test func headersHangThroughATunnelIsTheUndiciHeadersTimeout() async throws {
    let origin = try await ScriptedOrigin.start(slowDelayMs: 700, hangOnly: true)
    let proxy = try await TunnelProxy.start()
    let pool = DaemonFetchPool()
    let env = [
        "HTTP_PROXY": "http://127.0.0.1:\(proxy.port)",
        "SLOCK_DAEMON_FETCH_PRE_RESPONSE_TIMEOUT_MS": "300",
    ]
    let started = ContinuousClock.now
    let failure = await #expect(throws: DaemonFetchFailure.self) {
        try await pool.perform("http://127.0.0.1:\(origin.port)/hang", method: "GET", environment: env)
    }
    let elapsed = started.duration(to: .now)
    #expect(failure?.code == "UND_ERR_HEADERS_TIMEOUT")
    #expect(elapsed < .seconds(5))
    #expect(elapsed > .milliseconds(200))
    await origin.stop()
    await proxy.stop()
}

@Test func aSlowBodySurvivesThePreResponseTimeout() async throws {
    let origin = try await ScriptedOrigin.start(slowDelayMs: 700)
    let proxy = try await TunnelProxy.start()
    let pool = DaemonFetchPool()
    let env = [
        "HTTP_PROXY": "http://127.0.0.1:\(proxy.port)",
        "SLOCK_DAEMON_FETCH_PRE_RESPONSE_TIMEOUT_MS": "300",
    ]
    let response = try await pool.perform("http://127.0.0.1:\(origin.port)/slow", method: "GET", environment: env)
    #expect(response.status == 200)
    #expect(response.body == "{\"ok\":true}")
    await origin.stop()
    await proxy.stop()
}

@Test func aServer500ThroughTheTunnelDoesNotEvictTheDispatcher() async throws {
    let body = "{\"error\":\"boom\"}"
    let origin = try await ScriptedOrigin.start(slowDelayMs: 0, status: 500, body: body)
    let proxy = try await TunnelProxy.start()
    let pool = DaemonFetchPool()
    let env = [
        "HTTP_PROXY": "http://127.0.0.1:\(proxy.port)",
        "SLOCK_DAEMON_FETCH_PRE_RESPONSE_TIMEOUT_MS": "300",
    ]
    let url = "http://127.0.0.1:\(origin.port)/boom"
    let before = pool.buildFetchDispatcher(url, environment: env)
    let response = try await pool.perform(url, method: "POST", environment: env)
    #expect(response.status == 500)
    #expect(response.body == body)
    #expect(pool.buildFetchDispatcher(url, environment: env) == before)
    await origin.stop()
    await proxy.stop()
}

@Test func aServer404ThroughTheTunnelDoesNotEvictTheDispatcher() async throws {
    let body = "{\"error\":\"not_found\"}"
    let origin = try await ScriptedOrigin.start(slowDelayMs: 0, status: 404, body: body)
    let proxy = try await TunnelProxy.start()
    let pool = DaemonFetchPool()
    let env = [
        "HTTP_PROXY": "http://127.0.0.1:\(proxy.port)",
        "SLOCK_DAEMON_FETCH_PRE_RESPONSE_TIMEOUT_MS": "300",
    ]
    let url = "http://127.0.0.1:\(origin.port)/missing"
    let before = pool.buildFetchDispatcher(url, environment: env)
    let response = try await pool.perform(url, method: "GET", environment: env)
    #expect(response.status == 404)
    #expect(response.body == body)
    #expect(pool.buildFetchDispatcher(url, environment: env) == before)
    await origin.stop()
    await proxy.stop()
}
}

private final class ScriptedOrigin {
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let slowDelayMs: Int
    private let hangOnly: Bool

    private init(port: Int, group: MultiThreadedEventLoopGroup, channel: any Channel, slowDelayMs: Int, hangOnly: Bool) {
        self.port = port
        self.group = group
        self.channel = channel
        self.slowDelayMs = slowDelayMs
        self.hangOnly = hangOnly
    }

    static func start(
        slowDelayMs: Int,
        hangOnly: Bool = false,
        status: Int = 200,
        body: String = "{\"ok\":true}"
    ) async throws -> ScriptedOrigin {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    OriginHandler(slowDelayMs: slowDelayMs, hangOnly: hangOnly, status: status, body: body)
                )
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = channel.localAddress?.port else { throw DaemonFetchFailure.connectTimeout }
        return ScriptedOrigin(port: port, group: group, channel: channel, slowDelayMs: slowDelayMs, hangOnly: hangOnly)
    }

    func stop() async {
        await shutdownListeningGroup(group)
    }
}

private final class OriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let slowDelayMs: Int
    private let hangOnly: Bool
    private let status: Int
    private let body: String
    private var buffer = ByteBuffer()
    private var answered = false

    init(slowDelayMs: Int, hangOnly: Bool, status: Int, body: String) {
        self.slowDelayMs = slowDelayMs
        self.hangOnly = hangOnly
        self.status = status
        self.body = body
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inbound = unwrapInboundIn(data)
        buffer.writeBuffer(&inbound)
        guard !answered, headerReady(buffer) else { return }
        let text = String(buffer: buffer)
        answered = true
        if text.contains(" /hang ") || hangOnly { return }
        let payload = body
        let head = "HTTP/1.1 \(status) OK\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n"
        let delay = slowDelayMs
        if delay == 0 {
            let message = context.channel.allocator.buffer(string: head + payload)
            context.writeAndFlush(self.wrapOutboundOut(message), promise: nil)
            context.close(promise: nil)
            return
        }
        let headers = context.channel.allocator.buffer(string: head)
        context.writeAndFlush(self.wrapOutboundOut(headers), promise: nil)
        let loop = context.eventLoop
        let channel = context.channel
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delay)) {
            loop.execute {
                let rest = channel.allocator.buffer(string: payload)
                channel.writeAndFlush(rest, promise: nil)
                channel.close(promise: nil)
            }
        }
    }
}

private final class SinkProxy {
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel

    private init(port: Int, group: MultiThreadedEventLoopGroup, channel: any Channel) {
        self.port = port
        self.group = group
        self.channel = channel
    }

    static func start() async throws -> SinkProxy {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(SinkHandler())
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = channel.localAddress?.port else { throw DaemonFetchFailure.connectTimeout }
        return SinkProxy(port: port, group: group, channel: channel)
    }

    func stop() async {
        await shutdownListeningGroup(group)
    }
}

private final class SinkHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var answered = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !answered else { return }
        answered = true
        let reply = context.channel.allocator.buffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n")
        context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
    }
}

private final class TunnelProxy {
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel

    private init(port: Int, group: MultiThreadedEventLoopGroup, channel: any Channel) {
        self.port = port
        self.group = group
        self.channel = channel
    }

    static func start() async throws -> TunnelProxy {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(TunnelHandler(group: group))
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = channel.localAddress?.port else { throw DaemonFetchFailure.connectTimeout }
        return TunnelProxy(port: port, group: group, channel: channel)
    }

    func stop() async {
        await shutdownListeningGroup(group)
    }
}

private final class TunnelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let group: MultiThreadedEventLoopGroup
    private var buffer = ByteBuffer()
    private var upstream: (any Channel)?

    init(group: MultiThreadedEventLoopGroup) {
        self.group = group
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inbound = unwrapInboundIn(data)
        if let upstream {
            upstream.writeAndFlush(inbound, promise: nil)
            return
        }
        buffer.writeBuffer(&inbound)
        guard headerReady(buffer), let request = String(buffer: buffer).split(separator: "\r\n").first else { return }
        let parts = request.split(separator: " ")
        guard parts.count >= 2, parts[0] == "CONNECT" else { return }
        let hostPort = String(parts[1])
        guard let colon = hostPort.lastIndex(of: ":"), let port = Int(hostPort[hostPort.index(after: colon)...]) else { return }
        let host = String(hostPort[..<colon])
        ClientBootstrap(group: group).connect(host: host, port: port).whenSuccess { upstream in
            self.upstream = upstream
            let reply = context.channel.allocator.buffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n")
            context.writeAndFlush(self.wrapOutboundOut(reply), promise: nil)
            _ = upstream.pipeline.addHandler(UpstreamBridge(client: context.channel))
        }
    }
}

private final class UpstreamBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let client: any Channel
    init(client: any Channel) { self.client = client }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let inbound = unwrapInboundIn(data)
        client.writeAndFlush(inbound, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        client.close(promise: nil)
    }
}

private func shutdownListeningGroup(_ group: MultiThreadedEventLoopGroup) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            group.shutdownGracefully { _ in
                continuation.resume()
            }
        }
    }
}

private func headerReady(_ buffer: ByteBuffer) -> Bool {
    let start = buffer.readerIndex
    let end = buffer.writerIndex
    guard end - start >= 4 else { return false }
    var index = start
    while index + 3 < end {
        if buffer.getInteger(at: index, as: UInt8.self) == 13,
           buffer.getInteger(at: index + 1, as: UInt8.self) == 10,
           buffer.getInteger(at: index + 2, as: UInt8.self) == 13,
           buffer.getInteger(at: index + 3, as: UInt8.self) == 10 {
            return true
        }
        index += 1
    }
    return false
}
