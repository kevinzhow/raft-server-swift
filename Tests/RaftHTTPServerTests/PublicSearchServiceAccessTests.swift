import Crypto
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private final class MutableKeySource: PublicSearchServiceKeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [PublicSearchServiceKey]

    init(_ rows: [PublicSearchServiceKey]) { self.rows = rows }

    func set(_ rows: [PublicSearchServiceKey]) {
        lock.lock(); self.rows = rows; lock.unlock()
    }

    func keys() throws -> [PublicSearchServiceKey] {
        lock.lock(); defer { lock.unlock() }
        return rows
    }
}

private struct ServiceCredential {
    let token: String
    var sha256: String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    var header: String { "Raft-Service v1 k-current.\(token)" }
}

private func seedDirectory() -> (directory: PublicServerDirectory, seed: PublicServerDirectory.Seed) {
    let directory = PublicServerDirectory()
    directory.rolloutEnabled = true
    directory.searchIndexEnabled = true
    let seed = directory.addServer(
        id: "server",
        name: "Service Access",
        slug: "svc-access",
        ownerId: "owner",
        ownerToken: "owner-token",
        publiclyVisible: true,
        channels: [(id: "open", name: "open-talk", description: nil, guestVisible: true, publicId: nil, threads: [
            (id: "thread", publicId: nil, parent: "Question in svc-access", replies: ["A reply"]),
        ])]
    )
    return (directory, seed!)
}

@Test func publicSearchServiceCredentialsKeysAndSharedBucket() async throws {
    let current = ServiceCredential(token: "current-token-0123456789abcdef")
    let previous = ServiceCredential(token: "previous-token-0123456789abcdef")
    let next = ServiceCredential(token: "next-token-0123456789abcdef")
    let source = MutableKeySource([
        PublicSearchServiceKey(keyId: "k-current", sha256: current.sha256),
        PublicSearchServiceKey(keyId: "k-previous", sha256: previous.sha256, expiresAt: Date(timeIntervalSince1970: 32_503_680_000)),
    ])
    let (directory, seed) = seedDirectory()
    let bucket = PublicSearchMemoryBucketStore()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicSearch: directory.projectedCatalog(),
            publicServerDirectory: directory,
            publicSearchServiceKeySource: source,
            publicSearchServiceBucket: bucket,
            publicSearchServiceLimits: PublicSearchServiceLimits(environment: ["RAFT_LANDING_SERVICE_RATE_PER_MINUTE": "12", "RAFT_LANDING_SERVICE_MAX_IN_FLIGHT": "4"])
        ))
        try await app.testing { client in
            let url = "/api/public/search/servers/\(seed.serverPublicId)"
            func get(_ authorization: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                if let authorization { headers[HTTPField.Name("Authorization")!] = authorization }
                return try await client.get(URI(string: url), headers: headers)
            }
            #expect(try await get().status == .ok)
            let invalidHeaders = [
                "Raft-Service v1 k-nope.\(current.token)",
                "Raft-Service v1 k-current.\(previous.token)",
                "Raft-Service v1 k-current.short",
                "Raft-Service k-current.\(current.token)",
                "Raft-Service",
            ]
            for header in invalidHeaders {
                let response = try await get(header)
                #expect(response.status == .unauthorized, Comment(rawValue: header))
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            }
            #expect(try await get(current.header).status == .ok)
            #expect(try await get("Raft-Service v1 k-previous.\(previous.token)").status == .ok)

            source.set([PublicSearchServiceKey(keyId: "k-current", sha256: current.sha256)])
            #expect(try await get("Raft-Service v1 k-previous.\(previous.token)").status == .unauthorized)
            source.set([PublicSearchServiceKey(keyId: "k-next", sha256: next.sha256)])
            #expect(try await get(current.header).status == .unauthorized)
            #expect(try await get("Raft-Service v1 k-next.\(next.token)").status == .ok)
            source.set([PublicSearchServiceKey(keyId: "k-next", sha256: next.sha256, expiresAt: Date(timeIntervalSince1970: 32_503_680_000))])
            #expect(try await get("Raft-Service v1 k-next.\(next.token)").status == .serviceUnavailable)
            source.set([])
            #expect(try await get("Raft-Service v1 k-next.\(next.token)").status == .serviceUnavailable)
            #expect(try await get().status == .ok)
            source.set([PublicSearchServiceKey(keyId: "k-next", sha256: next.sha256)])
            let nextHeader = "Raft-Service v1 k-next.\(next.token)"

            directory.searchIndexEnabled = false
            #expect(try await get(nextHeader).status == .notFound)
            directory.searchIndexEnabled = true
            directory.apply(.setServerPublic(id: "server", visible: false))
            #expect(try await get(nextHeader).status == .notFound)
            directory.apply(.setServerPublic(id: "server", visible: true))

            _ = nextHeader
        }
    }

    // A fresh bucket: twelve service requests spend the minute, the thirteenth is limited.
    let rateSource = MutableKeySource([PublicSearchServiceKey(keyId: "k-next", sha256: next.sha256)])
    let (rateDirectory, rateSeed) = seedDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            publicSearch: rateDirectory.projectedCatalog(), publicServerDirectory: rateDirectory,
            publicSearchServiceKeySource: rateSource,
            publicSearchServiceBucket: PublicSearchMemoryBucketStore(),
            publicSearchServiceLimits: PublicSearchServiceLimits(environment: ["RAFT_LANDING_SERVICE_RATE_PER_MINUTE": "12"])
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[HTTPField.Name("Authorization")!] = "Raft-Service v1 k-next.\(next.token)"
            let url = "/api/public/search/servers/\(rateSeed.serverPublicId)"
            for index in 1...12 {
                let response = try await client.get(URI(string: url), headers: headers)
                #expect(response.status == .ok, Comment(rawValue: "request \(index)"))
            }
            let limited = try await client.get(URI(string: url), headers: headers)
            #expect(limited.status == .tooManyRequests)
            let retry = Int(limited.headers[HTTPField.Name("Retry-After")!] ?? "")
            #expect(retry != nil && retry! >= 1 && retry! <= 60)
            #expect(try await client.get(URI(string: url)).status == .ok, "anonymous bucket is separate")
        }
    }
}

