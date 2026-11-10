import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

/// Published upload/download paths must preserve bytes and channel ACLs. A JSON
/// metadata response cannot satisfy a successful attachment download.
@Test func attachmentUploadDownloadsExactBinaryBytesAndRangesBehindChannelACL() async throws {
    let accounts = EmailLoginDirectory()
    let owner = UUID().uuidString.lowercased()
    let outsider = UUID().uuidString.lowercased()
    let server = UUID().uuidString.lowercased()
    accounts.addAccount(id: owner, email: "attachment-byte-owner@example.com", password: "password123")
    accounts.markEmailVerified(userId: owner)
    accounts.addAccount(id: outsider, email: "attachment-byte-outsider@example.com", password: "password123")
    accounts.markEmailVerified(userId: outsider)
    accounts.oauth.addOwnedServer(id: server, slug: "attachment-byte-proof", name: "Attachment bytes", ownerId: owner)
    accounts.oauth.addMember(serverId: server, userId: outsider, role: "member")
    let channel = accounts.oauth.createChannel(serverId: server, name: "private-byte-proof", creatorUserId: owner)
    accounts.addPostableChannel(serverId: server, channelId: channel, memberId: owner, name: "private-byte-proof")
    accounts.oauth.setChannelType(id: channel, type: "private")
    accounts.setChannelPostablePrivateForTesting(channelId: channel)
    let bytes = Data([0, 255, 254, 128, 13, 10, 1, 2, 3, 65, 66, 67])
    let boundary = "raft-attachment-byte-proof"
    var multipart = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"channelId\"\r\n\r\n\(channel)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"proof.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
    multipart.append(bytes)
    multipart.append(Data("\r\n--\(boundary)--\r\n".utf8))
    let uploadBody = multipart

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                #expect(response.status == .ok)
                let object = try JSONSerialization.jsonObject(with: response.body.data ?? Data()) as? [String: Any]
                return try #require(object?["accessToken"] as? String)
            }
            let token = try await login("attachment-byte-owner@example.com")
            let otherToken = try await login("attachment-byte-outsider@example.com")
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = server
            headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
            let uploaded = try await client.send(.post, headers: headers, to: "/api/attachments/upload") { request in
                request.body = .init(data: uploadBody)
            }
            #expect(uploaded.status == .ok)
            let object = try JSONSerialization.jsonObject(with: uploaded.body.data ?? Data()) as? [String: Any]
            let rows = try #require(object?["attachments"] as? [[String: Any]])
            let id = try #require(rows.first?["id"] as? String)
            #expect(rows.first?["filename"] as? String == "proof.bin")
            let path = URI(string: "/api/attachments/\(id)")
            let downloaded = try await client.send(.get, headers: headers, to: path)
            #expect(downloaded.status == .ok)
            #expect(downloaded.body.data == bytes)
            #expect(downloaded.headers[.contentType] == "application/octet-stream")
            #expect(downloaded.headers[.contentLength] == String(bytes.count))
            #expect(downloaded.headers[HTTPField.Name("X-Content-Type-Options")!] == "nosniff")
            #expect(downloaded.headers[HTTPField.Name("Content-Disposition")!]?.contains("proof.bin") == true)

            headers[HTTPField.Name("Range")!] = "bytes=1-4"
            let ranged = try await client.send(.get, headers: headers, to: path)
            #expect(ranged.status.code == 206)
            #expect(ranged.body.data == Data(bytes[1...4]))
            #expect(ranged.headers[HTTPField.Name("Content-Range")!] == "bytes 1-4/\(bytes.count)")
            headers[HTTPField.Name("Range")!] = "bytes=999-1000"
            let unsatisfiable = try await client.send(.get, headers: headers, to: path)
            #expect(unsatisfiable.status.code == 416)
            #expect(unsatisfiable.headers[HTTPField.Name("Content-Range")!] == "bytes */\(bytes.count)")
            headers[HTTPField.Name("Range")!] = nil
            headers[.authorization] = "Bearer \(otherToken)"
            let forbidden = try await client.send(.get, headers: headers, to: path)
            #expect(forbidden.status == .notFound)
            #expect(forbidden.body.data != bytes)
            let anonymous = try await client.send(.get, to: path)
            #expect(anonymous.status == .unauthorized)
            #expect(anonymous.body.data != bytes)
        }
    }
}
