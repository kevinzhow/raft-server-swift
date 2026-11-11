import Foundation

/// Incremental HTTP/1.1 request framing for the SwiftNIO socket listener.
///
/// The parser is owned by one connection handler and runs on that connection's
/// event loop. It keeps one stream-local cursor and state machine so an
/// incomplete head, Content-Length body, chunk size, chunk body, chunk
/// terminator, or trailer waits for more bytes instead of being reparsed from
/// the beginning. Body storage is bounded by the engine.io payload limit; a
/// non-POST body is framed and discarded rather than captured.
struct EngineIOHTTPFramer {
    enum Event {
        case request(EngineIOHTTPRequest, body: [UInt8])
        case oversized(EngineIOHTTPRequest)
        case upgrade(EngineIOHTTPRequest, residual: [UInt8])
        case incomplete
        case failure(EngineIOHTTPFramingError)
    }

    private enum Phase {
        case head
        case fixedBody(remaining: UInt64)
        case chunkSize
        case chunkData(remaining: UInt64)
        case chunkTerminator
        case trailers
    }

    private static let maxHeaderBytes = 16 * 1_024
    private static let maxTrailerBytes = 16 * 1_024
    private static let maxChunkLineBytes = 8 * 1_024
    private static let compactThreshold = 4 * 1_024

    private let maxPayload: Int
    private var bytes: [UInt8] = []
    private var cursor = 0
    private var phase: Phase = .head
    private var request: EngineIOHTTPRequest?
    private var captured: [UInt8] = []
    private var decodedLength: UInt64 = 0
    private var trailerBytes = 0
    private var capturesBody = false
    private var done = false

    init(maxPayload: Int) {
        self.maxPayload = maxPayload
    }

    mutating func append(_ incoming: [UInt8]) {
        compact(force: false)
        bytes.append(contentsOf: incoming)
    }

    mutating func next() -> Event {
        guard !done else { return .incomplete }

        while true {
            switch phase {
            case .head:
                guard let headEnd = findHeaderEnd() else {
                    if bytes.count - cursor > Self.maxHeaderBytes {
                        return fail(.headerTooLarge)
                    }
                    return .incomplete
                }
                if headEnd - cursor > Self.maxHeaderBytes {
                    return fail(.headerTooLarge)
                }
                let headBytes = Array(bytes[cursor..<headEnd])
                guard let head = String(bytes: headBytes, encoding: .utf8) else {
                    return fail(.malformedHead)
                }
                let parsed: EngineIOHTTPRequest
                do {
                    parsed = try EngineIOHTTPRequest(validatingHead: head)
                } catch let error as EngineIOHTTPRequestError {
                    return fail(Self.framingError(for: error))
                } catch {
                    return fail(.malformedHead)
                }
                cursor = headEnd + 4
                compact(force: false)

                if parsed.isWebSocketUpgrade {
                    // Bytes after the upgrade head belong to the WebSocket
                    // frame stream. They are handed over verbatim; they are
                    // never interpreted as an HTTP body.
                    let residual = Array(bytes[cursor...])
                    bytes.removeAll()
                    cursor = 0
                    done = true
                    return .upgrade(parsed, residual: residual)
                }

                request = parsed
                capturesBody = parsed.method == "POST"
                captured = []
                decodedLength = 0
                trailerBytes = 0
                switch parsed.bodyFraming {
                case .none:
                    return finishRequest()
                case .contentLength(let length):
                    if capturesBody, length > UInt64(maxPayload) {
                        return failOversized(parsed)
                    }
                    if length == 0 { return finishRequest() }
                    phase = .fixedBody(remaining: length)
                case .chunked:
                    phase = .chunkSize
                }

            case .fixedBody(let remaining):
                let available = UInt64(bytes.count - cursor)
                if available == 0 {
                    compact(force: false)
                    return .incomplete
                }
                let take = Int(min(available, remaining))
                if capturesBody {
                    captured.append(contentsOf: bytes[cursor..<(cursor + take)])
                }
                cursor += take
                let left = remaining - UInt64(take)
                if left == 0 {
                    phase = .head
                    return finishRequest()
                }
                phase = .fixedBody(remaining: left)
                compact(force: false)
                return .incomplete

            case .chunkSize:
                guard let lineEnd = findCRLF(from: cursor) else {
                    if bytes.count - cursor > Self.maxChunkLineBytes {
                        return fail(.invalidChunkSize)
                    }
                    return .incomplete
                }
                if lineEnd - cursor > Self.maxChunkLineBytes {
                    return fail(.invalidChunkSize)
                }
                let size: UInt64
                do {
                    size = try parseChunkSize(bytes[cursor..<lineEnd])
                } catch let error as EngineIOHTTPFramingError {
                    return fail(error)
                } catch {
                    return fail(.invalidChunkSize)
                }
                cursor = lineEnd + 2
                if size == 0 {
                    phase = .trailers
                    continue
                }
                if capturesBody {
                    guard let request else { return fail(.malformedHead) }
                    if decodedLength > UInt64(maxPayload)
                        || size > UInt64(maxPayload) - decodedLength {
                        return failOversized(request)
                    }
                }
                phase = .chunkData(remaining: size)

            case .chunkData(let remaining):
                let available = UInt64(bytes.count - cursor)
                if available == 0 {
                    compact(force: false)
                    return .incomplete
                }
                let take = Int(min(available, remaining))
                if capturesBody {
                    captured.append(contentsOf: bytes[cursor..<(cursor + take)])
                }
                let (newLength, overflow) = decodedLength.addingReportingOverflow(UInt64(take))
                if overflow { return fail(.chunkSizeOverflow) }
                decodedLength = newLength
                cursor += take
                let left = remaining - UInt64(take)
                if left == 0 {
                    phase = .chunkTerminator
                } else {
                    phase = .chunkData(remaining: left)
                    compact(force: false)
                    return .incomplete
                }

            case .chunkTerminator:
                guard bytes.count - cursor >= 2 else {
                    compact(force: false)
                    return .incomplete
                }
                guard bytes[cursor] == 13, bytes[cursor + 1] == 10 else {
                    return fail(.invalidChunkTerminator)
                }
                cursor += 2
                phase = .chunkSize

            case .trailers:
                guard let lineEnd = findCRLF(from: cursor) else {
                    if bytes.count - cursor > Self.maxTrailerBytes - trailerBytes {
                        return fail(.trailersTooLarge)
                    }
                    return .incomplete
                }
                let line = bytes[cursor..<lineEnd]
                if line.count + 2 > Self.maxTrailerBytes - trailerBytes {
                    return fail(.trailersTooLarge)
                }
                trailerBytes += line.count + 2
                cursor = lineEnd + 2
                if line.isEmpty {
                    phase = .head
                    return finishRequest()
                }
                if let error = validateTrailer(line) { return fail(error) }
            }
        }
    }