@Test func servicePathFailsClosedWithoutASharedBucket() async throws {
    let current = ServiceCredential(token: "current-token-0123456789abcdef")
    let source = MutableKeySource([PublicSearchServiceKey(keyId: "k-current", sha256: current.sha256)])
    let (directory, seed) = seedDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            publicSearch: directory.projectedCatalog(), publicServerDirectory: directory,
            publicSearchServiceKeySource: source
        ))
        try await app.testing { client in
            let url = "/api/public/search/servers/\(seed.serverPublicId)"
            var headers = HTTPFields()
            headers[HTTPField.Name("Authorization")!] = current.header
            let service = try await client.get(URI(string: url), headers: headers)
            #expect(service.status == .serviceUnavailable)
            #expect(try await client.get(URI(string: url)).status == .ok)
        }
    }
}

private struct SlowKeySource: PublicSearchServiceKeyProviding {
    func keys() throws -> [PublicSearchServiceKey] {
        Thread.sleep(forTimeInterval: 1.5)
        return [PublicSearchServiceKey(keyId: "k-current", sha256: String(repeating: "a", count: 64))]
    }
}

private struct UnavailableBucket: PublicSearchBucketStoring {
    func consume(limit: Int) -> PublicSearchBucketDecision { .unavailable }
}

@Test func invalidKeySetsLimitsAndBucketUnavailabilityFailClosed() async throws {
    let current = ServiceCredential(token: "current-token-0123456789abcdef")
    let (directory, seed) = seedDirectory()
    let url = "/api/public/search/servers/\(seed.serverPublicId)"
    let invalidSets: [[PublicSearchServiceKey]] = [
        [PublicSearchServiceKey(keyId: "k-current", sha256: current.sha256), PublicSearchServiceKey(keyId: "k-current", sha256: current.sha256)],
        [PublicSearchServiceKey(keyId: "k-current", sha256: "not-a-digest")],
    ]
    for rows in invalidSets {
        let source = MutableKeySource(rows)
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                publicSearch: directory.projectedCatalog(), publicServerDirectory: directory,
                publicSearchServiceKeySource: source, publicSearchServiceBucket: PublicSearchMemoryBucketStore()
            ))
            try await app.testing { client in
                var headers = HTTPFields()
                headers[HTTPField.Name("Authorization")!] = current.header
                let service = try await client.get(URI(string: url), headers: headers)
                #expect(service.status == .serviceUnavailable)
                let anonymous = try await client.get(URI(string: url))
                #expect(anonymous.status == .ok)
            }
        }
    }
    let source = MutableKeySource([PublicSearchServiceKey(keyId: "k-current", sha256: current.sha256)])
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            publicSearch: directory.projectedCatalog(), publicServerDirectory: directory,
            publicSearchServiceKeySource: source, publicSearchServiceBucket: PublicSearchMemoryBucketStore(),
            publicSearchServiceLimits: PublicSearchServiceLimits(environment: ["RAFT_LANDING_SERVICE_RATE_PER_MINUTE": "0"])
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[HTTPField.Name("Authorization")!] = current.header
            let service = try await client.get(URI(string: url), headers: headers)
            #expect(service.status == .serviceUnavailable)
            let anonymous = try await client.get(URI(string: url))
            #expect(anonymous.status == .ok)
        }
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            publicSearch: directory.projectedCatalog(), publicServerDirectory: directory,
            publicSearchServiceKeySource: source, publicSearchServiceBucket: UnavailableBucket()
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[HTTPField.Name("Authorization")!] = current.header
            let service = try await client.get(URI(string: url), headers: headers)
            #expect(service.status == .serviceUnavailable)
            let anonymous = try await client.get(URI(string: url))
            #expect(anonymous.status == .ok)
        }
    }
}


@Test func keyLookupDeadlineFailsClosed() async throws {
    let current = ServiceCredential(token: "current-token-0123456789abcdef")
    let (directory, seed) = seedDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            publicSearch: directory.projectedCatalog(), publicServerDirectory: directory,
            publicSearchServiceKeySource: SlowKeySource(), publicSearchServiceBucket: PublicSearchMemoryBucketStore()
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[HTTPField.Name("Authorization")!] = current.header
            let service = try await client.get(URI(string: "/api/public/search/servers/\(seed.serverPublicId)"), headers: headers)
            #expect(service.status == .serviceUnavailable)
            let anonymous = try await client.get(URI(string: "/api/public/search/servers/\(seed.serverPublicId)"))
            #expect(anonymous.status == .ok)
        }
    }
}
