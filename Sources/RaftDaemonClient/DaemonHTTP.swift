import Foundation
import NIOCore
import NIOPosix

/// HTTP/1.1 fetch used by `daemonFetch`.
///
/// A proxy opens a CONNECT tunnel. `connectTimeoutMs` bounds that tunnel,
/// including the silent stretch after `200 Connection Established` on HTTPS.
/// `headersTimeoutMs` bounds only the wait for response headers. The body is
/// not cut by either timer. Timeouts use the undici cause codes the daemon
/// tests assert.

public enum DaemonFetchFailure: Error, Equatable, Sendable {
    case connectTimeout
    case headersTimeout

    public var code: String {
        switch self {
        case .connectTimeout: "UND_ERR_CONNECT_TIMEOUT"
        case .headersTimeout: "UND_ERR_HEADERS_TIMEOUT"
        }
    }
}

enum DaemonHTTP {
    static func execute(targetURL: String, method: String, dispatcher: DaemonDispatcher) async throws -> DaemonFetchResponse {
        guard let target = Endpoint(targetURL) else { throw DaemonFetchFailure.connectTimeout }
        let proxy = dispatcher.proxyURL.flatMap(Endpoint.init)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let box = CompletionBox()
        let handler = ExchangeHandler(
            target: target,
            proxy: proxy,
            method: method,
            connectTimeoutMs: dispatcher.connectTimeoutMs,
            headersTimeoutMs: dispatcher.headersTimeoutMs,
            box: box
        )
        let host = proxy?.host ?? target.host
        let port = proxy?.port ?? target.port
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.milliseconds(Int64(dispatcher.connectTimeoutMs)))
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }
        // `EventLoopFuture.get()` resumes on the event loop. Waiting for
        // `shutdownGracefully` from that same thread joins the thread and
        // never returns. The completion box resumes on a dispatch queue, and
        // the group is shut down only after that resume.
        let outcome: Result<DaemonFetchResponse, DaemonFetchFailure>
        do {
            _ = try await bootstrap.connect(host: host, port: port).get()
            outcome = await withCheckedContinuation { continuation in
                box.install(continuation)
            }
        } catch {
            outcome = .failure(.connectTimeout)
        }
        await shutdownOffLoop(group)
        return try outcome.get()
    }
}

private func shutdownOffLoop(_ group: MultiThreadedEventLoopGroup) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            group.shutdownGracefully { _ in
                continuation.resume()
            }
        }
    }
}

private struct Endpoint {
    var host: String
    var port: Int
    var scheme: String
    var path: String

    init?(_ raw: String) {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme,
              let host = components.host
        else { return nil }
        let port = components.port ?? (scheme == "https" || scheme == "wss" ? 443 : 80)
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        self.host = host
        self.port = port
        self.scheme = scheme
        self.path = path + query
    }

    var secure: Bool { scheme == "https" || scheme == "wss" }
}

/// Resumes the fetch exactly once, and only from a dispatch queue.
/// Resuming on the event loop parks the caller on the thread that must
/// later shut the group down.
private final class CompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<DaemonFetchResponse, DaemonFetchFailure>, Never>?
    private var result: Result<DaemonFetchResponse, DaemonFetchFailure>?

    func install(_ continuation: CheckedContinuation<Result<DaemonFetchResponse, DaemonFetchFailure>, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            DispatchQueue.global().async {
                continuation.resume(returning: result)
            }
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<DaemonFetchResponse, DaemonFetchFailure>) {
        lock.lock()
        if self.result != nil {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        DispatchQueue.global().async {
            continuation.resume(returning: result)
        }
    }
}

