import Foundation

/// Bounded RFC6455 framing. Client frames must be masked; server frames must not.
/// No compression extension is negotiated. Fragmentation and control frames can interleave.
struct PersistentWebSocket: Sendable {
    struct Frame: Sendable { let opcode: UInt8; let payload: [UInt8] }
    private var bytes: [UInt8] = []
    private var fragment: [UInt8] = []
    private var fragmented = false
    static let maximumMessageBytes = 1_048_576

    mutating func append(_ incoming: [UInt8], requireMask: Bool) throws -> [Frame] {
        bytes.append(contentsOf: incoming)
        guard bytes.count <= Self.maximumMessageBytes * 2 + 28 else { throw PersistentDaemonError.protocolViolation }
        var result: [Frame] = []
        while bytes.count >= 2 {
            guard result.count < 256 else { throw PersistentDaemonError.protocolViolation }
            let fin = bytes[0] & 0x80 != 0, opcode = bytes[0] & 0x0f
            guard bytes[0] & 0x70 == 0, (bytes[1] & 0x80 != 0) == requireMask else {
                throw PersistentDaemonError.protocolViolation
            }
            var count = UInt64(bytes[1] & 0x7f), cursor = 2
            if count == 126 {
                guard bytes.count >= 4 else { break }
                count = UInt64(bytes[2]) << 8 | UInt64(bytes[3]); cursor = 4
                guard count >= 126 else { throw PersistentDaemonError.protocolViolation }
            } else if count == 127 {
                guard bytes.count >= 10 else { break }
                count = 0
                for byte in bytes[2..<10] { count = (count << 8) | UInt64(byte) }
                cursor = 10
                guard count >= 65_536, count & (1 << 63) == 0 else { throw PersistentDaemonError.protocolViolation }
            }
            guard count <= UInt64(Self.maximumMessageBytes) else { throw PersistentDaemonError.protocolViolation }
            let control = opcode >= 8
            guard !control || (fin && count <= 125) else { throw PersistentDaemonError.protocolViolation }
            var mask: [UInt8] = []
            if requireMask {
                guard bytes.count >= cursor + 4 else { break }
                mask = Array(bytes[cursor..<cursor + 4]); cursor += 4
            }
            guard bytes.count >= cursor + Int(count) else { break }
            var payload = Array(bytes[cursor..<cursor + Int(count)])
            if requireMask { for index in payload.indices { payload[index] ^= mask[index % 4] } }
            bytes.removeFirst(cursor + Int(count))
            switch opcode {
            case 0:
                guard fragmented else { throw PersistentDaemonError.protocolViolation }
                fragment.append(contentsOf: payload)
                guard fragment.count <= Self.maximumMessageBytes else { throw PersistentDaemonError.protocolViolation }
                if fin { result.append(Frame(opcode: 1, payload: fragment)); fragment = []; fragmented = false }
            case 1:
                guard !fragmented else { throw PersistentDaemonError.protocolViolation }
                if fin { result.append(Frame(opcode: 1, payload: payload)) }
                else { fragmented = true; fragment = payload }
            case 8:
                guard payload.count != 1 else { throw PersistentDaemonError.protocolViolation }
                if payload.count >= 2 {
                    let code = Int(payload[0]) * 256 + Int(payload[1])
                    guard ((1000...1014).contains(code) && ![1004, 1005, 1006].contains(code))
                        || (3000...4999).contains(code),
                        String(bytes: payload.dropFirst(2), encoding: .utf8) != nil else {
                        throw PersistentDaemonError.protocolViolation
                    }
                }
                result.append(Frame(opcode: opcode, payload: payload))
            case 9, 10: result.append(Frame(opcode: opcode, payload: payload))
            default: throw PersistentDaemonError.protocolViolation
            }
        }
        return result
    }

    static func encode(opcode: UInt8, payload: [UInt8], masked: Bool = false) -> [UInt8] {
        var result: [UInt8] = [0x80 | opcode]
        let flag: UInt8 = masked ? 0x80 : 0
        if payload.count < 126 { result.append(flag | UInt8(payload.count)) }
        else if payload.count <= 65_535 {
            result += [flag | 126, UInt8((payload.count >> 8) & 255), UInt8(payload.count & 255)]
        } else {
            result.append(flag | 127)
            let count = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8((count >> shift) & 255)) }
        }
        if masked {
            let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
            result += mask
            result += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        } else { result += payload }
        return result
    }
}
