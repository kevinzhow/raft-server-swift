import Foundation
import NIOCore
import NIOWebSocket

/// The channel pipeline owns RFC6455 serialization. This helper never emits
/// hand-built wire headers and does not decide whether an outcome merits ACK.
enum MachineCommandWebSocket {
    struct Frame: Sendable { let opcode: UInt8; let payload: [UInt8] }
    static let maximumMessageBytes = 1_048_576

    static func write(opcode: UInt8, payload: [UInt8], channel: any Channel) -> EventLoopFuture<Void> {
        guard let kind = WebSocketOpcode(encodedWebSocketOpcode: opcode) else {
            return channel.eventLoop.makeFailedFuture(MachineCommandError.protocolViolation)
        }
        let frame = WebSocketFrame(fin: true, opcode: kind, data: channel.allocator.buffer(bytes: payload))
        return channel.writeAndFlush(frame)
    }
}

/// NIO decodes frames; Raft additionally requires masked, extension-free,
/// text-only messages with a 1 MiB aggregate limit and valid close payloads.
/// This state is confined to the channel's event loop.
private struct MachineCommandMessagePolicy {
    private var fragments: [UInt8] = []
    private var fragmented = false

    mutating func accept(_ frame: WebSocketFrame) throws -> MachineCommandWebSocket.Frame? {
        guard frame.maskKey != nil, !frame.rsv1, !frame.rsv2, !frame.rsv3,
              frame.length <= MachineCommandWebSocket.maximumMessageBytes else {
            throw MachineCommandError.protocolViolation
        }
        if frame.opcode.isControlOpcode {
            guard frame.fin, frame.length <= 125 else { throw MachineCommandError.protocolViolation }
        }
        let payload = Array(frame.unmaskedData.readableBytesView)
        switch frame.opcode {
        case .text:
            guard !fragmented else { throw MachineCommandError.protocolViolation }
            if frame.fin {
                guard String(bytes: payload, encoding: .utf8) != nil else { throw MachineCommandError.protocolViolation }
                return .init(opcode: 1, payload: payload)
            }
            fragments = payload; fragmented = true
            return nil
        case .continuation:
            guard fragmented, payload.count <= MachineCommandWebSocket.maximumMessageBytes - fragments.count else {
                throw MachineCommandError.protocolViolation
            }
            fragments += payload
            guard frame.fin else { return nil }
            guard String(bytes: fragments, encoding: .utf8) != nil else { throw MachineCommandError.protocolViolation }
            let message = MachineCommandWebSocket.Frame(opcode: 1, payload: fragments)
            fragments = []; fragmented = false
            return message
        case .connectionClose:
            guard payload.count != 1 else { throw MachineCommandError.protocolViolation }
            if !payload.isEmpty {
                var body = frame.unmaskedData
                guard let code = body.readInteger(as: UInt16.self),
                      ((1000...1014).contains(code) && ![1004, 1005, 1006].contains(code)) || (3000...4999).contains(code),
                      String(bytes: body.readableBytesView, encoding: .utf8) != nil else {
                    throw MachineCommandError.protocolViolation
                }
            }
            return .init(opcode: 8, payload: payload)
        case .ping: return .init(opcode: 9, payload: payload)
        case .pong: return .init(opcode: 10, payload: payload)
        default: throw MachineCommandError.protocolViolation
        }
    }
}

/// Installed after NIO's frame decoder. Fragment/control policy remains here,
/// while the existing connection owns JSON ingress, ordered commits and drain.
final class MachineCommandFrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    private let connection: MachineCommandConnectionHandler
    private var policy = MachineCommandMessagePolicy()
    private var closing = false

    init(connection: MachineCommandConnectionHandler) { self.connection = connection }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.eventLoop.preconditionInEventLoop()
        guard !closing else { return }
        do {
            guard let frame = try policy.accept(unwrapInboundIn(data)) else { return }
            if frame.opcode == 8 { closing = true }
            try connection.receiveFrame(frame, channel: context.channel)
        } catch {
            closing = true
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        closing = true
        context.close(promise: nil)
    }
}
