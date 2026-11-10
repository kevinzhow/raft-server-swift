import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

private let attachmentContractBytes = Data([0, 255, 13, 10, 65, 66, 67, 128])

private func withAttachmentContract(
    _ exercise: @escaping (any Client, HTTPFields, String) async throws -> Void
) async throws {
    let services = FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
        corsOrigins: ["https://app.example.com"])
    let accounts = services.emailAccounts
    let owner = UUID().uuidString.lowercased()
    let server = UUID().uuidString.lowercased()
    accounts.addAccount(id: owner, email: "attachment-contract@example.com", password: "password123")
    accounts.markEmailVerified(userId: owner)
    accounts.oauth.addOwnedServer(id: server, slug: "attachment-contract", name: "Attachment contract", ownerId: owner)
    let channel = accounts.oauth.createChannel(serverId: server, name: "attachment-contract", creatorUserId: owner)
    accounts.addPostableChannel(serverId: server, channelId: channel, memberId: owner, name: "attachment-contract")
    try await withApp { app in
        configure(app, services: services)
        try await app.testing { client in
            let login = try await client.send(.post, headers: [.contentType: "application/json"], to: "/api/auth/login") {
                $0.body = .init(string: "{\"email\":\"attachment-contract@example.com\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let object = try JSONSerialization.jsonObject(with: login.body.data ?? Data()) as? [String: Any]
            let token = try #require(object?["accessToken"] as? String)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = server
            try await exercise(client, headers, channel)
        }
    }
}

private func uploadContractAttachment(
    _ client: any Client, headers: HTTPFields, channel: String, filename: String, mime: String
) async throws -> String {
    let boundary = "attachment-response-contract"
    var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"channelId\"\r\n\r\n\(channel)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
    body.append(attachmentContractBytes)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    var uploadHeaders = headers
    uploadHeaders[.contentType] = "multipart/form-data; boundary=\(boundary)"
    let uploadBody = body
    let response = try await client.send(.post, headers: uploadHeaders, to: "/api/attachments/upload") {
        $0.body = .init(data: uploadBody)
    }
    #expect(response.status == .ok)
    let object = try JSONSerialization.jsonObject(with: response.body.data ?? Data()) as? [String: Any]
    let rows = try #require(object?["attachments"] as? [[String: Any]])
    return try #require(rows.first?["id"] as? String)
}

@Test func attachmentResponseIgnoresMalformedAndMultipleRangesAndResolvesSingleRanges() async throws {
    try await withAttachmentContract { client, headers, channel in
        let id = try await uploadContractAttachment(client, headers: headers, channel: channel, filename: "range.bin", mime: "application/octet-stream")
        let path = URI(string: "/api/attachments/\(id)")
        for raw in ["bytes=0-1,3-4", "bytes=abc-5", "bytes=1-abc", "items=0-1", "Bytes=0-1", "bytes =0-1", "bytes= 0-1", "bytes=0 -1", "bytes=0-1;extra", "bytes=-", "bytes=+1-2"] {
            var ranged = headers
            ranged[.range] = raw
            let response = try await client.send(.get, headers: ranged, to: path)
            #expect(response.status == .ok)
            #expect(response.body.data == attachmentContractBytes)
            #expect(response.headers[.contentRange] == nil)
        }
        let selections: [(String, Data, String)] = [
            ("bytes=1-3", Data(attachmentContractBytes[1...3]), "bytes 1-3/8"),
            ("bytes=5-", Data(attachmentContractBytes[5...7]), "bytes 5-7/8"),
            ("bytes=-2", Data(attachmentContractBytes[6...7]), "bytes 6-7/8"),
            ("bytes=2-999", Data(attachmentContractBytes[2...7]), "bytes 2-7/8"),
            ("bytes=-999", attachmentContractBytes, "bytes 0-7/8"),
            ("bytes=0001-0003", Data(attachmentContractBytes[1...3]), "bytes 1-3/8"),
            ("bytes=-999999999999999999999999999999", attachmentContractBytes, "bytes 0-7/8"),
            ("bytes=2-999999999999999999999999999999", Data(attachmentContractBytes[2...7]), "bytes 2-7/8"),
        ]
        for (raw, bytes, contentRange) in selections {
            var ranged = headers
            ranged[.range] = raw
            let response = try await client.send(.get, headers: ranged, to: path)
            #expect(response.status == .partialContent)
            #expect(response.body.data == bytes)
            #expect(response.headers[.contentRange] == contentRange)
            #expect(response.headers[.contentLength] == String(bytes.count))
        }
        var duplicated = headers
        duplicated.append(HTTPField(name: .range, value: "bytes=0-1"))
        duplicated.append(HTTPField(name: .range, value: "bytes=3-4"))
        let multipleFields = try await client.send(.get, headers: duplicated, to: path)
        #expect(multipleFields.status == .ok)
        #expect(multipleFields.body.data == attachmentContractBytes)
        let infinite = String(repeating: "9", count: 400)
        for raw in ["bytes=8-", "bytes=4-2", "bytes=-0", "bytes=999999999999999999999-", "bytes=-\(infinite)", "bytes=0-\(infinite)"] {
            var ranged = headers
            ranged[.range] = raw
            let response = try await client.send(.get, headers: ranged, to: path)
            #expect(response.status == .rangeNotSatisfiable)
            #expect(response.headers[.contentRange] == "bytes */8")
            #expect((response.body.data ?? Data()).isEmpty)
        }
        var anonymous = HTTPFields()
        anonymous[.range] = "bytes=abc-5"
        let denied = try await client.send(.get, headers: anonymous, to: path)
        #expect(denied.status == .unauthorized)
        #expect(denied.body.data != attachmentContractBytes)
    }
}

@Test func attachmentResponseSelectsNodeDispositionMimeAndConfiguredFramePolicy() async throws {
    try await withAttachmentContract { client, headers, channel in
        let rows: [(String, String, String, String, Bool)] = [
            ("image.png", "image/png", "", "inline", false),
            ("image.png", "image/png", "?download=1", "attachment", false),
            ("image.png", "image/png", "?disposition=attachment", "attachment", false),
            ("document.pdf", "application/pdf", "", "attachment", false),
            ("document.pdf", "application/pdf", "?disposition=inline", "inline", true),
            ("document.pdf", "application/pdf", "?disposition=inline&download=1", "attachment", true),
            ("movie.webm", "video/webm", "?disposition=inline", "inline", true),
            ("music.flac", "audio/flac", "?disposition=inline", "inline", true),
            ("unsafe.html", "text/html", "?disposition=inline", "attachment", false),
            ("unsafe.svg", "image/svg+xml", "?disposition=inline", "attachment", false),
            ("image.avif", "image/avif", "?disposition=inline", "attachment", false),
            ("image.heic", "image/heic", "?disposition=inline", "attachment", false),
        ]
        for (filename, mime, query, disposition, preview) in rows {
            let id = try await uploadContractAttachment(client, headers: headers, channel: channel, filename: filename, mime: mime)
            var spoofed = headers
            spoofed[.origin] = "https://untrusted.example.com"
            spoofed[HTTPField.Name("Host")!] = "untrusted.example.com"
            let response = try await client.send(.get, headers: spoofed, to: URI(string: "/api/attachments/\(id)\(query)"))
            #expect(response.status == .ok)
            #expect(response.body.data == attachmentContractBytes)
            #expect(response.headers[.contentDisposition] == "\(disposition); filename=\"\(filename)\"; filename*=UTF-8''\(filename)")
            #expect(response.headers[HTTPField.Name("X-Content-Type-Options")!] == "nosniff")
            if preview {
                #expect(response.headers[.contentSecurityPolicy] == "frame-ancestors 'self' https://app.example.com app://raft")
                #expect(response.headers[HTTPField.Name("X-Frame-Options")!] == nil)
                #expect(response.headers[HTTPField.Name("Cross-Origin-Resource-Policy")!] == "cross-origin")
                #expect(response.headers[HTTPField.Name("Referrer-Policy")!] == "no-referrer")
            }
            #expect(response.headers[.contentSecurityPolicy]?.contains("untrusted.example.com") != true)
        }
    }
}

@Test func attachmentResponseInfersExactNodeFilenameMimeAndAddsTextCharset() async throws {
    try await withAttachmentContract { client, headers, channel in
        for (filename, mime) in [("movie.mov", "video/quicktime"), ("audio.weba", "audio/webm"), ("audio.oga", "audio/ogg"),
                                 ("notes.md", "text/markdown; charset=utf-8"), ("rows.csv", "text/csv; charset=utf-8"),
                                 ("data.json", "application/json; charset=utf-8"), ("unknown.yaml", "application/octet-stream")] {
            let id = try await uploadContractAttachment(client, headers: headers, channel: channel, filename: filename, mime: "application/octet-stream")
            let response = try await client.send(.get, headers: headers, to: URI(string: "/api/attachments/\(id)?disposition=inline"))
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == mime)
            #expect(response.body.data == attachmentContractBytes)
        }
        let id = try await uploadContractAttachment(client, headers: headers, channel: channel, filename: "café.txt", mime: "text/plain")
        let response = try await client.send(.get, headers: headers, to: URI(string: "/api/attachments/\(id)"))
        #expect(response.headers[.contentType] == "text/plain; charset=utf-8")
        #expect(response.headers[.contentDisposition] == "attachment; filename=\"caf_.txt\"; filename*=UTF-8''caf%C3%A9.txt")
    }
}
