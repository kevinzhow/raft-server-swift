import Foundation
import HTTPTypes
import Testing
import Vapor
import VaporTesting
@testable import RaftHTTP
@testable import RaftHTTPServer

private func admissionServices(nodeEnv: String = "test") -> FallbackServices {
    FallbackServices(nodeEnv: nodeEnv, tracker: DbLivenessTracker(ping: {}), pingDatabase: {})
}

private func admissionSend(
    _ client: any Client, _ method: HTTPRequest.Method, _ path: String,
    token: String? = nil, body: String? = nil, serverId: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    if let token { headers[.authorization] = "Bearer \(token)" }
    if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
    if body != nil { headers[.contentType] = "application/json" }
    return try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
}

private func admissionRegister(
    _ client: any Client, email: String
) async throws -> (token: String, userId: String) {
    let response = try await admissionSend(client, .post, "/api/auth/register", body:
        "{\"email\":\"\(email)\",\"password\":\"SyntheticPassword123!\",\"acceptTerms\":true,"
        + "\"termsVersion\":\"\(AuthLegalPolicy.termsVersion)\",\"privacyVersion\":\"\(AuthLegalPolicy.privacyVersion)\"}")
    #expect(response.status == .ok)
    let registrationBytes = try await attachmentPreviewBody(response)
    let body = try #require(JSONSerialization.jsonObject(with: registrationBytes) as? [String: Any])
    let user = try #require(body["user"] as? [String: Any])
    #expect(user["emailVerified"] as? Bool == false)
    return (try #require(body["accessToken"] as? String), try #require(user["id"] as? String))
}

@Test func humanAdmissionRejectsFreshRegistrationBeforeBodyScopeAndEffectsInEveryEnvironment() async throws {
    for environment in ["test", "production"] {
        let services = admissionServices(nodeEnv: environment)
        try await withApp { app in
            configure(app, services: services)
            try await app.testing { client in
                let anonymous = try await admissionSend(client, .post, "/api/servers", body: "{")
                #expect(anonymous.status == .unauthorized)
                #expect(anonymous.body.string == "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
                let invalid = try await admissionSend(client, .post, "/api/servers", token: "synthetic-invalid-token", body: "{")
                #expect(invalid.status == .unauthorized)
                #expect(invalid.body.string == "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
                let registered = try await admissionRegister(client, email: "admission-\(environment)@example.com")
                let getDenied = try await admissionSend(client, .get, "/api/servers", token: registered.token)
                let headDenied = try await admissionSend(client, .head, "/api/servers", token: registered.token)
                #expect(getDenied.status == .forbidden)
                #expect(headDenied.status == .forbidden)
                #expect((headDenied.body.string ?? "").isEmpty)
                #expect(headDenied.headers[.contentLength] == getDenied.headers[.contentLength])
                for body in ["{\"name\":\"Denied Server\",\"slug\":\"admission-denied\"}", "{"] {
                    let denied = try await admissionSend(client, .post, "/api/servers", token: registered.token, body: body)
                    #expect(denied.status == .forbidden)
                    #expect(denied.body.string == "{\"error\":\"Email verification required\"}")
                    #expect(services.emailAccounts.oauth.serverIdForSlug("admission-denied") == nil)
                }
                // No X-Server-Id: account admission must still be the first refusal.
                let message = try await admissionSend(client, .post, "/api/messages", token: registered.token, body: "{")
                #expect(message.status == .forbidden)
                #expect(message.body.string == "{\"error\":\"Email verification required\"}")

                let me = try await admissionSend(client, .get, "/api/auth/me", token: registered.token)
                #expect(me.status == .ok)
                let complete = try await admissionSend(client, .post, "/api/auth/me/complete-profile", token: registered.token,
                    body: "{\"name\":\"admission-\(environment)\",\"displayName\":\"Admission User\"}")
                #expect(complete.status == .ok)
                let stillUnverified = try await admissionSend(client, .post, "/api/servers", token: registered.token,
                    body: "{\"name\":\"Still Denied\",\"slug\":\"still-denied\"}")
                #expect(stillUnverified.status == .forbidden)
                #expect(stillUnverified.body.string == "{\"error\":\"Email verification required\"}")
                #expect(services.emailAccounts.oauth.serverIdForSlug("still-denied") == nil)
            }
        }
    }
}

@Test func humanAdmissionRequiresProfileBeforeHeaderAndAllowsPublicProfileCompletion() async throws {
    let services = admissionServices()
    try await withApp { app in
        configure(app, services: services)
        try await app.testing { client in
            let registered = try await admissionRegister(client, email: "admission-profile@example.com")
            services.emailAccounts.authProfileStore.markEmailVerified(userId: registered.userId)
            for path in ["/api/servers", "/api/messages", "/api/agents/manageable"] {
                let denied = try await admissionSend(client, path.hasSuffix("manageable") ? .get : .post, path,
                    token: registered.token, body: path.hasSuffix("manageable") ? nil : "{")
                #expect(denied.status == .forbidden)
                #expect(denied.body.string == "{\"error\":\"Profile setup required\",\"code\":\"PROFILE_SETUP_REQUIRED\"}")
            }
            #expect(services.emailAccounts.oauth.serverIdForSlug("admission-allowed") == nil)
            let completed = try await admissionSend(client, .post, "/api/auth/me/complete-profile", token: registered.token,
                body: "{\"name\":\"admission-profile\",\"displayName\":\"Admission Profile\"}")
            #expect(completed.status == .ok)
            let created = try await admissionSend(client, .post, "/api/servers", token: registered.token,
                body: "{\"name\":\"Allowed Server\",\"slug\":\"admission-allowed\"}")
            #expect(created.status == .ok)
            #expect(services.emailAccounts.oauth.serverIdForSlug("admission-allowed") != nil)
        }
    }
}

@Test func humanAdmissionRejectsMissingCurrentAccountWithOrderedAuthError() async throws {
    let services = admissionServices()
    try await withApp { app in
        configure(app, services: services)
        try await app.testing { client in
            let registered = try await admissionRegister(client, email: "admission-missing@example.com")
            // Preserve the live token mapping while removing its account row.
            services.emailAccounts.authProfileStore.state.withLock { state in
                _ = state.accountSurface.accounts.removeValue(forKey: "admission-missing@example.com")
            }
            let denied = try await admissionSend(client, .post, "/api/servers", token: registered.token, body: "{")
            #expect(denied.status == .unauthorized)
            #expect(denied.body.string == "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
    }
}

@Test func humanAdmissionPreservesAuthOnlyComputerAndProfileOnlyInviteRoutes() async throws {
    let services = admissionServices()
    try await withApp { app in
        configure(app, services: services)
        try await app.testing { client in
            let registered = try await admissionRegister(client, email: "admission-recovery@example.com")
            let pendingInvite = try await admissionSend(client, .post, "/api/auth/accept-invite", token: registered.token, body: "{}")
            #expect(pendingInvite.status == .forbidden)
            #expect(pendingInvite.body.string == "{\"error\":\"Profile setup required\",\"code\":\"PROFILE_SETUP_REQUIRED\"}")

            let serverId = UUID().uuidString.lowercased()
            services.emailAccounts.oauth.addOwnedServer(id: serverId, slug: "admission-computer", name: "Admission Computer", ownerId: registered.userId)
            let attached = try await admissionSend(client, .post, "/api/computer/attach", token: registered.token,
                body: "{\"serverSlug\":\"admission-computer\",\"name\":\"admission-computer\"}")
            #expect(attached.status == .created)
            let attachedBody = try #require(JSONSerialization.jsonObject(with: Data((attached.body.string ?? "").utf8)) as? [String: Any])
            #expect((attachedBody["apiKey"] as? String)?.hasPrefix("sk_computer_") == true)

            let complete = try await admissionSend(client, .post, "/api/auth/me/complete-profile", token: registered.token,
                body: "{\"name\":\"admission-recovery\",\"displayName\":\"Admission Recovery\"}")
            #expect(complete.status == .ok)
            let invite = try await admissionSend(client, .post, "/api/auth/accept-invite", token: registered.token, body: "{}")
            #expect(invite.status == .badRequest)
            #expect(invite.body.string != "{\"error\":\"Email verification required\"}")
        }
    }
}

@Test func humanAdmissionPreservesFlexScopeBeforeLegacyHumanAdmission() async throws {
    let services = admissionServices()
    try await withApp { app in
        configure(app, services: services)
        try await app.testing { client in
            // Valid JSON isolates mount order. Malformed JSON belongs to the
            // earlier express.json phase and is an explicitly separate gap.
            let flexBody = #"{"error":"Authentication required"}"#
            for token in [nil, "synthetic-invalid-token"] as [String?] {
                let denied = try await admissionSend(client, .post, "/api/attachments/upload", token: token, body: "{}")
                #expect(denied.status == .unauthorized)
                #expect(denied.body.string == flexBody)
                #expect(denied.headers[.contentLength] == "35")
                #expect(denied.headers[.cacheControl] == "private, no-store")
            }
            let registered = try await admissionRegister(client, email: "admission-attachment@example.com")
            let serverId = UUID().uuidString.lowercased()
            services.emailAccounts.oauth.addOwnedServer(id: serverId, slug: "admission-attachment", name: "Admission Attachment", ownerId: registered.userId)
            let missing = try await admissionSend(client, .post, "/api/attachments/upload", token: registered.token, body: "{}")
            #expect(missing.status == .badRequest)
            #expect(missing.body.string == #"{"error":"Missing X-Server-Id"}"#)
            #expect(missing.headers[.contentLength] == String(#"{"error":"Missing X-Server-Id"}"#.utf8.count))
            #expect(missing.headers[.cacheControl] == "private, no-store")
            let deniedScope = try await admissionSend(client, .post, "/api/attachments/upload", token: registered.token, body: "{}", serverId: UUID().uuidString.lowercased())
            #expect(deniedScope.status == .forbidden)
            #expect(deniedScope.body.string == #"{"error":"Not a member of this server"}"#)
            #expect(deniedScope.headers[.cacheControl] == "private, no-store")
            let unverified = try await admissionSend(client, .post, "/api/attachments/upload", token: registered.token, body: "{}", serverId: serverId)
            #expect(unverified.status == .forbidden)
            #expect(unverified.body.string == #"{"error":"Email verification required"}"#)
            #expect(unverified.headers[.contentLength] == "39")
            #expect(unverified.headers[.cacheControl] == "private, no-store")
            let queryOnly = try await admissionSend(client, .post, "/api/attachments/upload?token=\(registered.token)&serverId=\(serverId)", body: "{}")
            #expect(queryOnly.status == .unauthorized)
            #expect(queryOnly.body.string == #"{"error":"Missing or invalid Authorization header","code":"auth_required"}"#)
            #expect(queryOnly.headers[.contentLength] == "74")
            #expect(queryOnly.headers[.cacheControl] == "private, no-store")
            let narrow = try await admissionSend(client, .get, "/api/attachments/upload-capabilities", token: registered.token)
            #expect(narrow.status == .forbidden)
            #expect(narrow.body.string == #"{"error":"Email verification required"}"#)
            services.emailAccounts.authProfileStore.markEmailVerified(userId: registered.userId)
            let missingScope = try await admissionSend(client, .post, "/api/attachments/upload", token: registered.token, body: "{}")
            #expect(missingScope.status == .badRequest)
            #expect(missingScope.body.string == #"{"error":"Missing X-Server-Id"}"#)
            let profileBody = #"{"error":"Profile setup required","code":"PROFILE_SETUP_REQUIRED"}"#
            let pending = try await admissionSend(client, .post, "/api/attachments/upload", token: registered.token, body: "{}", serverId: serverId)
            #expect(pending.status == .forbidden)
            #expect(pending.body.string == profileBody)
            #expect(pending.headers[.contentLength] == String(profileBody.utf8.count))
            #expect(pending.headers[.cacheControl] == "private, no-store")
            let narrowProfile = try await admissionSend(client, .get, "/api/attachments/upload-capabilities", token: registered.token)
            #expect(narrowProfile.status == .forbidden)
            #expect(narrowProfile.body.string == profileBody)
            // Header JWT + query scope reaches the later full profile first.
            let queryScopePending = try await admissionSend(client, .post, "/api/attachments/upload?serverId=\(serverId)", token: registered.token, body: "{}")
            #expect(queryScopePending.status == .forbidden)
            #expect(queryScopePending.body.string == profileBody)
            let completed = try await admissionSend(client, .post, "/api/auth/me/complete-profile", token: registered.token,
                body: "{\"name\":\"admission-attachment\",\"displayName\":\"Admission Attachment\"}")
            #expect(completed.status == .ok)
            let headerOnlyScope = try await admissionSend(client, .post, "/api/attachments/upload?serverId=\(serverId)", token: registered.token, body: "{}")
            #expect(headerOnlyScope.status == .badRequest)
            #expect(headerOnlyScope.body.string == #"{"error":"Missing X-Server-Id header"}"#)
            #expect(headerOnlyScope.headers[.cacheControl] == "private, no-store")
        }
    }
}

@Test func humanAdmissionMainMountsAndRouteLocalGatesRejectBeforeBodyEffects() async throws {
    let services = admissionServices()
    services.emailAccounts.nativeNotifications.configureDeployment(.init(enabled: true, nodeEnv: "test"))
    try await withApp { app in
        configure(app, services: services)
        try await app.testing { client in
            let registered = try await admissionRegister(client, email: "admission-mounts@example.com")
            let routes: [(HTTPRequest.Method, String)] = [
                (.get, "/api/servers"), (.get, "/api/feature-flags"), (.get, "/api/channels/inbox"),
                (.post, "/api/read-mutations"), (.post, "/api/v2/messages"),
                (.get, "/api/agents/manageable"), (.post, "/api/agents/synthetic/credentials"),
                (.get, "/api/raftbench"), (.get, "/api/billing"), (.post, "/api/tasks"),
                (.post, "/api/reminders"), (.post, "/api/share-artifacts"), (.post, "/api/integration-invites"),
                (.get, "/api/integrations"), (.post, "/api/actions"), (.post, "/api/product-events/batch"),
                (.get, "/api/mcp"), (.get, "/api/provider-connections"), (.get, "/api/agent-runtime-providers"),
                (.post, "/api/product-feedback"), (.post, "/api/message-translations:batch"),
                (.post, "/api/public/servers/example/join-as-guest"), (.post, "/api/slack-bridge/oauth/start"),
                (.post, "/api/notifications/enrollment-grants"), (.get, "/api/notifications/devices"),
                (.post, "/api/push/subscribe"), (.get, "/api/push/delivery-status"),
                (.get, "/api/announcements/active"), (.post, "/api/announcements/synthetic/dismiss"),
            ]
            for (method, path) in routes {
                let denied = try await admissionSend(client, method, path, token: registered.token, body: method == .post ? "{" : nil)
                #expect(denied.status == .forbidden)
                #expect(denied.body.string == "{\"error\":\"Email verification required\"}")
            }
            services.emailAccounts.nativeNotifications.configureDeployment(.init(enabled: false, nodeEnv: "test"))
            let disabled = try await admissionSend(client, .get, "/api/notifications/devices", token: registered.token)
            #expect(disabled.status == .notFound)
        }
    }
}

@Test(.timeLimit(.minutes(1))) func singleURLServingDoesNotPromoteLaterEmailOrProfileAdmission() async throws {
    try await withSingleURLStorage { storage in
        let setup = AttachmentPreviewAccounts(storage: storage.storage)
        let bytes = Data("published early attachment read\n".utf8)
        try await withApp { app in
            configure(app, services: singleURLServices(setup.accounts))
            try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
                let id = try await singleURLUpload(client, authorization: setup.authorization, server: setup.serverId,
                    channel: setup.channelId, filename: "early.txt", mime: "text/plain", bytes: bytes)
                // Public registration intentionally leaves this account unverified
                // and pending profile, unlike the independent upload owner.
                let registered = try await admissionRegister(client, email: "single-early-reader@example.com")
                setup.accounts.oauth.addMember(serverId: setup.serverId, userId: registered.userId, role: "member")
                let first = try await admissionSend(client, .get, "/api/attachments/\(id)/url?disposition=attachment",
                    token: registered.token, serverId: setup.serverId)
                #expect(first.status == .ok)
                let wire = try await singleURLWire(first)
                let fetched = try await client.get(URI(string: wire.url))
                #expect(fetched.status == .ok)
                let plaintext = try await attachmentPreviewBody(fetched)
                #expect(plaintext == bytes)
            }
        }
    }
}

@Test func routerMountBoundaryProtectsUnverifiedAndPendingMachineOwnersWithoutRPC() async throws {
    let services = admissionServices()
    try await withApp { app in
        configure(app, services: services)
        try await app.testing { client in
            let registered = try await admissionRegister(client, email: "mount-boundary-owner@example.com")
            let serverId = UUID().uuidString.lowercased()
            services.emailAccounts.oauth.addOwnedServer(id: serverId, slug: "mount-boundary", name: "Mount Boundary", ownerId: registered.userId)
            let attached = try await admissionSend(client, .post, "/api/computer/attach", token: registered.token,
                body: "{\"serverSlug\":\"mount-boundary\",\"name\":\"Unverified owner's Computer\"}")
            #expect(attached.status == .created)
            let attachedBody = try #require(JSONSerialization.jsonObject(with: Data((attached.body.string ?? "").utf8)) as? [String: Any])
            let machineId = try #require(attachedBody["machineId"] as? String)
            let tail = "/\(serverId)/machines/\(machineId)"
            let ordinary = "/api/servers" + tail
            let encodedId = "/api/servers/" + serverId.replacingOccurrences(of: "-", with: "%2D") + "/machines/\(machineId)"
            let acceptedMounts = [ordinary, encodedId]
            let rejectedMounts = ["/%61pi/servers", "/api/%73ervers", "/api//servers"]
            // These assertions harden Vapor's serving route boundary. They do
            // not claim Node accepts encoded or repeated-slash mount literals.
            for profilePending in [false, true] {
                if profilePending { services.emailAccounts.authProfileStore.markEmailVerified(userId: registered.userId) }
                let expected = profilePending
                    ? #"{"error":"Profile setup required","code":"PROFILE_SETUP_REQUIRED"}"#
                    : #"{"error":"Email verification required"}"#
                for base in acceptedMounts {
                    for leaf in ["/runtime-options", "/runtime-models/codex", "/runtime%2Dmodels/codex"] {
                        let denied = try await admissionSend(client, .get, base + leaf, token: registered.token, serverId: serverId)
                        #expect(denied.status == .forbidden)
                        #expect(denied.body.string == expected)
                        let head = try await admissionSend(client, .head, base + leaf, token: registered.token, serverId: serverId)
                        #expect(head.status == .forbidden)
                        #expect((head.body.string ?? "").isEmpty)
                        #expect(head.headers[.contentLength] == denied.headers[.contentLength])
                    }
                }
                for prefix in rejectedMounts {
                    let path = prefix + tail + "/runtime-models/codex"
                    let denied = try await admissionSend(client, .get, path, token: registered.token)
                    #expect(denied.status == .notFound)
                    let body = try #require(JSONSerialization.jsonObject(with: Data((denied.body.string ?? "").utf8)) as? [String: Any])
                    #expect(body["code"] as? String == "not_found")
                    #expect(body["path"] as? String == path)
                    let head = try await admissionSend(client, .head, path, token: registered.token)
                    #expect(head.status == .notFound)
                    #expect((head.body.string ?? "").isEmpty)
                    #expect(head.headers[.contentLength] == denied.headers[.contentLength])
                }
            }
            let complete = try await admissionSend(client, .post, "/api/auth/me/complete-profile", token: registered.token,
                body: "{\"name\":\"mount-boundary-owner\",\"displayName\":\"Mount Boundary\"}")
            #expect(complete.status == .ok)
            for base in acceptedMounts {
                let options = try await admissionSend(client, .get, base + "/runtime-options", token: registered.token, serverId: serverId)
                #expect(options.status == .ok)
                for leaf in ["/runtime-models/codex", "/runtime%2Dmodels/codex"] {
                    let unbound = try await admissionSend(client, .get, base + leaf, token: registered.token, serverId: serverId)
                    #expect(unbound.status == .ok)
                    #expect(unbound.body.string == #"{"kind":"error","retryable":true,"code":"computer_offline"}"#)
                    #expect(unbound.headers[.cacheControl] == "private, no-store")
                }
            }
            for prefix in rejectedMounts {
                let denied = try await admissionSend(client, .get, prefix + tail + "/runtime-models/codex", token: registered.token)
                #expect(denied.status == .notFound)
                // Keep the Node raw API mount cache oracle separate from the
                // serving-route guard. Encoded first literals never gain it.
                #expect(denied.headers[.cacheControl] == (prefix.hasPrefix("/api/") ? "private, no-store" : nil))
            }
            for prefix in ["/api%2Fservers", "/%2561pi/servers", "/api/%2573ervers"] {
                let denied = try await admissionSend(client, .get, prefix + tail + "/runtime-models/codex", token: registered.token)
                #expect(denied.status == .notFound)
            }
            var preflightHeaders = HTTPFields()
            preflightHeaders[HTTPField.Name("Origin")!] = "http://localhost:5173"
            preflightHeaders[HTTPField.Name("Access-Control-Request-Method")!] = "GET"
            let preflight = try await client.send(.options, headers: preflightHeaders,
                to: URI(string: "/api/%73ervers" + tail + "/runtime-models/codex"))
            #expect(preflight.status == .noContent)
        }
    }
}

@Test func routerMountBoundaryPreservesNarrowUploadAndLegacyFlexAdmissionOrder() async throws {
    let services = admissionServices()
    try await withApp { app in
        configure(app, services: services)
        try await app.testing { client in
            let registered = try await admissionRegister(client, email: "mount-boundary-flex@example.com")
            let narrow = try await admissionSend(client, .get, "/api/attachments/upload-capabilities", token: registered.token)
            #expect(narrow.status == .forbidden)
            #expect(narrow.body.string == #"{"error":"Email verification required"}"#)
            let encodedNarrow = try await admissionSend(client, .get, "/api/attachments/%75pload-capabilities", token: registered.token)
            #expect(encodedNarrow.status == .notFound)
            let flex = try await admissionSend(client, .post, "/api/attachments/upload", token: registered.token, body: "{}")
            #expect(flex.status == .badRequest)
            #expect(flex.body.string == #"{"error":"Missing X-Server-Id"}"#)
            let anonymous = try await admissionSend(client, .post, "/api/attachments/upload", body: "{}")
            #expect(anonymous.status == .unauthorized)
            #expect(anonymous.body.string == #"{"error":"Authentication required"}"#)
        }
    }
}

@Test(.timeLimit(.minutes(1))) func routerMountBoundaryPreservesSignedHTMLPreviewServing() async throws {
    try await withSingleURLStorage { storage in
        let setup = AttachmentPreviewAccounts(storage: storage.storage)
        let bytes = Data("<!doctype html><title>Boundary preview</title><p>signed document</p>".utf8)
        try await withApp { app in
            configure(app, services: singleURLServices(setup.accounts))
            try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
                let id = try await singleURLUpload(client, authorization: setup.authorization, server: setup.serverId,
                    channel: setup.channelId, filename: "boundary.html", mime: "text/html", bytes: bytes)
                let token = try await setup.previewToken(id)
                let preview = try await admissionSend(client, .get,
                    "/api/attachments/\(id)/html-preview?serverId=\(setup.serverId)&previewToken=\(token)")
                #expect(preview.status == .ok)
                let document = try await attachmentPreviewBody(preview)
                #expect(String(decoding: document, as: UTF8.self).contains("signed document"))
            }
        }
    }
}

