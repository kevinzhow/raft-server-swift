import Foundation

extension RedisClient {
    public func ping() async throws {
        guard try await execute(["PING"]) == .simpleString("PONG") else { throw RedisError.unexpectedResponse }
    }

    public func getBytes(_ key: String) async throws -> [UInt8]? {
        guard case .bulkString(let bytes) = try await execute(["GET", key])
        else { throw RedisError.unexpectedResponse }
        return bytes
    }

    public func get(_ key: String) async throws -> String? {
        guard let bytes = try await getBytes(key) else { return nil }
        guard let value = String(bytes: bytes, encoding: .utf8) else { throw RedisError.unexpectedResponse }
        return value
    }

    /// SET [EX seconds] [NX]. False means NX refused an existing key.
    @discardableResult
    public func set(
        _ key: String, value: String, expirySeconds: Int? = nil, onlyIfAbsent: Bool = false
    ) async throws -> Bool {
        try await setBytes(key, value: Array(value.utf8), expirySeconds: expirySeconds, onlyIfAbsent: onlyIfAbsent)
    }

    @discardableResult
    public func setBytes(
        _ key: String, value: [UInt8], expirySeconds: Int? = nil, onlyIfAbsent: Bool = false
    ) async throws -> Bool {
        if let expirySeconds, expirySeconds <= 0 { throw RedisError.invalidCommand }
        var arguments = [Array("SET".utf8), Array(key.utf8), value]
        if let expirySeconds { arguments += [Array("EX".utf8), Array(String(expirySeconds).utf8)] }
        if onlyIfAbsent { arguments.append(Array("NX".utf8)) }
        let reply = try await execute(bytes: arguments)
        if reply == .simpleString("OK") { return true }
        if onlyIfAbsent, reply == .bulkString(nil) { return false }
        throw RedisError.unexpectedResponse
    }

    public func setIfAbsent(_ key: String, value: String, ttlSeconds: Int) async throws -> Bool {
        try await set(key, value: value, expirySeconds: ttlSeconds, onlyIfAbsent: true)
    }

    /// PX is required by response mailboxes and leases whose deadlines use milliseconds.
    public func setIfAbsent(_ key: String, value: String, ttlMilliseconds: Int) async throws -> Bool {
        guard ttlMilliseconds > 0 else { throw RedisError.invalidCommand }
        let reply = try await execute(["SET", key, value, "PX", String(ttlMilliseconds), "NX"])
        if reply == .simpleString("OK") { return true }
        if reply == .bulkString(nil) { return false }
        throw RedisError.unexpectedResponse
    }

    @discardableResult
    public func delete(_ keys: [String]) async throws -> Int64 {
        guard !keys.isEmpty else { throw RedisError.invalidCommand }
        guard case .integer(let count) = try await execute(["DEL"] + keys), count >= 0
        else { throw RedisError.unexpectedResponse }
        return count
    }

    /// Returns Redis's recipient count, not an acknowledgement of consumer processing.
    public func publish(channel: String, message: String) async throws -> Int64 {
        guard case .integer(let count) = try await execute(["PUBLISH", channel, message]), count >= 0
        else { throw RedisError.unexpectedResponse }
        return count
    }

    public func eval(script: String, keys: [String], arguments: [String] = []) async throws -> RedisReply {
        try await execute(["EVAL", script, String(keys.count)] + keys + arguments)
    }

    /// Matches upstream public-search bucket atomicity: an increment can never lose its TTL.
    public func incrementWithTTL(_ key: String, ttlSeconds: Int) async throws -> Int64 {
        guard ttlSeconds > 0 else { throw RedisError.invalidCommand }
        let script = """
        local count = redis.call('INCR', KEYS[1])
        if redis.call('TTL', KEYS[1]) < 0 then
          redis.call('EXPIRE', KEYS[1], tonumber(ARGV[1]))
        end
        return count
        """
        guard case .integer(let count) = try await eval(script: script, keys: [key], arguments: [String(ttlSeconds)])
        else { throw RedisError.unexpectedResponse }
        return count
    }

    /// Release a lease only when its current token still belongs to this caller.
    /// GET followed by DEL would delete another owner's lease after TTL expiry.
    public func deleteIfValueMatches(_ key: String, value: String) async throws -> Bool {
        let script = """
        if redis.call('GET', KEYS[1]) == ARGV[1] then
          return redis.call('DEL', KEYS[1])
        end
        return 0
        """
        guard case .integer(let count) = try await eval(script: script, keys: [key], arguments: [value]), count == 0 || count == 1
        else { throw RedisError.unexpectedResponse }
        return count == 1
    }
}
