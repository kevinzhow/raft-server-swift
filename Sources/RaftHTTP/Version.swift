import Foundation

/// `GET /api/version` from `packages/server/src/app.ts` and `version.ts`
/// at raft-source v1.21.23-source.1.
///
/// `serverVersion` is `packages/server/package.json` `"version"` for that tag.
/// A missing package file there becomes `0.0.0-dev`; this port reports the
/// shipped semver. Release identity is read from the environment on each call.

public enum BuildIdentityStatus: Equatable, Sendable {
    case ready(version: String, sha: String, builtAt: String, branch: String)
    case unavailable(reason: String, sha: String?, builtAt: String?, branch: String?)
}

public enum APIVersion {
    public static let serverVersion = "1.21.23"
    public static let unavailableCode = "build_identity_unavailable"
    public static let unavailableError = "Build identity unavailable"

    public static func read(
        environment: [String: String],
        serverVersion: String = APIVersion.serverVersion
    ) -> BuildIdentityStatus {
        let sha = canonical(environment, raft: "RAFT_RELEASE_SHA", legacy: "SLOCK_RELEASE_SHA")
        let builtAt = canonical(environment, raft: "RAFT_BUILD_AT", legacy: "SLOCK_BUILD_AT")
        let branch = canonical(environment, raft: "RAFT_RELEASE_BRANCH", legacy: "SLOCK_RELEASE_BRANCH")
        if sha == nil {
            return .unavailable(reason: Reason.shaMissing, sha: sha, builtAt: builtAt, branch: branch)
        }
        if let sha, !isReleaseSHA(sha) {
            return .unavailable(reason: Reason.shaFormat, sha: sha, builtAt: builtAt, branch: branch)
        }
        if builtAt == nil {
            return .unavailable(reason: Reason.builtAtMissing, sha: sha, builtAt: builtAt, branch: branch)
        }
        if let builtAt, !isUTCInstant(builtAt) {
            return .unavailable(reason: Reason.builtAtFormat, sha: sha, builtAt: builtAt, branch: branch)
        }
        if branch == nil {
            return .unavailable(reason: Reason.branchMissing, sha: sha, builtAt: builtAt, branch: branch)
        }
        guard let sha, let builtAt, let branch else {
            return .unavailable(reason: Reason.shaMissing, sha: sha, builtAt: builtAt, branch: branch)
        }
        return .ready(version: serverVersion, sha: sha.lowercased(), builtAt: builtAt, branch: branch)
    }

    /// JSON body for the route. HEAD keeps an empty body and the GET length.
    public static func reply(
        method: String,
        environment: [String: String],
        serverVersion: String = APIVersion.serverVersion
    ) -> HTTPReply {
        let status = read(environment: environment, serverVersion: serverVersion)
        switch status {
        case .ready(let version, let sha, let builtAt, let branch):
            let body = "{\"version\":\(jsonString(version)),\"sha\":\(jsonString(sha)),\"builtAt\":\(jsonString(builtAt)),\"branch\":\(jsonString(branch))}"
            return AppFallback.transmit(status: 200, contentType: AppFallback.jsonContentType, body: body, method: method)
        case .unavailable(let reason, let sha, let builtAt, let branch):
            let body = "{\"error\":\(jsonString(Self.unavailableError)),\"code\":\(jsonString(Self.unavailableCode)),\"detail\":\(jsonString(reason)),\"sha\":\(jsonField(sha)),\"builtAt\":\(jsonField(builtAt)),\"branch\":\(jsonField(branch))}"
            return AppFallback.transmit(status: 503, contentType: AppFallback.jsonContentType, body: body, method: method)
        }
    }
}

private enum Reason {
    static let shaMissing = "RAFT_RELEASE_SHA is missing or disagrees with its legacy alias"
    static let shaFormat = "RAFT_RELEASE_SHA must be a 40-character git SHA"
    static let builtAtMissing = "RAFT_BUILD_AT is missing or disagrees with its legacy alias"
    static let builtAtFormat = "RAFT_BUILD_AT must be a UTC ISO-8601 instant"
    static let branchMissing = "RAFT_RELEASE_BRANCH is missing or disagrees with its legacy alias"
}

private func canonical(_ environment: [String: String], raft: String, legacy: String) -> String? {
    let raftValue = clean(environment[raft])
    let legacyValue = clean(environment[legacy])
    if let raftValue, let legacyValue, raftValue != legacyValue { return nil }
    return raftValue ?? legacyValue
}

private func clean(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

private func isReleaseSHA(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy(\.isHexDigit)
}

/// `Date.parse` after `UTC_INSTANT_PATTERN` in `version.ts`.
/// Month 1...12 and day 1...31 are enough: an impossible day overflows instead of failing.
/// Hour 24 is the end-of-day instant, and only when the rest of the clock is zero.
private func isUTCInstant(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    let count = bytes.count
    guard count == 20 || count == 24 else { return false }
    guard bytes[4] == UInt8(ascii: "-"),
          bytes[7] == UInt8(ascii: "-"),
          bytes[10] == UInt8(ascii: "T"),
          bytes[13] == UInt8(ascii: ":"),
          bytes[16] == UInt8(ascii: ":"),
          bytes[count - 1] == UInt8(ascii: "Z")
    else { return false }

    var millis = 0
    if count == 24 {
        guard bytes[19] == UInt8(ascii: ".") else { return false }
        guard let parsed = digits(bytes, 20..<23) else { return false }
        millis = parsed
    }
    guard digits(bytes, 0..<4) != nil,
          let month = digits(bytes, 5..<7),
          let day = digits(bytes, 8..<10),
          let hour = digits(bytes, 11..<13),
          let minute = digits(bytes, 14..<16),
          let second = digits(bytes, 17..<19)
    else { return false }
    guard (1...12).contains(month), (1...31).contains(day) else { return false }
    guard (0...59).contains(minute), (0...59).contains(second) else { return false }
    if hour == 24 {
        return minute == 0 && second == 0 && millis == 0
    }
    return (0...23).contains(hour)
}

private func digits(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
    var value = 0
    for index in range {
        let byte = bytes[index]
        guard byte >= 48, byte <= 57 else { return nil }
        value = value * 10 + Int(byte - 48)
    }
    return value
}

private func jsonField(_ value: String?) -> String {
    guard let value else { return "null" }
    return jsonString(value)
}