@Test func humanAdmissionUsesMatchedLaterLiteralsAndActualUploadUUIDs() async throws {
    let services = admissionServices()
    try await withApp { app in
        configure(app, services: services)
        try await app.testing { client in
            let registered = try await admissionRegister(client, email: "matched-admission@example.com")
            let id = UUID().uuidString.lowercased()
            let encodedId = id.replacingOccurrences(of: "-", with: "%2D")
            let protected: [(HTTPRequest.Method, String)] = [
                (.post, "/api/announcements/\(id)/dismiss"),
                (.post, "/api/announcements/\(id)/%64ismiss"),
                (.post, "/api/announcements/\(encodedId)/%64ismiss"),
                (.post, "/api/public/servers/matched-admission/join-as-guest"),
                (.post, "/api/public/servers/matched-admission/%6Aoin-as-guest"),
                (.post, "/api/public/servers/one%2Fsegment/%6Aoin-as-guest"),
                (.get, "/api/attachments/upload-sessions/\(id)"),
                (.get, "/api/attachments/upload-sessions/\(encodedId)"),
            ]
            for pending in [false, true] {
                if pending { services.emailAccounts.authProfileStore.markEmailVerified(userId: registered.userId) }
                let expected = pending
                    ? #"{"error":"Profile setup required","code":"PROFILE_SETUP_REQUIRED"}"#
                    : #"{"error":"Email verification required"}"#
                for (method, path) in protected {
                    // Malformed POST JSON must not outrun account admission.
                    let denied = try await admissionSend(client, method, path, token: registered.token,
                        body: method == .post ? "{" : nil)
                    #expect(denied.status == .forbidden)
                    #expect(denied.body.string == expected)
                }
                for terminal in ["%2564ismiss", "dismiss%2Fextra"] {
                    let missing = try await admissionSend(client, .post,
                        "/api/announcements/\(id)/\(terminal)", token: registered.token, body: "{}")
                    #expect(missing.status == .notFound)
                }
            }
        }
    }
}

@Test func humanAdmissionDirectServerCreationUsesTheSameRefusal() async throws {
    let services = admissionServices()
    try await withApp { app in
        configure(app, services: services)
        try await app.testing { client in
            let registered = try await admissionRegister(client, email: "admission-direct@example.com")
            #expect(throws: HumanAdmissionError.emailVerificationRequired) {
                try services.emailAccounts.managedMCPLifecycle.createServer(authorization: "Bearer \(registered.token)", body: nil)
            }
            services.emailAccounts.authProfileStore.markEmailVerified(userId: registered.userId)
            #expect(throws: HumanAdmissionError.profileSetupRequired) {
                try services.emailAccounts.managedMCPLifecycle.createServer(authorization: "Bearer \(registered.token)", body: nil)
            }
        }
    }
}