private final class ExchangeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let target: Endpoint
    private let proxy: Endpoint?
    private let method: String
    private let connectTimeoutMs: Int
    private let headersTimeoutMs: Int
    private let box: CompletionBox
    private var buffer = ByteBuffer()
    private var phase: Phase
    private var timerGeneration = 0
    private var done = false
    private let stateLock = NSLock()
    private var status = 0
    private var headers: [String: String] = [:]
    private var body = Data()
    private var bodyMode: BodyMode = .none

    private enum Phase {
        case connect
        case tls
        case headers
        case body
    }

    private enum BodyMode {
        case none
        case length(Int)
        case chunkSize
        case chunkData(Int)
        case chunkEnding
        case chunkTrailer
    }

    init(
        target: Endpoint,
        proxy: Endpoint?,
        method: String,
        connectTimeoutMs: Int,
        headersTimeoutMs: Int,
        box: CompletionBox
    ) {
        self.target = target
        self.proxy = proxy
        self.method = method
        self.connectTimeoutMs = connectTimeoutMs
        self.headersTimeoutMs = headersTimeoutMs
        self.box = box
        self.phase = proxy == nil ? .headers : .connect
    }

    func channelActive(context: ChannelHandlerContext) {
        if proxy != nil {
            arm(after: connectTimeoutMs, error: .connectTimeout)
            write(context, "CONNECT \(target.host):\(target.port) HTTP/1.1\r\nHost: \(target.host):\(target.port)\r\n\r\n")
        } else {
            sendRequest(context)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inbound = unwrapInboundIn(data)
        buffer.writeBuffer(&inbound)
        pump(context)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(DaemonFetchFailure.connectTimeout)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if phase == .body, status != 0 {
            consumeBody(context)
            if !done { succeed() }
        } else if phase == .headers {
            fail(DaemonFetchFailure.headersTimeout)
        } else {
            fail(DaemonFetchFailure.connectTimeout)
        }
    }

    private func pump(_ context: ChannelHandlerContext) {
        switch phase {
        case .connect:
            guard let parsed = takeHeaders() else { return }
            guard parsed.status == 200 else {
                fail(DaemonFetchFailure.connectTimeout)
                return
            }
            if target.secure {
                // HTTPS stays on the connect timer. A sink that writes
                // `200 Connection Established` and then nothing is
                // `UND_ERR_CONNECT_TIMEOUT`, not a headers timeout.
                phase = .tls
            } else {
                disarmTimer()
                sendRequest(context)
            }
        case .tls:
            break
        case .headers:
            guard let parsed = takeHeaders() else { return }
            disarmTimer()
            status = parsed.status
            headers = parsed.headers
            phase = .body
            if parsed.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                bodyMode = .chunkSize
            } else if let length = parsed.headers["content-length"].flatMap(Int.init) {
                bodyMode = .length(length)
            } else {
                bodyMode = .none
            }
            pump(context)
        case .body:
            consumeBody(context)
        }
    }

    private func consumeBody(_ context: ChannelHandlerContext) {
        switch bodyMode {
        case .none:
            if buffer.readableBytes > 0, let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .length(let remaining):
            let take = min(remaining, buffer.readableBytes)
            if take > 0, let bytes = buffer.readBytes(length: take) {
                body.append(contentsOf: bytes)
            }
            let left = remaining - take
            if left == 0 {
                succeed()
            } else {
                bodyMode = .length(left)
            }
        case .chunkSize:
            guard let line = takeLine() else { return }
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line
            guard let size = Int(sizeText, radix: 16) else {
                fail(DaemonFetchFailure.headersTimeout)
                return
            }
            if size == 0 {
                bodyMode = .chunkTrailer
            } else {
                bodyMode = .chunkData(size)
            }
            consumeBody(context)
        case .chunkData(let remaining):
            let take = min(remaining, buffer.readableBytes)
            if take > 0, let bytes = buffer.readBytes(length: take) {
                body.append(contentsOf: bytes)
            }
            let left = remaining - take
            if left == 0 {
                bodyMode = .chunkEnding
                consumeBody(context)
            } else {
                bodyMode = .chunkData(left)
            }
        case .chunkEnding:
            guard buffer.readableBytes >= 2 else { return }
            buffer.moveReaderIndex(forwardBy: 2)
            bodyMode = .chunkSize
            consumeBody(context)
        case .chunkTrailer:
            guard buffer.readableBytes >= 2 else { return }
            let view = buffer.readableBytesView
            guard view[view.startIndex] == 13, view[view.index(after: view.startIndex)] == 10 else { return }
            buffer.moveReaderIndex(forwardBy: 2)
            succeed()
        }
    }

    private func sendRequest(_ context: ChannelHandlerContext) {
        phase = .headers
        arm(after: headersTimeoutMs, error: .headersTimeout)
        write(context, "\(method) \(target.path) HTTP/1.1\r\nHost: \(target.host):\(target.port)\r\nConnection: close\r\n\r\n")
    }

    private func write(_ context: ChannelHandlerContext, _ text: String) {
        let buffer = context.channel.allocator.buffer(string: text)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    private func arm(after milliseconds: Int, error: DaemonFetchFailure) {
        stateLock.lock()
        timerGeneration += 1
        let token = timerGeneration
        stateLock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let matches = self.timerGeneration == token && !self.done
            if matches {
                self.done = true
                self.timerGeneration += 1
            }
            self.stateLock.unlock()
            guard matches else { return }
            self.box.finish(.failure(error))
        }
    }

    private func disarmTimer() {
        stateLock.lock()
        timerGeneration += 1
        stateLock.unlock()
    }

    private func takeLine() -> String? {
        let start = buffer.readerIndex
        let end = buffer.writerIndex
        var index = start
        while index < end {
            if buffer.getInteger(at: index, as: UInt8.self) == 10 {
                let length = index - start + 1
                guard let bytes = buffer.readBytes(length: length) else { return nil }
                var text = String(decoding: bytes, as: UTF8.self)
                if text.hasSuffix("\n") { text.removeLast() }
                if text.hasSuffix("\r") { text.removeLast() }
                return text
            }
            index += 1
        }
        return nil
    }

    private func takeHeaders() -> (status: Int, headers: [String: String])? {
        guard let length = headerBlockLength() else { return nil }
        guard let bytes = buffer.readBytes(length: length) else { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        // Swift treats CRLF as one grapheme, so splitting on "\n" alone
        // never sees the line breaks in a normal HTTP header block.
        let lines = text.split(omittingEmptySubsequences: false) { character in
            character == "\n" || character == "\r" || character == "\r\n"
        }.map { line -> String in
            var line = String(line)
            if line.hasSuffix("\r") { line.removeLast() }
            return line
        }
        guard let statusLine = lines.first else { return nil }
        let code = Int(statusLine.split(separator: " ").dropFirst().first.map(String.init) ?? "") ?? 0
        var fields: [String: String] = [:]
        for line in lines.dropFirst() where line.contains(":") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            fields[name] = value
        }
        return (code, fields)
    }

    private func headerBlockLength() -> Int? {
        let start = buffer.readerIndex
        let end = buffer.writerIndex
        guard end - start >= 4 else { return nil }
        var index = start
        while index + 3 < end {
            if buffer.getInteger(at: index, as: UInt8.self) == 13,
               buffer.getInteger(at: index + 1, as: UInt8.self) == 10,
               buffer.getInteger(at: index + 2, as: UInt8.self) == 13,
               buffer.getInteger(at: index + 3, as: UInt8.self) == 10 {
                return index + 4 - start
            }
            index += 1
        }
        return nil
    }

    private func succeed() {
        finish(.success(DaemonFetchResponse(status: status, body: String(decoding: body, as: UTF8.self))))
    }

    private func fail(_ error: DaemonFetchFailure) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<DaemonFetchResponse, DaemonFetchFailure>) {
        stateLock.lock()
        if done {
            stateLock.unlock()
            return
        }
        done = true
        timerGeneration += 1
        stateLock.unlock()
        box.finish(result)
    }
}
