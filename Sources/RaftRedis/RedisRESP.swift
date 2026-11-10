import Foundation
import NIOCore
@preconcurrency import RediStack

/// Business reply values. RediStack's shared null representation becomes bulk nil.
/// Nullable arrays remain source-compatible, but their wire distinction is not retained.
public indirect enum RedisReply: Sendable, Equatable {
    case simpleString(String)
    case error(String)
    case integer(Int64)
    case bulkString([UInt8]?)
    case array([RedisReply]?)
}

/// Value conversion and budgets only. RediStack owns RESP encoding and parsing.
enum RedisRESP {
    static func command(_ arguments: [[UInt8]], maximumBytes: Int) throws -> (String, [RESPValue]) {
        guard let first = arguments.first else { throw RedisError.invalidCommand }
        var remaining = maximumBytes
        var values: [RESPValue] = []
        values.reserveCapacity(arguments.count)
        for argument in arguments {
            guard argument.count <= remaining else { throw RedisError.commandTooLarge }
            remaining -= argument.count
            var buffer = ByteBufferAllocator().buffer(capacity: argument.count)
            buffer.writeBytes(argument)
            values.append(.bulkString(buffer))
        }
        var encoded = ByteBufferAllocator().buffer(capacity: maximumBytes - remaining)
        RESPTranslator().write(RESPValue.array(values), into: &encoded)
        guard encoded.readableBytes <= maximumBytes else { throw RedisError.commandTooLarge }
        return (String(decoding: first, as: UTF8.self), Array(values.dropFirst()))
    }

    static func reply(_ value: RESPValue, maximumBytes: Int) throws -> RedisReply {
        var budget = Budget(bytes: maximumBytes, elements: 16_384)
        return try convert(value, depth: 0, budget: &budget)
    }

    static func failure(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? RedisError { return error }
        if let error = error as? RediStack.RedisError {
            let text = serverText(error)
            let prefix = text.utf8.prefix { $0 != 32 }
            let code = !prefix.isEmpty && prefix.count <= 64 && prefix.allSatisfy({ (65...90).contains($0) })
                ? String(decoding: prefix, as: UTF8.self) : "ERR"
            return RedisError.serverError(code: code)
        }
        if error is RESPTranslator.ParsingError { return RedisError.malformedResponse }
        if let error = error as? RedisClientError, error == .connectionClosed {
            return RedisError.connectionClosed
        }
        if let error = error as? ChannelError, case .connectTimeout = error {
            return RedisError.connectionTimedOut
        }
        return RedisError.connectionFailed
    }

    private struct Budget {
        var bytes: Int
        var elements: Int

        mutating func consume(_ count: Int) throws {
            guard count <= bytes else { throw RedisError.responseTooLarge }
            bytes -= count
        }
    }

    private static func convert(_ value: RESPValue, depth: Int, budget: inout Budget) throws -> RedisReply {
        guard depth <= 32, budget.elements > 0 else { throw RedisError.responseTooLarge }
        budget.elements -= 1
        switch value {
        case .null:
            return .bulkString(nil)
        case .bulkString(let buffer):
            guard let buffer else { return .bulkString([]) }
            try budget.consume(buffer.readableBytes)
            return .bulkString(Array(buffer.readableBytesView))
        case .simpleString(let buffer):
            guard buffer.readableBytes <= 16_384 else { throw RedisError.responseTooLarge }
            try budget.consume(buffer.readableBytes)
            guard let text = String(bytes: buffer.readableBytesView, encoding: .utf8)
            else { throw RedisError.malformedResponse }
            return .simpleString(text)
        case .integer(let value):
            guard let integer = Int64(exactly: value) else { throw RedisError.malformedResponse }
            return .integer(integer)
        case .error(let error):
            let text = serverText(error)
            guard text.utf8.count <= 16_384 else { throw RedisError.responseTooLarge }
            try budget.consume(text.utf8.count)
            return .error(text)
        case .array(let elements):
            guard elements.count <= budget.elements else { throw RedisError.responseTooLarge }
            var replies: [RedisReply] = []
            replies.reserveCapacity(elements.count)
            for element in elements {
                replies.append(try convert(element, depth: depth + 1, budget: &budget))
            }
            return .array(replies)
        }
    }

    private static func serverText(_ error: RediStack.RedisError) -> String {
        let prefix = "(Redis) "
        return error.message.hasPrefix(prefix) ? String(error.message.dropFirst(prefix.count)) : error.message
    }
}
