import Foundation
import Glibc
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

final class FakeHands: @unchecked Sendable {
    struct Captured: Sendable {
        let path: String
        let body: String
        let contentType: String
    }

    private let status: Int
    private let responseBody: String
    private let lock = NSLock()
    private var captured: [Captured] = []
    private var serverFD: Int32 = -1
    private var stopped = false
    let port: Int

    init(status: Int, responseBody: String) throws {
        self.status = status
        self.responseBody = responseBody
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw NSError(domain: "FakeHands", code: 1) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw NSError(domain: "FakeHands", code: 2) }
        listen(fd, 16)
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
        serverFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
    }

    func requests() -> [Captured] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
    }

    private func acceptLoop() {
        while true {
            lock.lock(); let fd = serverFD; let isStopped = stopped; lock.unlock()
            if isStopped || fd < 0 { return }
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let count = read(client, &chunk, chunk.count)
            if count <= 0 { return }
            buffer.append(contentsOf: chunk[0..<count])
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
        }
        let headerData = buffer[..<headerEnd!.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let contentType = lines.first { $0.lowercased().hasPrefix("content-type:") }?
            .split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let contentLength = lines.first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        var body = Data(buffer[headerEnd!.upperBound...])
        while body.count < contentLength {
            let count = read(client, &chunk, chunk.count)
            if count <= 0 { break }
            body.append(contentsOf: chunk[0..<count])
        }
        lock.lock()
        captured.append(Captured(path: path, body: String(decoding: body, as: UTF8.self), contentType: contentType))
        lock.unlock()
        let response = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"
        _ = response.withCString { pointer in write(client, pointer, strlen(pointer)) }
    }
}

private struct FeedbackFixture {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-000001102001"
    let token: String

    init() {
        accounts.addAccount(id: userId, email: "diagnostics-feedback@hands.test", password: "password123")
        accounts.markEmailVerified(userId: userId)
        token = accounts.mintAccessTokenForTesting(userId: userId)
    }
}

private func multipart(_ fields: [String: String]) -> (body: String, contentType: String) {
    let boundary = "raft-test-boundary"
    var body = ""
    for (name, value) in fields {
        body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
    }
    body += "--\(boundary)--\r\n"
    return (body, "multipart/form-data; boundary=\(boundary)")
}

private func fieldValue(_ body: String, _ name: String) -> String? {
    guard let range = body.range(of: "name=\"\(name)\"") else { return nil }
    let rest = body[range.upperBound...]
    guard let separator = rest.range(of: "\r\n\r\n") else { return nil }
    let after = rest[separator.upperBound...]
    guard let end = after.range(of: "\r\n--") else { return nil }
    return String(after[..<end.lowerBound])
}

private func submit(_ client: any Client, _ fixture: FeedbackFixture, kind: String, diagnostics: String?) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var fields: [String: String] = [
        "type": "problem",
        "message": "feedback from \(kind)",
        "submission_id": "77777777-7777-4777-8777-777777777777",
        "may_contact": "false",
        "metadata": "{\"client_kind\":\"\(kind)\",\"platform\":\"\(kind)\",\"client_version\":\"1.0.0\"}",
    ]
    if let diagnostics { fields["diagnostics"] = diagnostics }
    let form = multipart(fields)
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(fixture.token)"
    headers[.contentType] = form.contentType
    headers[HTTPField.Name("X-Raft-Client-Kind")!] = kind
    let response = try await client.send(.post, headers: headers, to: URI(string: "/api/product-feedback")) { request in
        request.body = .init(string: form.body)
    }
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

private func diagnosticsJSON() -> String {
    "{\"r2_key\":\"feedback/11111111-1111-4111-8111-111111111111/presigned/0f0e0d0c-0b0a-4908-8706-050403020100-diagnostics.zip\",\"filename\":\"diagnostics.zip\",\"content_type\":\"application/zip\",\"size\":4096}"
}

@Test func mobileDiagnosticsForwardPresignedReferenceToHands() async throws {
    for (index, kind) in ["android", "ios", "ohos"].enumerated() {
        let fake = try FakeHands(status: 201, responseBody: "{\"id\":\"ticket-\(index)\",\"status\":\"open\"}")
        defer { fake.stop() }
        let fixture = FeedbackFixture()
        fixture.accounts.setHandsFeedbackForTesting(baseURL: "http://127.0.0.1:\(fake.port)", appId: "11111111-1111-4111-8111-111111111111", appToken: "app_token")
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
            try await app.testing { client in
                let result = try await submit(client, fixture, kind: kind, diagnostics: diagnosticsJSON())
                #expect(result.status == .created, Comment(rawValue: "\(kind) \(result.body)"))
                let captured = fake.requests()
                let create = try #require(captured.first { $0.path.hasSuffix("/feedback") })
                let presigned = try #require(fieldValue(create.body, "presigned"))
                #expect(presigned.contains("\"r2_key\""))
                #expect(presigned.contains("diagnostics.zip"))
            }
        }
    }
}

