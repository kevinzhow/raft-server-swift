import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func multipartUploadBody(
    channelId: String,
    files: [(name: String, filename: String, mimeType: String, bytes: Data)]
) -> (contentType: String, body: Data) {
    let boundary = "----raft-test-boundary"
    var data = Data()
    func append(_ string: String) { data.append(Data(string.utf8)) }
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"channelId\"\r\n\r\n")
    append("\(channelId)\r\n")
    for file in files {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n")
        append("Content-Type: \(file.mimeType)\r\n\r\n")
        data.append(file.bytes)
        append("\r\n")
    }
    append("--\(boundary)--\r\n")
    return ("multipart/form-data; boundary=\(boundary)", data)
}

private func attachmentUploadFixture(suffix: String) -> (EmailLoginDirectory, String, String, String) {
    let accounts = EmailLoginDirectory()
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 1_020_000 + (Int(suffix) ?? 0))
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 1_020_000 + (Int(suffix) ?? 0))
    let email = "upload-owner-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: email, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "upload-\(suffix)", name: "Upload", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "upload-room-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "upload-room-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    return (accounts, serverId, channel, email)
}

private func uploadLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

@Test func attachmentUploadRejectsEmptyOversizedAndAcceptsBatchAndPro() async throws {
    let (accounts, serverId, channel, email) = attachmentUploadFixture(suffix: "1601")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await uploadLogin(client, email: email)
            func upload(_ files: [(String, String, String, Data)]) async throws -> ClientResponse {
                let multipart = multipartUploadBody(
                    channelId: channel,
                    files: files.map { (name: "files", filename: $0.0, mimeType: $0.1, bytes: $0.3) }
                )
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                headers[.contentType] = multipart.contentType
                return try await client.send(.post, headers: headers, to: "/api/attachments/upload") { request in
                    request.body = .init(data: multipart.body)
                }
            }
            func body(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }

            let empty = try await upload([("empty.png", "image/png", "image/png", Data())])
            #expect(empty.status == .badRequest)
            #expect(body(empty) as NSDictionary == ["error": "Empty files are not allowed"] as NSDictionary)

            let oversizedData = Data(count: 50 * 1024 * 1024 + 1)
            let oversized = try await upload([("oversized.bin", "application/octet-stream", "application/octet-stream", oversizedData)])
            #expect(oversized.status.code == 413)
            #expect(body(oversized) as NSDictionary == [
                "error": "Max 50MB per file",
                "errorCode": "ATTACHMENT_TOO_LARGE",
                "maxBytes": 50 * 1024 * 1024,
            ] as NSDictionary)

            let batch = (0..<10).map { index in
                ("file-\(index).txt", "text/plain", "text/plain", Data("file-\(index)".utf8))
            }
            let batchResponse = try await upload(batch)
            #expect(batchResponse.status == .ok)
            let attachments = body(batchResponse)["attachments"] as? [[String: Any]] ?? []
            #expect(attachments.count == 10)
            #expect(attachments.map { $0["filename"] as? String } == (0..<10).map { "file-\($0).txt" })

            accounts.oauth.setServerPlan(id: serverId, plan: "pro")
            let proData = Data(count: 60 * 1024 * 1024)
            let pro = try await upload([("pro.bin", "application/octet-stream", "application/octet-stream", proData)])
            #expect(pro.status == .ok)
            #expect((body(pro)["attachments"] as? [[String: Any]] ?? []).count == 1)
        }
    }
}
