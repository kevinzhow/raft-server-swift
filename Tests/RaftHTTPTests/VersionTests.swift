import Testing
@testable import RaftHTTP

private let sha = "abcdef1234567890abcdef1234567890abcdef12"
private let builtAt = "2026-07-13T04:52:55Z"
private let branch = "staging"

private func header(_ reply: HTTPReply, _ name: String) -> String {
    reply.value(for: name) ?? ""
}

private func legacyEnvironment(sha: String = sha.uppercased()) -> [String: String] {
    [
        "SLOCK_RELEASE_SHA": sha,
        "SLOCK_BUILD_AT": builtAt,
        "SLOCK_RELEASE_BRANCH": branch,
    ]
}

@Test func serverVersionIsThePinnedPackageSemver() {
    #expect(APIVersion.serverVersion == "1.21.23")
}

@Test func completeLegacyIdentityIsAcceptedAndLowercased() {
    let status = APIVersion.read(environment: legacyEnvironment())
    #expect(status == .ready(version: "1.21.23", sha: sha, builtAt: builtAt, branch: branch))
}

@Test func raftIdentityIsCanonicalAndLegacyAliasesMustAgree() {
    let agree: [String: String] = [
        "RAFT_RELEASE_SHA": sha,
        "RAFT_BUILD_AT": builtAt,
        "RAFT_RELEASE_BRANCH": branch,
        "SLOCK_RELEASE_SHA": sha,
        "SLOCK_BUILD_AT": builtAt,
        "SLOCK_RELEASE_BRANCH": branch,
    ]
    #expect(APIVersion.read(environment: agree) == .ready(version: "1.21.23", sha: sha, builtAt: builtAt, branch: branch))

    var disagree = agree
    disagree["SLOCK_RELEASE_SHA"] = String(repeating: "f", count: 40)
    #expect(APIVersion.read(environment: disagree) == .unavailable(
        reason: "RAFT_RELEASE_SHA is missing or disagrees with its legacy alias",
        sha: nil,
        builtAt: builtAt,
        branch: branch
    ))
}

@Test func missingReleaseShaFailsExplicitly() {
    let status = APIVersion.read(environment: [
        "SLOCK_BUILD_AT": builtAt,
        "SLOCK_RELEASE_BRANCH": branch,
    ])
    #expect(status == .unavailable(
        reason: "RAFT_RELEASE_SHA is missing or disagrees with its legacy alias",
        sha: nil,
        builtAt: builtAt,
        branch: branch
    ))
}

@Test func placeholderAndShortReleaseShasAreRejected() {
    for candidate in ["unknown", "abcdef1"] {
        let status = APIVersion.read(environment: legacyEnvironment(sha: candidate))
        #expect(status == .unavailable(
            reason: "RAFT_RELEASE_SHA must be a 40-character git SHA",
            sha: candidate,
            builtAt: builtAt,
            branch: branch
        ))
    }
}

@Test func releaseValuesAreTrimmedBeforeTheyAreCompared() {
    var environment = legacyEnvironment()
    environment["SLOCK_RELEASE_SHA"] = "  \(sha.uppercased())  "
    environment["SLOCK_RELEASE_BRANCH"] = "  staging  "
    #expect(APIVersion.read(environment: environment) == .ready(version: "1.21.23", sha: sha, builtAt: builtAt, branch: "staging"))
}

@Test func blankReleaseValuesCountAsMissing() {
    let status = APIVersion.read(environment: legacyEnvironment(sha: "   "))
    #expect(status == .unavailable(
        reason: "RAFT_RELEASE_SHA is missing or disagrees with its legacy alias",
        sha: nil,
        builtAt: builtAt,
        branch: branch
    ))
}

@Test func builtAtMustBeAUtcInstantThatDateParseAccepts() {
    let rejected = [
        "2026-07-13T04:52:55.12Z",
        "2026-13-01T00:00:00Z",
        "2026-07-13T24:00:01Z",
        "2026-07-13T04:52:60Z",
        "2026-00-01T00:00:00Z",
        "2026-01-00T00:00:00Z",
        "2026-01-32T00:00:00Z",
    ]
    for candidate in rejected {
        var environment = legacyEnvironment()
        environment["SLOCK_BUILD_AT"] = candidate
        #expect(APIVersion.read(environment: environment) == .unavailable(
            reason: "RAFT_BUILD_AT must be a UTC ISO-8601 instant",
            sha: sha.uppercased(),
            builtAt: candidate,
            branch: branch
        ))
    }

    for candidate in ["2026-07-13T04:52:55.123Z", "2026-02-31T00:00:00Z", "2026-07-13T24:00:00.000Z"] {
        var environment = legacyEnvironment()
        environment["SLOCK_BUILD_AT"] = candidate
        #expect(APIVersion.read(environment: environment) == .ready(version: "1.21.23", sha: sha, builtAt: candidate, branch: branch))
    }
}

@Test func missingBranchNamesThatField() {
    var environment = legacyEnvironment()
    environment["SLOCK_RELEASE_BRANCH"] = nil
    #expect(APIVersion.read(environment: environment) == .unavailable(
        reason: "RAFT_RELEASE_BRANCH is missing or disagrees with its legacy alias",
        sha: sha.uppercased(),
        builtAt: builtAt,
        branch: nil
    ))
}

@Test func versionJSONUsesStringifyOrderAndEscapesTheBranch() {
    var environment = legacyEnvironment()
    environment["SLOCK_RELEASE_BRANCH"] = "a\"b\\c"
    let reply = APIVersion.reply(method: "GET", environment: environment, serverVersion: "9.9.9")
    #expect(reply.status == 200)
    #expect(header(reply, "content-type") == AppFallback.jsonContentType)
    #expect(header(reply, "x-robots-tag") == "noindex, nofollow")
    #expect(reply.body == "{\"version\":\"9.9.9\",\"sha\":\"\(sha)\",\"builtAt\":\"\(builtAt)\",\"branch\":\"a\\\"b\\\\c\"}")
}

@Test func unavailableVersionJSONKeepsNullFieldsAndDropsTheBodyOnHead() {
    let environment = [
        "SLOCK_BUILD_AT": builtAt,
        "SLOCK_RELEASE_BRANCH": branch,
    ]
    let get = APIVersion.reply(method: "GET", environment: environment)
    let body = "{\"error\":\"Build identity unavailable\",\"code\":\"build_identity_unavailable\",\"detail\":\"RAFT_RELEASE_SHA is missing or disagrees with its legacy alias\",\"sha\":null,\"builtAt\":\"\(builtAt)\",\"branch\":\"\(branch)\"}"
    #expect(get.status == 503)
    #expect(get.body == body)
    #expect(header(get, "content-length") == String(body.utf8.count))

    let head = APIVersion.reply(method: "HEAD", environment: environment)
    #expect(head.status == 503)
    #expect(head.body.isEmpty)
    #expect(header(head, "content-length") == String(body.utf8.count))
}
