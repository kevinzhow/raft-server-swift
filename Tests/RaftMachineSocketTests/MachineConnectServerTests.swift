import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import RaftConnectAuth
@testable import RaftMachineSocket

private struct ScriptedLookup: MachineCredentialLooking {
    var computer: ComputerAuthResolution = .denied(.computerNotFound)
    var machineById: MatchedMachine?
    func findComputer(apiKey: String) async throws -> ComputerAuthResolution { computer }
    func machine(id: String) async throws -> MatchedMachine? { machineById }
    func serverExists(id: String) async throws -> Bool { true }
    func machine(apiKey: String) async throws -> MatchedMachine? { nil }
}

private struct ExplodingLookup: MachineCredentialLooking {
    struct Boom: Error {}
    func findComputer(apiKey: String) async throws -> ComputerAuthResolution { throw Boom() }
    func machine(id: String) async throws -> MatchedMachine? { throw Boom() }
    func serverExists(id: String) async throws -> Bool { throw Boom() }
    func machine(apiKey: String) async throws -> MatchedMachine? { throw Boom() }
}

private let rfcKey = "dGhlIHNhbXBsZSBub25jZQ=="
private let rfcAccept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

@Test func switchingProtocolsUsesTheRfcAcceptValue() {
    let prelude = machineUpgradeSwitchingProtocols(
        clientKey: rfcKey,
        capabilities: [serverCapabilityRuntimeDetectionAsyncV1]
    )
    #expect(prelude.contains("HTTP/1.1 101 Switching Protocols\r\n"))
    #expect(prelude.contains("Sec-WebSocket-Accept: \(rfcAccept)\r\n"))
    #expect(prelude.contains("\(raftServerCapabilitiesHeader): \(serverCapabilityRuntimeDetectionAsyncV1)\r\n"))
    #expect(secWebSocketAccept(rfcKey) == rfcAccept)
}

@Test func contextFrameMatchesStringifyOrder() {
    let json = machineContextJSON(machineId: "m1", serverId: "s1", capabilities: [serverCapabilityRuntimeDetectionAsyncV1])
    #expect(json == "{\"type\":\"machine:context\",\"machineId\":\"m1\",\"serverId\":\"s1\",\"capabilities\":[\"machine:runtime-detection-async-v1\"]}")
}

@Test func missingKeyOnTheSocketIsTheExact401() async throws {
    let server = try await MachineConnectServer.start(lookup: ExplodingLookup())
    defer { Task { try? await server.close() } }
    let response = try await exchange(port: server.port, request: upgradeRequest(path: "/daemon/connect"))
    #expect(String(decoding: response, as: UTF8.self) == "HTTP/1.1 401 Unauthorized\r\nSlock-Reason: missing_key\r\n\r\n")
}

@Test func queryKeyRejectedWhenUnknown() async throws {
    let server = try await MachineConnectServer.start(lookup: ScriptedLookup())
    defer { Task { try? await server.close() } }
    let response = try await exchange(port: server.port, request: upgradeRequest(path: "/daemon/connect?key=not-a-real-key"))
    #expect(String(decoding: response, as: UTF8.self).contains("Slock-Reason: invalid_key_format\r\n"))
}

