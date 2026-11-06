import Foundation
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func publicSearchIndexWalksBoundedPagesExactlyOnce() async throws {
    let directory = PublicServerDirectory()
    directory.searchIndexEnabled = true
    for index in 0..<28 {
        _ = directory.addServer(
            id: "server-\(index)", name: "Paged \(index)", slug: "paged-\(index)",
            ownerId: "owner-\(index)", ownerToken: "token-\(index)", publiclyVisible: true,
            channels: [(id: "open-\(index)", name: "open-\(index)", description: nil, guestVisible: true, publicId: nil, threads: [
                (id: "thread-\(index)", publicId: nil, parent: "Question \(index)", replies: ["Reply \(index)"]),
            ])]
        )
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, publicSearch: directory.projectedCatalog(), publicServerDirectory: directory))
        try await app.testing { client in
            var seen: [String] = []
            var cursor: String?
            var pages = 0
            repeat {
                let query = cursor.map { "?cursor=\($0)" } ?? ""
                let response = try await client.get(URI(string: "/api/public/search/index\(query)"))
                #expect(response.status == .ok)
                let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                let entries = body["entries"] as? [[String: Any]] ?? []
                let paths = entries.compactMap { $0["canonicalPath"] as? String }
                let servers = Set(paths.compactMap { $0.split(separator: "/").dropFirst(2).first.map(String.init) })
                #expect(servers.count <= 25, "a page covers at most 25 servers with entries")
                seen.append(contentsOf: paths)
                cursor = body["nextCursor"] as? String
                pages += 1
                #expect(pages < 10)
            } while cursor != nil
            #expect(pages >= 2, "28 servers do not fit one page")
            #expect(Set(seen).count == seen.count, "no entry twice")
            #expect(seen.count == 28 * 3, "every entry once")
        }
    }
}

@Test func emptyCandidatePagesReturnAForwardCursor() async throws {
    let directory = PublicServerDirectory()
    directory.searchIndexEnabled = true
    for index in 0..<510 {
        _ = directory.addServer(
            id: "hidden-\(index)", name: "Hidden \(index)", slug: "hidden-\(index)",
            ownerId: "owner-\(index)", ownerToken: "token-\(index)",
            publiclyVisible: true, publicSearchEnabled: false
        )
        directory.setServerPublicIdForTesting(serverId: "hidden-\(index)", publicId: String(format: "%032x", index))
    }
    _ = directory.addServer(
        id: "eligible", name: "Eligible", slug: "eligible",
        ownerId: "owner-e", ownerToken: "token-e", publiclyVisible: true,
        channels: [(id: "open", name: "open", description: nil, guestVisible: true, publicId: nil, threads: [
            (id: "thread", publicId: nil, parent: "Question", replies: ["Reply"]),
        ])]
    )
    directory.setServerPublicIdForTesting(serverId: "eligible", publicId: String(repeating: "f", count: 32))
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, publicSearch: directory.projectedCatalog(), publicServerDirectory: directory))
        try await app.testing { client in
            var cursor: String?
            var allPaths: [String] = []
            var pages = 0
            var firstPageEntries: [[String: Any]] = []
            repeat {
                let query = cursor.map { "?cursor=\($0)" } ?? ""
                let response = try await client.get(URI(string: "/api/public/search/index\(query)"))
                let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                let entries = body["entries"] as? [[String: Any]] ?? []
                if pages == 0 { firstPageEntries = entries }
                allPaths.append(contentsOf: entries.compactMap { $0["canonicalPath"] as? String })
                cursor = body["nextCursor"] as? String
                pages += 1
                #expect(pages < 6)
            } while cursor != nil
            #expect(firstPageEntries.isEmpty, "the first 500 candidates produce nothing")
            #expect(allPaths.count == 3, "the eligible server's three entries appear exactly once")
        }
    }
}
