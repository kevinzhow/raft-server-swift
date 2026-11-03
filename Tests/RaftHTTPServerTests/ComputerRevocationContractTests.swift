import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func deletingAMachineRevokesItsComputerKey() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001390901"
    let serverId = "33333333-3333-4333-8333-000001390901"
    accounts.addAccount(id: ownerId, email: "revocation-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "revocation-co", name: "Revocation Co", ownerId: ownerId)
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let attached = try await client.send(.post, headers: headers, to: "/api/computer/attach") { request in
                request.body = .init(string: #"{"serverSlug":"revocation-co","name":"audit-computer"}"#)
            }
            #expect(attached.status == .created)
            let body = (try? JSONSerialization.jsonObject(with: Data((attached.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let apiKey = try #require(body["apiKey"] as? String)
            let machineId = try #require(body["machineId"] as? String)

            var computerHeaders = HTTPFields()
            computerHeaders[.authorization] = "Bearer \(apiKey)"
            let before = try await client.get(URI(string: "/internal/computer/runners"), headers: computerHeaders)
            #expect(before.status == .ok)

            // Unauthenticated and unknown-machine deletes are refused before any revocation.
            let anonymous = try await client.send(.delete, to: "/api/servers/\(serverId)/machines/\(machineId)")
            #expect(anonymous.status == .unauthorized)
            let unknown = try await client.send(.delete, headers: headers, to: "/api/servers/\(serverId)/machines/\(UUID().uuidString)")
            #expect(unknown.status == .notFound)
            #expect(accounts.computerRecordForTesting(apiKey: apiKey)?.revokedAt == nil)

            let removed = try await client.send(.delete, headers: headers, to: "/api/servers/\(serverId)/machines/\(machineId)")
            #expect(removed.status == .ok)

            let after = try await client.get(URI(string: "/internal/computer/runners"), headers: computerHeaders)
            #expect(after.status == .unauthorized, "a deleted machine's Computer key can no longer act")
            let receipt = accounts.computerRecordForTesting(apiKey: apiKey)
            #expect(receipt?.revokedAt != nil)
            #expect(receipt?.machineId == nil)
        }
    }
}