@Test func acceptedUpgradeCarriesContextFrame() async throws {
    let machine = MatchedMachine(id: "m1", serverId: "s1")
    let server = try await MachineConnectServer.start(
        lookup: ScriptedLookup(computer: .linked(computerId: "c1", machineId: "m1"), machineById: machine)
    )
    defer { Task { try? await server.close() } }
    let response = try await exchange(
        port: server.port,
        request: upgradeRequest(path: "/daemon/connect", authorization: "Bearer sk_computer_live"),
        stopAfterWebSocketFrame: true
    )
    let text = String(decoding: response, as: UTF8.self)
    #expect(text.contains("HTTP/1.1 101 Switching Protocols\r\n"))
    #expect(text.contains("Sec-WebSocket-Accept: \(rfcAccept)\r\n"))
    #expect(text.contains("raft-server-capabilities: machine:runtime-detection-async-v1\r\n"))
    let headerEnd = text.range(of: "\r\n\r\n")!
    let headerBytes = Data(text[..<headerEnd.upperBound].utf8).count
    let frame = Array(response.dropFirst(headerBytes))
    #expect(frame.first == 0x81)
    let payloadCount = Int(frame[1])
    let payload = frame.dropFirst(2).prefix(payloadCount)
    let json = String(decoding: payload, as: UTF8.self)
    #expect(json.contains("\"type\":\"machine:context\""))
    #expect(json.contains("\"machineId\":\"m1\""))
    #expect(json.contains("\"capabilities\":[\"machine:runtime-detection-async-v1\"]"))
}

@Test func otherPathsAre404() async throws {
    let server = try await MachineConnectServer.start(lookup: ExplodingLookup())
    defer { Task { try? await server.close() } }
    let response = try await exchange(port: server.port, request: upgradeRequest(path: "/socket.io/"))
    #expect(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 404 Not Found\r\n"))
}

private func upgradeRequest(path: String, authorization: String? = nil) -> String {
    var lines = [
        "GET \(path) HTTP/1.1",
        "Host: 127.0.0.1",
        "Connection: Upgrade",
        "Upgrade: websocket",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Key: \(rfcKey)",
    ]
    if let authorization {
        lines.append("Authorization: \(authorization)")
    }
    return lines.joined(separator: "\r\n") + "\r\n\r\n"
}

private func exchange(port: Int, request: String, stopAfterWebSocketFrame: Bool = false) async throws -> Data {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { try? await group.shutdownGracefully() } }
    let promise = group.any().makePromise(of: Data.self)
    let bootstrap = ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.pipeline.addHandler(CollectHandler(promise: promise, stopAfterWebSocketFrame: stopAfterWebSocketFrame))
        }
    let channel = try await bootstrap.connect(host: "127.0.0.1", port: port).get()
    let buffer = channel.allocator.buffer(bytes: Array(request.utf8))
    try await channel.writeAndFlush(buffer).get()
    let data = try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask { try await promise.futureResult.get() }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw MachineConnectTestTimeout()
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
    try? await channel.close()
    return data
}

private struct MachineConnectTestTimeout: Error {}

private final class CollectHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var collected = Data()
    private let promise: EventLoopPromise<Data>
    private let stopAfterWebSocketFrame: Bool
    private var finished = false

    init(promise: EventLoopPromise<Data>, stopAfterWebSocketFrame: Bool) {
        self.promise = promise
        self.stopAfterWebSocketFrame = stopAfterWebSocketFrame
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            collected.append(contentsOf: bytes)
        }
        if complete() {
            finish(context: context, result: .success(collected))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(context: context, result: .success(collected))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if collected.isEmpty {
            finish(context: context, result: .failure(error))
        } else {
            finish(context: context, result: .success(collected))
        }
    }

    private func finish(context: ChannelHandlerContext, result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        switch result {
        case .success(let data):
            promise.succeed(data)
        case .failure(let error):
            promise.fail(error)
        }
        _ = context
    }

    private func complete() -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = collected.range(of: separator) else { return false }
        let header = collected[..<headerEnd.upperBound]
        let text = String(decoding: header, as: UTF8.self)
        if text.hasPrefix("HTTP/1.1 401") || text.hasPrefix("HTTP/1.1 404") || text.hasPrefix("HTTP/1.1 500") || text.hasPrefix("HTTP/1.1 400") {
            return true
        }
        guard stopAfterWebSocketFrame, text.hasPrefix("HTTP/1.1 101") else { return false }
        let rest = collected[headerEnd.upperBound...]
        guard rest.count >= 2 else { return false }
        let length = Int(rest[rest.startIndex + 1])
        guard length < 126 else { return rest.count >= 4 }
        return rest.count >= 2 + length
    }
}