@Test func diagnosticsValidationAndHandsOutcomeMapping() async throws {
    let fake = try FakeHands(status: 201, responseBody: "{\"id\":\"ticket-ok\",\"status\":\"open\"}")
    defer { fake.stop() }
    let fixture = FeedbackFixture()
    fixture.accounts.setHandsFeedbackForTesting(baseURL: "http://127.0.0.1:\(fake.port)", appId: "11111111-1111-4111-8111-111111111111", appToken: "app_token")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            // No diagnostics: no presigned field.
            let plain = try await submit(client, fixture, kind: "android", diagnostics: nil)
            #expect(plain.status == .created)
            let plainCreate = try #require(fake.requests().last { $0.path.hasSuffix("/feedback") })
            #expect(fieldValue(plainCreate.body, "presigned") == nil)

            // Invalid diagnostics never reach Hands.
            let before = fake.requests().count
            let invalid: [(String, String)] = [
                ("web", diagnosticsJSON()),
                ("android", "not json"),
                ("android", "[\(diagnosticsJSON())]"),
                ("android", diagnosticsJSON().replacingOccurrences(of: "application/zip", with: "image/png")),
                ("android", diagnosticsJSON().replacingOccurrences(of: "diagnostics.zip", with: "diagnostics.tar")),
                ("android", diagnosticsJSON().replacingOccurrences(of: "\"size\":4096", with: "\"size\":0")),
                ("android", diagnosticsJSON().replacingOccurrences(of: "\"size\":4096", with: "\"size\":\"4096\"")),
                ("android", diagnosticsJSON().replacingOccurrences(of: "/presigned/", with: "/inline/")),
                ("android", diagnosticsJSON() + ",\"upload_url\":\"https://r2.example/put\""),
            ]
            for (kind, diagnostics) in invalid {
                let result = try await submit(client, fixture, kind: kind, diagnostics: diagnostics)
                #expect(result.status == .badRequest, Comment(rawValue: diagnostics))
                #expect(result.body["code"] as? String == "feedback_diagnostics_invalid")
            }
            #expect(fake.requests().count == before, "invalid diagnostics never reach Hands")
        }
    }
}

@Test func handsPresignedCodesAndOrdinaryFailuresMapToTypedResponses() async throws {
    for (code, expected) in [
        ("presigned_invalid", ("feedback_diagnostics_rejected", 400)),
        ("presigned_not_found", ("feedback_diagnostics_rejected", 400)),
        ("presigned_size_mismatch", ("feedback_diagnostics_rejected", 400)),
        ("attachments_limit_exceeded", ("feedback_invalid", 400)),
    ] {
        let fake = try FakeHands(status: 400, responseBody: "{\"error\":\"x\",\"code\":\"\(code)\"}")
        defer { fake.stop() }
        let fixture = FeedbackFixture()
        fixture.accounts.setHandsFeedbackForTesting(baseURL: "http://127.0.0.1:\(fake.port)", appId: "11111111-1111-4111-8111-111111111111", appToken: "app_token")
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
            try await app.testing { client in
                let result = try await submit(client, fixture, kind: "android", diagnostics: diagnosticsJSON())
                #expect(Int(result.status.code) == expected.1, Comment(rawValue: code))
                #expect(result.body["code"] as? String == expected.0, Comment(rawValue: code))
            }
        }
    }

    let conflict = try FakeHands(status: 409, responseBody: "{\"error\":\"submission_id already used\"}")
    defer { conflict.stop() }
    let fixture = FeedbackFixture()
    fixture.accounts.setHandsFeedbackForTesting(baseURL: "http://127.0.0.1:\(conflict.port)", appId: "11111111-1111-4111-8111-111111111111", appToken: "app_token")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let result = try await submit(client, fixture, kind: "android", diagnostics: diagnosticsJSON())
            #expect(result.status == .conflict)
            #expect(result.body["code"] as? String == "feedback_submission_conflict")
        }
    }
}

@Test func presignedCodeWithoutDiagnosticsOrWithNon400StaysOrdinary() async throws {
    let withoutDiagnostics = try FakeHands(status: 400, responseBody: "{\"error\":\"x\",\"code\":\"presigned_invalid\"}")
    defer { withoutDiagnostics.stop() }
    let fixture = FeedbackFixture()
    fixture.accounts.setHandsFeedbackForTesting(baseURL: "http://127.0.0.1:\(withoutDiagnostics.port)", appId: "11111111-1111-4111-8111-111111111111", appToken: "app_token")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let result = try await submit(client, fixture, kind: "android", diagnostics: nil)
            #expect(result.status == .badRequest)
            #expect(result.body["code"] as? String == "feedback_invalid")
        }
    }

    let non400 = try FakeHands(status: 422, responseBody: "{\"error\":\"x\",\"code\":\"presigned_invalid\"}")
    defer { non400.stop() }
    let fixture2 = FeedbackFixture()
    fixture2.accounts.setHandsFeedbackForTesting(baseURL: "http://127.0.0.1:\(non400.port)", appId: "11111111-1111-4111-8111-111111111111", appToken: "app_token")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture2.accounts))
        try await app.testing { client in
            let result = try await submit(client, fixture2, kind: "android", diagnostics: diagnosticsJSON())
            #expect(result.status == .serviceUnavailable)
            #expect(result.body["code"] as? String == "feedback_service_unavailable")
        }
    }
}
