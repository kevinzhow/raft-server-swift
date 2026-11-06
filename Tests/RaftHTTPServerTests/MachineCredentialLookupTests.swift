import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func machineKeysUseTheUpstreamPrefixAndResolveByKey() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111622"
    let serverId = "33333333-3333-4333-8333-333333333666"
    accounts.addAccount(id: ownerId, email: "credential-lookup@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "credential-lookup", name: "Credential Lookup", ownerId: ownerId)

    let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "lookup-machine")
    let machineKey = accounts.machineAPIKey(machineId: machineId) ?? ""
    #expect(machineKey.hasPrefix("sk_machine_"))
    #expect(machineKey.count == "sk_machine_".count + 64)

    #expect(accounts.runtimeFormsAndProbes.machineCredential(apiKey: machineKey)?.machineId == machineId)
    #expect(accounts.runtimeFormsAndProbes.machineCredential(apiKey: machineKey)?.serverId == serverId)
    #expect(accounts.runtimeFormsAndProbes.machineCredential(apiKey: "sk_machine_unknown") == nil)
    #expect(accounts.runtimeFormsAndProbes.machineCredential(id: machineId)?.serverId == serverId)
    #expect(accounts.runtimeFormsAndProbes.machineCredential(id: "missing-machine") == nil)
    #expect(accounts.runtimeFormsAndProbes.serverExists(id: serverId))
    #expect(!accounts.runtimeFormsAndProbes.serverExists(id: "33333333-3333-4333-8333-333333333667"))
}

@Test func attachedComputerKeyUsesTheUpstreamPrefixAndResolvesToItsMachine() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111623"
    let serverId = "33333333-3333-4333-8333-333333333668"
    accounts.addAccount(id: ownerId, email: "computer-lookup@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "computer-lookup", name: "Computer Lookup", ownerId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"computer-lookup@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let attach = try await client.send(.post, headers: headers, to: "/api/computer/attach") { request in
                request.body = .init(string: "{\"serverSlug\":\"computer-lookup\",\"name\":\"lookup-computer\"}")
            }
            #expect(attach.status == .created)
            let body = try JSONSerialization.jsonObject(with: Data((attach.body.string ?? "").utf8)) as? [String: Any]
            let apiKey = body?["apiKey"] as? String ?? ""
            let machineId = body?["machineId"] as? String ?? ""
            #expect(apiKey.hasPrefix("sk_computer_"))
            #expect(apiKey.count == "sk_computer_".count + 64)

            guard case .linked(_, let resolvedMachineId) = accounts.computerCredential(apiKey: apiKey) else {
                Issue.record("attached computer key did not resolve")
                return
            }
            #expect(resolvedMachineId == machineId)
            #expect(accounts.computerCredential(apiKey: "sk_computer_unknown") == .notFound)
        }
    }
}
