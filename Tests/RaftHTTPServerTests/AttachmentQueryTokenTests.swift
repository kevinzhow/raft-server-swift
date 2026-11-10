import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import RaftObjectStorage
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test(.timeLimit(.minutes(1))) func attachmentQueryTokenMintsAStreamingURLThatCarriesTheToken() async throws {
    try await withSingleURLStorage { storage in
        let setup = AttachmentPreviewAccounts(storage: storage.storage)
        let bytes = Data("query token attachment\n".utf8)
        try await withApp { app in
            configure(app, services: singleURLServices(setup.accounts))
            try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
                let id = try await singleURLUpload(client, authorization: setup.authorization, server: setup.serverId,
                    channel: setup.channelId, filename: "secret.txt", mime: "text/plain", bytes: bytes)
                var path = URLComponents()
                path.path = "/api/attachments/\(id)/url"
                let token = String(setup.authorization.dropFirst(7))
                path.queryItems = [.init(name: "serverId", value: setup.serverId), .init(name: "token", value: token)]
                let requestPath = try #require(path.string)
                let first = try await client.get(URI(string: requestPath))
                #expect(first.status == .ok)
                let wire = try await singleURLWire(first)
                let parsed = try #require(URLComponents(string: wire.url))
                #expect(parsed.queryItems?.first { $0.name == "token" }?.value == token)
                #expect(parsed.queryItems?.first { $0.name == "serverId" }?.value == setup.serverId)
                let fetched = try await client.get(URI(string: wire.url))
                #expect(fetched.status == .ok)
                let plaintext = try await attachmentPreviewBody(fetched)
                #expect(plaintext == bytes)
                #expect(fetched.headers[.contentType] == "text/plain; charset=utf-8")
                #expect(fetched.headers[.contentLength] == String(bytes.count))
                path.queryItems = [.init(name: "serverId", value: setup.serverId), .init(name: "token", value: "invalid")]
                let invalidPath = try #require(path.string)
                let refused = try await client.get(URI(string: invalidPath))
                #expect(refused.status == .unauthorized)
                _ = try await attachmentPreviewBody(refused)
            }
        }
    }
}

@Test(.timeLimit(.minutes(1))) func attachmentReadAcceptsComputerCredentialForItsLinkedServer() async throws {
    try await withSingleURLStorage { storage in
        let setup = AttachmentPreviewAccounts(storage: storage.storage)
        let otherServer = UUID().uuidString.lowercased()
        setup.accounts.oauth.addOwnedServer(id: otherServer, slug: "computer-other", name: "Other", ownerId: setup.userId)
        let otherChannel = setup.accounts.oauth.createChannel(serverId: otherServer, name: "other-room", creatorUserId: setup.userId)
        setup.accounts.addPostableChannel(serverId: otherServer, channelId: otherChannel, memberId: setup.userId, name: "other-room")
        let machine = setup.accounts.registerMachine(serverId: setup.serverId, userId: setup.userId, name: "computer-attach-machine")
        setup.accounts.linkComputerForTesting(serverId: setup.serverId, machineId: machine, online: true)
        let key = try #require(setup.accounts.computerAPIKeyForTesting(machineId: machine))
        let boundBytes = Data("computer authorized attachment\n".utf8)
        let otherBytes = Data("real other-server encrypted attachment\n".utf8)
        try await withApp { app in
            configure(app, services: singleURLServices(setup.accounts))
            try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
                let bound = try await singleURLUpload(client, authorization: setup.authorization, server: setup.serverId,
                    channel: setup.channelId, filename: "bound.txt", mime: "text/plain", bytes: boundBytes)
                let other = try await singleURLUpload(client, authorization: setup.authorization, server: otherServer,
                    channel: otherChannel, filename: "other.txt", mime: "text/plain", bytes: otherBytes)
                for headerServer in [nil, otherServer] as [String?] {
                    let headers = singleURLHeaders("Bearer \(key)", headerServer)
                    // Node derives server scope from the credential, ignoring the
                    // untrusted foreign header. The same bound bytes remain readable.
                    let boundRead = try await client.get(URI(string: "/api/attachments/\(bound)"), headers: headers)
                    #expect(boundRead.status == .ok)
                    let plaintext = try await attachmentPreviewBody(boundRead)
                    #expect(plaintext == boundBytes)
                    #expect(boundRead.headers[.contentType] == "text/plain; charset=utf-8")
                    #expect(boundRead.headers[.contentLength] == String(boundBytes.count))
                    // This object really exists in storage and belongs to the
                    // other server; an ignored header must never make it readable.
                    let forbidden = try await client.get(URI(string: "/api/attachments/\(other)"), headers: headers)
                    #expect(forbidden.status == .notFound)
                    let refused = try await attachmentPreviewBody(forbidden)
                    #expect(refused != otherBytes)
                    #expect(String(data: refused, encoding: .utf8) == #"{"error":"Attachment not found"}"#)
                }
            }
        }
    }
}
