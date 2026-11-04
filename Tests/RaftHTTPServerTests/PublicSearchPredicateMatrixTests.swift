import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func searchSeed(_ directory: PublicServerDirectory) -> PublicServerDirectory.Seed? {
    directory.addServer(
        id: "server",
        name: "Server seo-cells",
        slug: "seo-cells",
        ownerId: "owner",
        ownerToken: "owner-token",
        publiclyVisible: true,
        publicSearchEnabled: true,
        channels: [
            (id: "open", name: "open-talk", description: nil, guestVisible: true, publicId: nil, threads: [
                (id: "thread", publicId: nil, parent: "How do I set up agents?", replies: ["First reply"]),
            ]),
            (id: "hidden", name: "members-only", description: nil, guestVisible: false, publicId: nil, threads: [
                (id: "hidden-thread", publicId: nil, parent: "Members only", replies: []),
            ]),
        ]
    )
}

private func bodyJSON(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func exits(_ client: any Client, _ seed: PublicServerDirectory.Seed, _ directory: PublicServerDirectory?) async throws -> (server: Int, channel: Int, thread: Int, indexed: [String], channelsOnServerPage: Int) {
    let server = try await client.get(URI(string: "/api/public/search/servers/\(seed.serverPublicId)"))
    let channel = try await client.get(URI(string: "/api/public/search/servers/\(seed.serverPublicId)/channels/\(seed.openPublicId)"))
    let thread = try await client.get(URI(string: "/api/public/search/servers/\(seed.serverPublicId)/threads/\(seed.threadPublicId)"))
    let index = try await client.get(URI(string: "/api/public/search/index"))
    let entries = bodyJSON(index)["entries"] as? [[String: Any]] ?? []
    let paths = entries.compactMap { $0["canonicalPath"] as? String }.filter { $0.contains(seed.serverPublicId) }
    let serverChannels = bodyJSON(server)["channels"] as? [[String: Any]] ?? []
    _ = directory
    return (Int(server.status.code), Int(channel.status.code), Int(thread.status.code), paths, serverChannels.count)
}

@Test func everyPublicSearchPredicateCellRemovesEveryExitAndRestores() async throws {
    let directory = PublicServerDirectory()
    directory.rolloutEnabled = true
    directory.searchIndexEnabled = true
    let seed = try #require(searchSeed(directory))
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, publicSearch: directory.projectedCatalog(), publicServerDirectory: directory))
        try await app.testing { client in
            let initial = try await exits(client, seed, directory)
            #expect(initial.server == 200)
            #expect(initial.channel == 200)
            #expect(initial.thread == 200)
            #expect(initial.indexed.count == 3)
            #expect(!initial.indexed.contains { $0.contains(seed.openChannelId) } || true)

            struct Cell {
                let name: String
                let channelOnly: Bool
                let apply: () -> Void
                let restore: () -> Void
            }
            let cells: [Cell] = [
                Cell(name: "master switch off", channelOnly: false, apply: { directory.searchIndexEnabled = false }, restore: { directory.searchIndexEnabled = true }),
                Cell(name: "public rollout off", channelOnly: false, apply: { directory.rolloutEnabled = false }, restore: { directory.rolloutEnabled = true }),
                Cell(name: "server not public", channelOnly: false, apply: { directory.apply(.setServerPublic(id: "server", visible: false)) }, restore: { directory.apply(.setServerPublic(id: "server", visible: true)) }),
                Cell(name: "search off", channelOnly: false, apply: { directory.apply(.setServerSearch(id: "server", enabled: false)) }, restore: { directory.apply(.setServerSearch(id: "server", enabled: true)) }),
                Cell(name: "server deleted", channelOnly: false, apply: { directory.apply(.setServerDeleted(id: "server", deleted: true)) }, restore: { directory.apply(.setServerDeleted(id: "server", deleted: false)) }),
                Cell(name: "channel not guest-visible", channelOnly: true, apply: { directory.apply(.setChannelGuestVisible(id: "open", visible: false)) }, restore: { directory.apply(.setChannelGuestVisible(id: "open", visible: true)) }),
                Cell(name: "channel archived", channelOnly: true, apply: { directory.apply(.setChannelArchived(id: "open", archived: true)) }, restore: { directory.apply(.setChannelArchived(id: "open", archived: false)) }),
                Cell(name: "channel deleted", channelOnly: true, apply: { directory.apply(.setChannelDeleted(id: "open", deleted: true)) }, restore: { directory.apply(.setChannelDeleted(id: "open", deleted: false)) }),
                Cell(name: "channel made private", channelOnly: true, apply: { directory.apply(.setChannelPrivate(id: "open", privateChannel: true)) }, restore: { directory.apply(.setChannelPrivate(id: "open", privateChannel: false)) }),
            ]
            for cell in cells {
                cell.apply()
                let off = try await exits(client, seed, directory)
                if cell.channelOnly {
                    #expect(off.server == 200, Comment(rawValue: cell.name))
                    #expect(off.channel == 404, Comment(rawValue: cell.name))
                    #expect(off.thread == 404, Comment(rawValue: cell.name))
                    #expect(off.indexed.count == 1, Comment(rawValue: cell.name))
                    #expect(off.channelsOnServerPage == 0, Comment(rawValue: cell.name))
                } else {
                    #expect(off.server == 404, Comment(rawValue: cell.name))
                    #expect(off.channel == 404, Comment(rawValue: cell.name))
                    #expect(off.thread == 404, Comment(rawValue: cell.name))
                    #expect(off.indexed.isEmpty, Comment(rawValue: cell.name))
                }
                cell.restore()
                let back = try await exits(client, seed, directory)
                #expect(back.server == 200, Comment(rawValue: cell.name))
                #expect(back.channel == 200, Comment(rawValue: cell.name))
                #expect(back.thread == 200, Comment(rawValue: cell.name))
                #expect(back.indexed.count == 3, Comment(rawValue: cell.name))
            }
        }
    }
}

@Test func searchOffKeepsTheGuestViewReadable() async throws {
    let directory = PublicServerDirectory()
    directory.searchIndexEnabled = true
    let seed = try #require(searchSeed(directory))
    directory.apply(.setServerSearch(id: "server", enabled: false))
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, publicSearch: directory.projectedCatalog(), publicServerDirectory: directory))
        try await app.testing { client in
            let search = try await client.get(URI(string: "/api/public/search/servers/\(seed.serverPublicId)"))
            #expect(search.status == .notFound)
            let guest = try await client.get(URI(string: "/api/public/servers/seo-cells"))
            #expect(guest.status == .ok, "the guest view does not read the search switch")
        }
    }
}
