import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

@Test func serverInviteRejectsAnInvalidEmailAndAcceptsAValidOne() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111344"
    let memberId = "11111111-1111-4111-8111-111111111345"
    let serverId = "33333333-3333-4333-8333-333333333503"
    accounts.addAccount(id: ownerId, email: "invite-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "invite-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "invite", name: "Invite", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("invite-owner@slock.test")
            let memberToken = try await login("invite-member@slock.test")

            let invalid = try await client.send(.post, headers: headers(ownerToken), to: "/api/servers/\(serverId)/invites") { request in
                request.body = .init(string: "{\"email\":\"not-an-email\"}")
            }
            #expect(invalid.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((invalid.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Enter a valid email address")

            let accepted = try await client.send(.post, headers: headers(ownerToken), to: "/api/servers/\(serverId)/invites") { request in
                request.body = .init(string: "{\"email\":\"invitee@slock.test\"}")
            }
            #expect(accepted.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((accepted.body.string ?? "").utf8)) as? [String: Any]
            let invite = body?["invite"] as? [String: Any]
            #expect((invite?["id"] as? String)?.isEmpty == false)
            #expect(invite?["email"] as? String == "invitee@slock.test")
            #expect(invite?["status"] as? String == "pending")

            let forbidden = try await client.send(.post, headers: headers(memberToken), to: "/api/servers/\(serverId)/invites") { request in
                request.body = .init(string: "{\"email\":\"another@slock.test\"}")
            }
            #expect(forbidden.status == .forbidden)

            // Reuse the existing member identity to exercise email acceptance;
            // no extra account/server fixture or synthetic membership query.
            let emailInvite = try await client.send(.post, headers: headers(ownerToken), to: "/api/servers/\(serverId)/invites") { request in
                request.body = .init(string: "{\"email\":\"invite-member@slock.test\"}")
            }
            #expect(emailInvite.status == .ok)
            let emailBody = try JSONSerialization.jsonObject(with: Data((emailInvite.body.string ?? "").utf8)) as? [String: Any]
            let emailRow = try #require(emailBody?["invite"] as? [String: Any])
            let inviteId = try #require(emailRow["id"] as? String)
            let inviteToken = "email-token-\(inviteId)"
            accounts.setServerInviteTokenForTesting(inviteId: inviteId, token: inviteToken)
            accounts.setServerSeats(serverId: serverId, seats: 2)
            let firstAgreement = accounts.oauth.putServerAgreement(serverId: serverId, title: "Invite Rules v1", bodyMarkdown: "Read first")

            func accept(_ userToken: String, agreementId: String? = nil) async throws -> ClientResponse {
                let agreementField = agreementId.map { ",\"agreementId\":\"\($0)\"" } ?? ""
                let payload = "{\"token\":\"\(inviteToken)\"\(agreementField)}"
                return try await client.send(.post, headers: headers(userToken), to: "/api/auth/accept-invite") { request in
                    request.body = .init(string: payload)
                }
            }

            let wrongEmail = try await accept(ownerToken)
            #expect(wrongEmail.status == .badRequest)
            #expect(wrongEmail.body.string == "{\"error\":\"Invalid invite\"}")
            let full = try await accept(memberToken)
            #expect(full.status == .badRequest)
            #expect(full.body.string == "{\"error\":\"Seat limit reached (2/2 on Pro plan)\"}")
            accounts.setServerSeats(serverId: serverId, seats: 3)
            let required = try await accept(memberToken)
            #expect(required.status == .conflict)
            let requiredBody = try JSONSerialization.jsonObject(with: Data((required.body.string ?? "").utf8)) as? [String: Any]
            #expect(requiredBody?["error"] as? String == "agreement_required")
            #expect((requiredBody?["agreement"] as? [String: Any])?["id"] as? String == firstAgreement.id)
            let currentAgreement = accounts.oauth.putServerAgreement(serverId: serverId, title: "Invite Rules v2", bodyMarkdown: "Read current")
            let changed = try await accept(memberToken, agreementId: firstAgreement.id)
            #expect(changed.status == .conflict)
            let changedBody = try JSONSerialization.jsonObject(with: Data((changed.body.string ?? "").utf8)) as? [String: Any]
            #expect(changedBody?["error"] as? String == "agreement_changed")
            #expect((changedBody?["agreement"] as? [String: Any])?["id"] as? String == currentAgreement.id)
            #expect(accounts.membershipAgreementAuditsForTesting(serverId: serverId, subjectId: memberId).isEmpty)

            let pending = try await client.send(.get, headers: headers(ownerToken), to: "/api/servers/\(serverId)/invites")
            #expect(pending.status == .ok)
            let pendingRows = try JSONSerialization.jsonObject(with: Data((pending.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(pendingRows.contains { $0["id"] as? String == inviteId }, "refusals leave the actual invite row pending")

            let joined = try await accept(memberToken, agreementId: currentAgreement.id)
            #expect(joined.status == .ok)
            #expect(joined.body.string == "{\"ok\":true,\"serverId\":\"\(serverId)\"}")
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: memberId) == "member")
            let audits = accounts.membershipAgreementAuditsForTesting(serverId: serverId, subjectId: memberId)
            #expect(audits.count == 1)
            #expect(audits.first?.agreementId == currentAgreement.id)
            #expect(audits.first?.agreementVersion == 2)
            #expect(audits.first?.actorUserId == memberId)
            #expect(audits.first?.source == "invite")
            let remaining = try await client.send(.get, headers: headers(ownerToken), to: "/api/servers/\(serverId)/invites")
            #expect(remaining.status == .ok)
            let remainingRows = try JSONSerialization.jsonObject(with: Data((remaining.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(!remainingRows.contains { $0["id"] as? String == inviteId })
            let consumed = try await accept(memberToken, agreementId: currentAgreement.id)
            #expect(consumed.status == .badRequest)
            #expect(consumed.body.string == "{\"error\":\"Invalid invite\"}")
            #expect(accounts.membershipAgreementAuditsForTesting(serverId: serverId, subjectId: memberId).count == 1)
        }
    }
}