    // MARK: - Completion and failure

    private mutating func finishRequest() -> Event {
        guard let request else { return fail(.malformedHead) }
        let body = captured
        self.request = nil
        captured = []
        decodedLength = 0
        trailerBytes = 0
        phase = .head
        compact(force: true)
        return .request(request, body: body)
    }

    private mutating func failOversized(_ request: EngineIOHTTPRequest) -> Event {
        done = true
        bytes.removeAll()
        cursor = 0
        return .oversized(request)
    }

    private mutating func fail(_ error: EngineIOHTTPFramingError) -> Event {
        done = true
        bytes.removeAll()
        cursor = 0
        return .failure(error)
    }

    // MARK: - Parsing helpers

    private func findHeaderEnd() -> Int? {
        guard bytes.count >= cursor + 4 else { return nil }
        var index = cursor
        while index + 3 < bytes.count {
            if bytes[index] == 13, bytes[index + 1] == 10,
               bytes[index + 2] == 13, bytes[index + 3] == 10 {
                return index
            }
            index += 1
        }
        return nil
    }

    private func findCRLF(from start: Int) -> Int? {
        guard bytes.count >= start + 2 else { return nil }
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 13, bytes[index + 1] == 10 { return index }
            index += 1
        }
        return nil
    }

    private func parseChunkSize(_ line: ArraySlice<UInt8>) throws -> UInt64 {
        var value: UInt64 = 0
        var digits = 0
        for byte in line {
            if byte == UInt8(ascii: ";") { break }
            guard let digit = Self.hexValue(byte) else {
                throw EngineIOHTTPFramingError.invalidChunkSize
            }
            digits += 1
            let (multiplied, multiplyOverflow) = value.multipliedReportingOverflow(by: 16)
            if multiplyOverflow { throw EngineIOHTTPFramingError.chunkSizeOverflow }
            let (sum, addOverflow) = multiplied.addingReportingOverflow(UInt64(digit))
            if addOverflow { throw EngineIOHTTPFramingError.chunkSizeOverflow }
            value = sum
        }
        guard digits > 0 else { throw EngineIOHTTPFramingError.invalidChunkSize }
        return value
    }

    private func validateTrailer(_ line: ArraySlice<UInt8>) -> EngineIOHTTPFramingError? {
        guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else {
            return .invalidTrailer
        }
        let name = String(decoding: line[..<colon], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return .invalidTrailer }
        // Node's HTTP parser rejects boundary-changing fields in trailers.
        if ["content-length", "transfer-encoding", "host", "connection",
            "upgrade", "expect", "trailer"].contains(name) {
            return .invalidTrailer
        }
        return nil
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return byte - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }

    private static func framingError(for error: EngineIOHTTPRequestError) -> EngineIOHTTPFramingError {
        switch error {
        case .malformedHead:
            return .malformedHead
        case .duplicateContentLength:
            return .duplicateContentLength
        case .invalidContentLength:
            return .invalidContentLength
        case .duplicateTransferEncoding:
            return .duplicateTransferEncoding
        case .contentLengthWithTransferEncoding:
            return .contentLengthWithTransferEncoding
        case .unsupportedTransferEncoding:
            return .unsupportedTransferEncoding
        }
    }

    private mutating func compact(force: Bool) {
        guard cursor > 0 else { return }
        if force || cursor >= Self.compactThreshold || cursor == bytes.count {
            bytes.removeFirst(cursor)
            cursor = 0
        }
    }
}

enum EngineIOHTTPFramingError: Error, Equatable, Sendable {
    case malformedHead
    case headerTooLarge
    case duplicateContentLength
    case invalidContentLength
    case duplicateTransferEncoding
    case contentLengthWithTransferEncoding
    case unsupportedTransferEncoding
    case invalidChunkSize
    case chunkSizeOverflow
    case invalidChunkTerminator
    case trailersTooLarge
    case invalidTrailer
}
