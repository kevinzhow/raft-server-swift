import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func externalAvatarServesOnlyActiveMaterializedArtifacts() async throws {
    let accounts = EmailLoginDirectory()
    let artifactId = "00000000-0000-4000-8000-00000000b101"
    let bytes = Data([1, 2, 3])
    let digest = String(repeating: "0", count: 64)
    accounts.addExternalAvatarForTesting(
        id: artifactId,
        contentType: "image/webp",
        bytes: bytes,
        sourceDigest: digest
    )
    let inactiveId = "00000000-0000-4000-8000-00000000b102"
    accounts.addExternalAvatarForTesting(
        id: inactiveId,
        contentType: "image/webp",
        bytes: bytes,
        sourceDigest: digest,
        active: false
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let response = try await client.get(URI(string: "/api/external-avatars/\(artifactId).webp"))
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "image/webp")
            #expect(response.headers[HTTPField.Name("Cross-Origin-Resource-Policy")!] == "cross-origin")
            #expect(response.headers[HTTPField.Name("Content-Disposition")!] == "inline")
            #expect(response.headers[HTTPField.Name("Cache-Control")!] == "public, no-cache, must-revalidate")
            #expect(response.headers[HTTPField.Name("ETag")!] == "\"sha256-\(digest)\"")
            #expect(Data((response.body.string ?? "").utf8) == bytes)

            #expect(try await client.get(URI(string: "/api/external-avatars/not-a-uuid.webp")).status == .notFound)
            #expect(try await client.get(URI(string: "/api/external-avatars/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.webp")).status == .notFound)
            #expect(try await client.get(URI(string: "/api/external-avatars/\(inactiveId).webp")).status == .notFound)
            #expect(try await client.get(URI(string: "/api/external-avatars/\(artifactId).png")).status == .notFound)

            accounts.setExternalAvatarStorageAvailableForTesting(false)
            #expect(try await client.get(URI(string: "/api/external-avatars/\(artifactId).webp")).status == .serviceUnavailable)
        }
    }
}
