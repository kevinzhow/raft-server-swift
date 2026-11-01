import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func announcementImagesRequireAPublishedStartedAnnouncement() async throws {
    let accounts = EmailLoginDirectory()
    let imageId = "00000000-0000-4000-8000-00000000a101"
    let announcementId = accounts.addAnnouncementForTesting(
        title: "Image",
        pages: ["{\"body\":\"Body\"}"],
        startsAt: Date().addingTimeInterval(86_400),
        status: "draft",
        publishedAt: nil,
        imageId: imageId
    )
    accounts.addAnnouncementImageForTesting(
        id: imageId,
        announcementId: announcementId,
        contentType: "image/png",
        bytes: Data([1, 2, 3])
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let draft = try await client.get(URI(string: "/api/announcements/images/\(imageId)"))
            #expect(draft.status == .notFound)

            accounts.setAnnouncementStateForTesting(
                id: announcementId,
                status: "published",
                publishedAt: Date(),
                startsAt: Date().addingTimeInterval(86_400)
            )
            let future = try await client.get(URI(string: "/api/announcements/images/\(imageId)"))
            #expect(future.status == .notFound)

            accounts.setAnnouncementStateForTesting(
                id: announcementId,
                status: "published",
                publishedAt: Date(),
                startsAt: Date().addingTimeInterval(-60)
            )
            let published = try await client.get(URI(string: "/api/announcements/images/\(imageId)"))
            #expect(published.status == .ok)
            #expect(published.headers[.contentType] == "image/png")
            #expect(published.headers[HTTPField.Name("Cache-Control")!] == "public, max-age=31536000, immutable")
            #expect(published.headers[HTTPField.Name("Cross-Origin-Resource-Policy")!] == "cross-origin")
            #expect(Data((published.body.string ?? "").utf8) == Data([1, 2, 3]))

            accounts.setAnnouncementStateForTesting(
                id: announcementId,
                status: "expired",
                publishedAt: Date(),
                startsAt: Date().addingTimeInterval(-60)
            )
            #expect(try await client.get(URI(string: "/api/announcements/images/\(imageId)")).status == .ok)
            #expect(try await client.get(URI(string: "/api/announcements/images/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")).status == .notFound)

            accounts.setAnnouncementImageStorageAvailableForTesting(false)
            #expect(try await client.get(URI(string: "/api/announcements/images/\(imageId)")).status == .serviceUnavailable)
        }
    }
}
