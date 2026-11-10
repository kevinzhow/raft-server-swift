import TestSupport
import Foundation
import HTTPTypes
@testable import RaftHTTP
@testable import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func htmlPreviewAppendsTheInertBridgeAndDownloadStaysByteIdentical() async throws {
    let accounts = EmailLoginDirectory()
    accounts.oauth.jwtSecret = attachmentPreviewFixtureSigningSecret
    let serverId = "33333333-3333-4333-8333-333333333679"
    let ownerId = "11111111-1111-4111-8111-111111111639"
    let ownerEmail = "preview-bridge-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "preview-bridge", name: "Preview Bridge", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "preview-bridge-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "preview-bridge-room")
    let html = "<!doctype html><html><body><h1>Report</h1><p>D0>=35</p></body></html>"
    let htmlBytes = Data(html.utf8)
    let attachment = accounts.addChannelAttachment(channelId: channel, uploaderId: ownerId, filename: "report.html",
        mimeType: "text/html", sizeBytes: htmlBytes.count, bytes: htmlBytes)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let urlResponse = try await client.get(URI(string: "/api/attachments/\(attachment)/html-preview-url"), headers: headers)
            #expect(urlResponse.status == .ok)
            let urlBody = (try JSONSerialization.jsonObject(with: Data((urlResponse.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let url = try #require(urlBody["url"] as? String)

            let preview = try await client.get(URI(string: url))
            #expect(preview.status == .ok)
            #expect(preview.headers[HTTPField.Name("Content-Length")!] == nil, "the stored size must not truncate the appended bridge")
            let csp = preview.headers[HTTPField.Name("Content-Security-Policy")!] ?? ""
            for directive in ["default-src 'none'", "sandbox allow-scripts", "connect-src 'none'", "form-action 'none'", "object-src 'none'", "base-uri 'none'", "worker-src 'none'"] {
                #expect(csp.contains(directive), "preview CSP must keep \(directive)")
            }
            let previewBody = try await collectedBody(preview)
            #expect(previewBody == html + AttachmentPreviewBridge.script, "the document streams unmodified with the bridge appended")

            // Downloads stay byte-identical to the stored object.
            let download = try await client.get(URI(string: "/api/attachments/\(attachment)?serverId=\(serverId)&token=\(token)"))
            #expect(download.status == .ok)
            #expect(download.body.string == html)
            #expect(download.body.data == htmlBytes)
            #expect(download.headers[.contentType] == "text/html; charset=utf-8")
            #expect(download.headers[.contentLength] == String(htmlBytes.count))
            #expect(download.headers[.contentDisposition]?.hasPrefix("attachment;") == true)
        }
    }
}

@Test func htmlPreviewBridgePreservesBytesAndScansOnlyActiveBoundedHead() async throws {
    let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"script-src 'none'\">"
    let prefix = Data("<!doctype html><head><!-- \(meta) --><script>var inert = '\(meta)';</script>".utf8)
    var html = prefix
    html.append(Data(meta.utf8))
    html.append(Data("</head><body>synthetic".utf8))
    html.append(contentsOf: [0, 255, 254])
    html.append(Data("</body>".utf8))
    let response = try AttachmentHTMLPreviewResponse.make(.init(bytes: html, filename: "report.html", mimeType: "text/html"), frameAncestors: [])
    var expected = prefix
    expected.append(Data(AttachmentPreviewBridge.script.utf8))
    expected.append(html.dropFirst(prefix.count))
    #expect(try await response.body.data() == expected)
    #expect(AttachmentHTMLPreviewResponse.cspMetaStart(html) == prefix.count)
    for hidden in ["<head><template>\(meta)</template></head>", "<head><style>\(meta)</style></head>", "<head></head><body>\(meta)"] {
        #expect(AttachmentHTMLPreviewResponse.cspMetaStart(Data(hidden.utf8)) == nil)
    }
    var overLimit = Data(repeating: 32, count: AttachmentHTMLPreviewResponse.headScanLimitBytes)
    overLimit.append(Data(meta.utf8))
    #expect(AttachmentHTMLPreviewResponse.cspMetaStart(overLimit) == nil)
}

@Test func htmlPreviewFrameAncestorsAdmitOnlyConfiguredExactOrigins() {
    let policy = AttachmentHTMLPreviewResponse.policy([
        "https://EXAMPLE.com:443/path?q=1", "https://example.com", "*", "https://*.example.com",
        "https://example.com:8443/", "https://user:synthetic@example.com", "data:text/html,synthetic",
    ])
    #expect(policy.hasSuffix("frame-ancestors 'self' https://example.com https://example.com:8443 app://raft"))
    #expect(!policy.contains("allow-same-origin"))
    #expect(!policy.contains("*"))
    #expect(!policy.contains("synthetic"))
}

private func collectedBody(_ response: ClientResponse) async throws -> String {
    final class Box: @unchecked Sendable {
        var text = ""
        let lock = NSLock()
    }
    let box = Box()
    try await response.body.withStreamingBytes { span in
        var bytes: [UInt8] = []
        bytes.reserveCapacity(span.count)
        for index in span.indices { bytes.append(span[index]) }
        box.lock.withLock { box.text += String(decoding: bytes, as: UTF8.self) }
    }
    return box.lock.withLock { box.text }
}
