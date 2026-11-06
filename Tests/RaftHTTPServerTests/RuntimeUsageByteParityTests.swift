import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Locks the published bytes of the migrated runtime-usage/attestation routes.
/// The service test locks the read models; these assertions prove the feature
/// projection keeps the same status, header set, `Content-Length` and member
/// order through `respond`.

@Test func serverUsageResponseIsByteExactAndStable() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111702"
    let serverId = "33333333-3333-4333-8333-333333333702"
    accounts.addAccount(id: ownerId, email: "runtime-usage-bytes@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "runtime-usage-bytes", name: "Usage Bytes", ownerId: ownerId)
    _ = accounts.oauth.createAgent(serverId: serverId, name: "agent-one")
    _ = accounts.oauth.createAgent(serverId: serverId, name: "agent-two")
    _ = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "bytes-machine")
    _ = accounts.oauth.createChannel(serverId: serverId, name: "public", creatorUserId: ownerId)
    _ = accounts.oauth.createChannel(serverId: serverId, name: "private", creatorUserId: ownerId, type: "private")
    _ = accounts.oauth.createChannel(serverId: serverId, name: "thread", creatorUserId: ownerId, type: "thread")
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    let expected = #"{"agents":2,"machines":1,"channels":2}"#

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func usage() async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                return try await client.get("/api/servers/\(serverId)/usage", headers: headers)
            }
            // Two calls: the legacy reply was one hand-built string, so key
            // order must not depend on a process hash seed.
            for _ in 0..<2 {
                let response = try await usage()
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/json; charset=utf-8")
                #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
                #expect(response.headers[.contentLength] == String(expected.utf8.count))
                #expect(response.body.string == expected)
            }
        }
    }
}

@Test func machineOfflineErrorKeepsTheArchiveMemberOrder() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111703"
    let serverId = "33333333-3333-4333-8333-333333333703"
    accounts.addAccount(id: ownerId, email: "runtime-usage-offline@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "runtime-usage-offline", name: "Offline", ownerId: ownerId)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "offline-machine")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "offline-agent")
    accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    // `error` before `code`: not the alphabetical order a sorted encoder gives.
    let expected = #"{"error":"Computer is offline","code":"machine_offline"}"#

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            let response = try await client.get(
                "/api/servers/\(serverId)/machines/\(machine)/agents/\(agent)/diagnostic/session-transcript",
                headers: headers
            )
            #expect(response.status == .conflict)
            #expect(response.headers[.contentType] == "application/json; charset=utf-8")
            #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(response.headers[.contentLength] == String(expected.utf8.count))
            #expect(response.body.string == expected)
        }
    }
}

@Test func diagnosticBodiesWithoutAContentTypeKeepTheLegacyParser() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111704"
    let serverId = "33333333-3333-4333-8333-333333333704"
    accounts.addAccount(id: ownerId, email: "runtime-usage-raw@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "runtime-usage-raw", name: "Raw Bodies", ownerId: ownerId)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "raw-machine")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "raw-agent")
    accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    let messageId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let reportId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func headers() -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                return fields
            }
            // No `Content-Type`: the archive parsed the raw body anyway, so the
            // typed path must fall back to it instead of answering 415/400.
            let accepted = try await client.send(
                .post,
                headers: headers(),
                to: "/api/servers/\(serverId)/machines/\(machine)/agents/\(agent)/diagnostic/mention-delivery/\(messageId)/redrive"
            ) { request in
                request.body = .init(string: #"{"expectedVersion":0}"#)
            }
            #expect(accepted.status == .notFound)
            #expect(accepted.body.string == #"{"status":"NOT_JOINABLE"}"#)

            let rejected = try await client.send(
                .post,
                headers: headers(),
                to: "/api/servers/\(serverId)/machines/\(machine)/agents/\(agent)/diagnostic/mention-delivery/\(messageId)/redrive"
            ) { request in
                request.body = .init(string: #"{"expectedVersion":-1}"#)
            }
            #expect(rejected.status == .badRequest)
            #expect(rejected.body.string == #"{"status":"INVALID_REQUEST"}"#)

            let feedback = try await client.send(
                .post,
                headers: headers(),
                to: "/api/servers/\(serverId)/machines/\(machine)/agents/\(agent)/feedback/\(reportId)/transcript"
            ) { request in
                request.body = .init(string: #"{"reportGeneratedAt":"2026-07-20T16:40:04.797Z"}"#)
            }
            #expect(feedback.status == .accepted)
            #expect(feedback.body.string == #"{"accepted":true,"feedbackReportId":"\#(reportId)","agentId":"\#(agent)"}"#)
        }
    }
}
