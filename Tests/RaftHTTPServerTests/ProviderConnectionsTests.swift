import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// Full HTTP wiring with an explicit external key for this scenario's real provider service.
func configureProviderConnectionsTestApp(
    _ app: Application, accounts: EmailLoginDirectory, credentialMasterKey: Data
) throws {
    let providers = try accounts.managedMCPProviderConnections.bindingCredentialMasterKey(credentialMasterKey)
    configure(app, services: FallbackServices(
        nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
    ))
    IntegrationsFeature(
        controlPlane: accounts.managedMCPControlPlane,
        identities: accounts.authIdentities,
        apps: accounts.integrationsAndAppAccess,
        appManagement: accounts.integrationAppManagement,
        cardPrepare: accounts.actionCardPrepare,
        agentsLifecycle: accounts.agentsLifecycle,
        providerConnections: providers,
        actionCards: accounts.actionCards
    ).register(routes: app)
}

@Test func providerConnectionsAreGatedAndNeverEchoCredentials() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111244"
    let memberId = "11111111-1111-4111-8111-111111111245"
    let serverId = "33333333-3333-4333-8333-333333333440"
    accounts.addAccount(id: ownerId, email: "provider-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "provider-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "provider-api", name: "Provider API", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

    try await withApp { app in
        try configureProviderConnectionsTestApp(
            app, accounts: accounts, credentialMasterKey: Data((0..<32).map { UInt8($0) })
        )
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            let ownerToken = try await login("provider-owner@slock.test")
            let memberToken = try await login("provider-member@slock.test")

            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }

            let gatedRead = try await client.send(.get, headers: headers(ownerToken), to: "/api/provider-connections")
            #expect(gatedRead.status == .notFound)
            #expect((try JSONSerialization.jsonObject(with: Data((gatedRead.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "provider_connections_disabled")

            let gatedWrite = try await client.send(.post, headers: headers(ownerToken), to: "/api/provider-connections") { request in
                request.body = .init(string: "{\"name\":\"Hidden\",\"providerId\":\"deepseek\",\"apiKey\":\"disabled-secret\"}")
            }
            #expect(gatedWrite.status == .notFound)
            #expect((gatedWrite.body.string ?? "").contains("disabled-secret") == false)

            accounts.setProviderConnectionsEnabled(serverId: serverId, enabled: true)

            let forbiddenRead = try await client.send(.get, headers: headers(memberToken), to: "/api/provider-connections")
            #expect(forbiddenRead.status == .forbidden)
            let forbiddenWrite = try await client.send(.post, headers: headers(memberToken), to: "/api/provider-connections") { request in
                request.body = .init(string: "{\"name\":\"Nope\",\"providerId\":\"deepseek\",\"apiKey\":\"member-secret\"}")
            }
            #expect(forbiddenWrite.status == .forbidden)
            #expect((forbiddenWrite.body.string ?? "").contains("member-secret") == false)

            let alias = try await client.send(.post, headers: headers(ownerToken), to: "/api/provider-connections") { request in
                request.body = .init(string: "{\"name\":\"Alias\",\"providerId\":\"deepseek\",\"apiKey\":\"write-only-secret\",\"clientSecret\":\"unexpected-alias\"}")
            }
            #expect(alias.status == .badRequest)
            #expect((alias.body.string ?? "").contains("write-only-secret") == false)
            #expect((alias.body.string ?? "").contains("unexpected-alias") == false)

            let createdResponse = try await client.send(.post, headers: headers(ownerToken), to: "/api/provider-connections") { request in
                request.body = .init(string: "{\"name\":\"Team DeepSeek\",\"providerId\":\"deepseek\",\"apiKey\":\"api-private-value\"}")
            }
            #expect(createdResponse.status == .created)
            #expect((createdResponse.body.string ?? "").contains("api-private-value") == false)
            let created = try JSONSerialization.jsonObject(with: Data((createdResponse.body.string ?? "").utf8)) as? [String: Any]
            #expect(created?["status"] as? String == "unchecked")
            #expect(created?["hasCredential"] as? Bool == true)
            let createdId = created?["id"] as? String ?? ""

            let listResponse = try await client.send(.get, headers: headers(ownerToken), to: "/api/provider-connections")
            #expect(listResponse.status == .ok)
            #expect((listResponse.body.string ?? "").contains("api-private-value") == false)
            #expect((listResponse.body.string ?? "").contains("encryptedApiKey") == false)
            let list = try JSONSerialization.jsonObject(with: Data((listResponse.body.string ?? "").utf8)) as? [String: Any]
            let connections = list?["connections"] as? [[String: Any]] ?? []
            #expect(connections.map { $0["id"] as? String } == [createdId])
            let options = list?["providerOptions"] as? [[String: Any]] ?? []
            #expect(options.map { $0["id"] as? String } == ManagedMCPProviderConnectionsService.providerConnectionProviderIds)
            #expect(options.first { $0["id"] as? String == "google" }?["providerKind"] as? String == "preset")
            #expect(options.first { $0["id"] as? String == "openai-compatible" }?["providerKind"] as? String == "gateway")
            #expect(options.allSatisfy { (($0["label"] as? String) ?? "").isEmpty == false })

            let implicitPatch = try await client.send(.patch, headers: headers(ownerToken), to: "/api/provider-connections/\(createdId)") { request in
                request.body = .init(string: "{\"apiKey\":\"must-not-enter-metadata\",\"providerId\":\"openai-compatible\"}")
            }
            #expect(implicitPatch.status == .badRequest)
            #expect((implicitPatch.body.string ?? "").contains("must-not-enter-metadata") == false)

            let rotatedResponse = try await client.send(.post, headers: headers(ownerToken), to: "/api/provider-connections/\(createdId)/credentials/rotate") { request in
                request.body = .init(string: "{\"apiKey\":\"rotated-private-value\"}")
            }
            #expect(rotatedResponse.status == .ok)
            #expect((rotatedResponse.body.string ?? "").contains("rotated-private-value") == false)
            let rotated = try JSONSerialization.jsonObject(with: Data((rotatedResponse.body.string ?? "").utf8)) as? [String: Any]
            #expect(rotated?["status"] as? String == "unchecked")
            #expect(rotated?["credentialVersion"] as? Int == 2)

            let unifiedPatch = try await client.send(.patch, headers: headers(ownerToken), to: "/api/provider-connections/\(createdId)") { request in
                request.body = .init(string: "{\"name\":\"Patched Team DeepSeek\",\"apiKey\":\"unified-patch-secret\"}")
            }
            #expect(unifiedPatch.status == .ok)
            #expect((unifiedPatch.body.string ?? "").contains("unified-patch-secret") == false)
            let patched = try JSONSerialization.jsonObject(with: Data((unifiedPatch.body.string ?? "").utf8)) as? [String: Any]
            #expect(patched?["name"] as? String == "Patched Team DeepSeek")
            #expect(patched?["credentialVersion"] as? Int == 3)
            #expect(patched?["status"] as? String == "unchecked")

            let otherServerId = "33333333-3333-4333-8333-333333333441"
            accounts.oauth.addOwnedServer(id: otherServerId, slug: "other-provider", name: "Other Provider", ownerId: ownerId)
            let agentId = accounts.oauth.createAgent(serverId: serverId, name: "assigned-provider-agent")
            accounts.assignAgentToProviderConnection(
                connectionId: createdId,
                serverId: serverId,
                agentId: agentId,
                computerName: "assigned-agent-machine"
            )

            let unassignedBefore = accounts.oauth.createAgent(serverId: serverId, name: "unassigned-agent")
            #expect(unassignedBefore.isEmpty == false)
            let plainList = try await client.send(.get, headers: headers(ownerToken), to: "/api/provider-connections/\(createdId)/agents")
            #expect(plainList.status == .ok)
            #expect((plainList.body.string ?? "").contains("assigned-secret-value") == false)
            let assigned = try JSONSerialization.jsonObject(with: Data((plainList.body.string ?? "").utf8)) as? [String: Any]
            let assignedRows = assigned?["agents"] as? [[String: Any]] ?? []
            #expect(assignedRows.map { $0["id"] as? String } == [agentId])
            #expect(assignedRows.first?["name"] as? String == "assigned-provider-agent")
            #expect(assignedRows.first?["runtime"] as? String == "builtin")
            #expect(assignedRows.first?["status"] as? String == "inactive")
            #expect(assignedRows.first?["computerName"] as? String == "assigned-agent-machine")
            #expect(assignedRows.first?["deleted"] as? Bool == false)

            let forbiddenAgents = try await client.send(.get, headers: headers(memberToken), to: "/api/provider-connections/\(createdId)/agents")
            #expect(forbiddenAgents.status == .forbidden)
            var otherHeaders = headers(ownerToken)
            otherHeaders[HTTPField.Name("X-Server-Id")!] = otherServerId
            let crossServerAgents = try await client.send(.get, headers: otherHeaders, to: "/api/provider-connections/\(createdId)/agents")
            #expect(crossServerAgents.status == .notFound)
            let unknownConnection = try await client.send(.get, headers: headers(ownerToken), to: "/api/provider-connections/\(UUID().uuidString.lowercased())/agents")
            #expect(unknownConnection.status == .notFound)

            let malformedAgent = try await client.send(.delete, headers: headers(ownerToken), to: "/api/provider-connections/\(createdId)/agents/not-a-uuid")
            #expect(malformedAgent.status == .badRequest)

            let activeDetach = try await client.send(.delete, headers: headers(ownerToken), to: "/api/provider-connections/\(createdId)/agents/\(agentId)")
            #expect(activeDetach.status == .conflict)
            #expect((try JSONSerialization.jsonObject(with: Data((activeDetach.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "provider_connection_assignment_active")

            let blockedDelete = try await client.send(.delete, headers: headers(ownerToken), to: "/api/provider-connections/\(createdId)")
            #expect(blockedDelete.status == .conflict)

            accounts.oauth.deleteAgent(id: agentId)
            let freedDelete = try await client.send(.delete, headers: headers(ownerToken), to: "/api/provider-connections/\(createdId)")
            #expect(freedDelete.status == .ok)

            let retiredTest = try await client.send(.post, headers: headers(ownerToken), to: "/api/provider-connections/\(createdId)/test") { request in
                request.body = .init(string: "{\"model\":\"deepseek/deepseek-v4-pro\",\"message\":\"hi\"}")
            }
            #expect(retiredTest.status == .gone)
            let retiredModels = try await client.send(.get, headers: headers(ownerToken), to: "/api/provider-connections/\(createdId)/models")
            #expect(retiredModels.status == .gone)
            #expect((retiredModels.body.string ?? "").contains("api-private-value") == false)
        }
    }
}
