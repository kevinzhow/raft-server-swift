import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import RaftObjectStorage
import Testing
import TestSupport
import Vapor
import VaporTesting

/// `GET /api/attachments/:id/preview` published by the pinned server at
/// `packages/server/src/routes/attachments.ts:1319-1366`.
///
/// The route answers `200` with `{status,...}` for both a built preview and an
/// unsupported file; it never turns a readable image/HTML file into `415`.
/// Access uses the same Flex admission as the download routes.
private func previewHeaders(_ setup: AttachmentPreviewAccounts) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = setup.authorization
    headers[HTTPField.Name("X-Server-Id")!] = setup.serverId
    return headers
}

private func previewObject(_ response: ClientResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: response.body.data ?? Data()) as? [String: Any])
}

@Test func attachmentPreviewBuildsTextAndPublishesUpstreamErrors() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        let setup = AttachmentPreviewAccounts(storage: fixture.storage)
        let bytes = Data("attachment preview text\nsecond line\n".utf8)
        let id = try await setup.upload(bytes, filename: "acceptance.txt", mime: "text/plain")
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {}, emailAccounts: setup.accounts))
            try await app.testing { client in
                let response = try await client.get(
                    URI(string: "/api/attachments/\(id)/preview"), headers: previewHeaders(setup))
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "private, no-store")
                #expect(response.body.string == #"{"status":"ok","data":{"kind":"text","text":"attachment preview text\nsecond line\n"},"truncated":false}"#)

                let missing = try await client.get(
                    URI(string: "/api/attachments/11111111-1111-4111-8111-111111111999/preview"),
                    headers: previewHeaders(setup))
                #expect(missing.status == .notFound)
                #expect(try previewObject(missing)["error"] as? String == "Attachment not found")

                let malformed = try await client.get(
                    URI(string: "/api/attachments/not-a-uuid/preview"), headers: previewHeaders(setup))
                #expect(malformed.status == .badRequest)
                #expect(malformed.body.string == #"{"error":"A valid attachment id is required","code":"invalid_attachment_id"}"#)
            }
        }
        await fixture.stop()
    } catch {
        await fixture.stop()
        throw error
    }
}

@Test func attachmentPreviewKeepsReadableUnsupportedTypesOutOf415() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        let setup = AttachmentPreviewAccounts(storage: fixture.storage)
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x01, 0x02])
        let pngId = try await setup.upload(png, filename: "shot.png", mime: "image/png")
        let html = Data("<html><body>readable HTML has a separate preview route</body></html>".utf8)
        let htmlId = try await setup.upload(html, filename: "page.html", mime: "text/html")
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {}, emailAccounts: setup.accounts))
            try await app.testing { client in
                for id in [pngId, htmlId] {
                    let response = try await client.get(
                        URI(string: "/api/attachments/\(id)/preview"), headers: previewHeaders(setup))
                    #expect(response.status == .ok)
                    #expect(response.headers[.cacheControl] == "private, no-store")
                    #expect(response.body.string == #"{"status":"unsupported","reason":"unsupported"}"#)
                }
            }
        }
        await fixture.stop()
    } catch {
        await fixture.stop()
        throw error
    }
}

@Test func attachmentPreviewAppliesProviderCapsAndShapes() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        let setup = AttachmentPreviewAccounts(storage: fixture.storage)
        let largeText = Data(String(repeating: "a", count: 100_000).utf8)
        let largeId = try await setup.upload(largeText, filename: "large.log", mime: "text/plain")
        let csv = Data("name,age\nAda,36\nBob,40\n".utf8)
        let csvId = try await setup.upload(csv, filename: "people.csv", mime: "text/csv")
        let markdown = Data("# Heading\n\nbody\n".utf8)
        let markdownId = try await setup.upload(markdown, filename: "notes.md", mime: "text/markdown")
        let diff = Data("diff --git a/a.txt b/a.txt\n@@ -1 +1 @@\n-old\n+new\n".utf8)
        let diffId = try await setup.upload(diff, filename: "change.patch", mime: "text/x-diff")
        let pdf = Data("%PDF-1.7 synthetic".utf8)
        let pdfId = try await setup.upload(pdf, filename: "report.pdf", mime: "application/pdf")
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {}, emailAccounts: setup.accounts))
            try await app.testing { client in
                let large = try await client.get(
                    URI(string: "/api/attachments/\(largeId)/preview"), headers: previewHeaders(setup))
                #expect(large.status == .ok)
                let largeBody = try previewObject(large)
                #expect(largeBody["truncated"] as? Bool == true)
                let data = try #require(largeBody["data"] as? [String: Any])
                #expect(data["kind"] as? String == "text")
                #expect((data["text"] as? String)?.count == 96 * 1024)

                let csvResponse = try await client.get(
                    URI(string: "/api/attachments/\(csvId)/preview"), headers: previewHeaders(setup))
                #expect(csvResponse.body.string == #"{"status":"ok","data":{"kind":"csv","delimiter":",","headers":["name","age"],"rows":[["Ada","36"],["Bob","40"]],"rowCount":2,"columnCount":2},"truncated":false}"#)

                let markdownResponse = try await client.get(
                    URI(string: "/api/attachments/\(markdownId)/preview"), headers: previewHeaders(setup))
                #expect(markdownResponse.body.string == "{\"status\":\"ok\",\"data\":{\"kind\":\"markdown\",\"markdown\":\"# Heading\\n\\nbody\"},\"truncated\":false}")

                let diffResponse = try await client.get(
                    URI(string: "/api/attachments/\(diffId)/preview"), headers: previewHeaders(setup))
                #expect(diffResponse.body.string == #"{"status":"ok","data":{"kind":"diff","stats":{"files":1,"hunks":1,"additions":1,"deletions":1}},"truncated":false}"#)

                let pdfResponse = try await client.get(
                    URI(string: "/api/attachments/\(pdfId)/preview"), headers: previewHeaders(setup))
                #expect(pdfResponse.body.string == #"{"status":"ok","data":{"kind":"pdf"},"truncated":true}"#)
            }
        }
        await fixture.stop()
    } catch {
        await fixture.stop()
        throw error
    }
}
