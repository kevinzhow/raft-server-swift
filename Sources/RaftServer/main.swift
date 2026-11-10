import Configuration
import Foundation
import Logging
import RaftConnectAuth
import RaftHTTP
import RaftHTTPServer
import RaftMachineSocket
import RaftObjectStorage
import RaftRealtime
import RaftShared
import Vapor

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private struct DatabaseNotConnected: Error {}

private func machineJSONString(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value])
    let array = String(decoding: data, as: UTF8.self)
    return String(array.dropFirst().dropLast())
}

private struct MachineConnectShutdown: LifecycleHandler {
    let server: MachineConnectServer

    func shutdown(_ application: Application) async {
        try? await server.close()
    }
}

private struct RealtimeShutdown: LifecycleHandler {
    let server: RealtimeServer

    func shutdown(_ application: Application) async {
        try? await server.close()
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
}

private func configuredSocialAuthProviders(_ environment: [String: String]) -> Set<String> {
    func present(_ key: String) -> Bool {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return false
        }
        return true
    }
    var configured: Set<String> = []
    if present("GOOGLE_CLIENT_ID"), present("GOOGLE_CLIENT_SECRET") { configured.insert("google") }
    if present("GITHUB_CLIENT_ID"), present("GITHUB_CLIENT_SECRET") { configured.insert("github") }
    let appleClient = present("APPLE_CLIENT_ID") || present("APPLE_WEB_CLIENT_ID")
    let appleSecret = present("APPLE_CLIENT_SECRET")
        || (present("APPLE_TEAM_ID") && present("APPLE_KEY_ID") && present("APPLE_PRIVATE_KEY"))
    if appleClient, appleSecret { configured.insert("apple") }
    return configured
}

@main
enum Entrypoint {
    static func main() async {
        do { try await run() }
        catch {
            let reason = (error as? ProductionStartupError)?.description ?? "Server startup failed; inspect configuration and dependency health"
            FileHandle.standardError.write(Data("raft-server: \(reason)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        do {
            if try await ProductionBootstrap.migrateIfRequested(
                arguments: CommandLine.arguments, environment: processEnvironment
            ) { return }
        } catch {
            // Migration errors can carry connection details. Emit no raw error.
            FileHandle.standardError.write(Data("raft-server schema migration failed; check DATABASE_URL and PostgreSQL availability\n".utf8))
            exit(1)
        }
        let nodeEnv = processEnvironment["NODE_ENV"] ?? "development"
        let production: ProductionConfiguration? = nodeEnv == "production" ? try ProductionConfiguration(environment: processEnvironment) : nil
        try HumanMessageCreateService.validateMessageParserRuntime()
        let config = ConfigReader(providers: [
            CommandLineArgumentsProvider(),
            EnvironmentVariablesProvider(),
        ])
        LoggingSystem.bootstrap { StreamLogHandler.standardOutput(label: $0) }
        let environment = try Environment.detect(from: config)
        let app = try Application(environment, configReader: config)
        let emailAccounts = EmailLoginDirectory()
        emailAccounts.oauthFlows.configureDeployment(.init(
            configuredSocialAuthProviders: configuredSocialAuthProviders(processEnvironment),
            appleClientId: nonEmpty(processEnvironment["APPLE_CLIENT_ID"]) ?? nonEmpty(processEnvironment["APPLE_WEB_CLIENT_ID"]) ?? "",
            nativeAppleClientId: nonEmpty(processEnvironment["APPLE_IOS_CLIENT_ID"]) ?? "",
            nativeAppleClientSecret: nonEmpty(processEnvironment["APPLE_IOS_CLIENT_SECRET"]) ?? "",
            nativeAppleStateSecret: nonEmpty(processEnvironment["NATIVE_APPLE_AUTH_STATE_SECRET"])
                ?? nonEmpty(processEnvironment["SOCIAL_AUTH_STATE_SECRET"])
                ?? nonEmpty(processEnvironment["JWT_SECRET"]) ?? "",
            socialAuthStateSecret: nonEmpty(processEnvironment["JWT_SECRET"]) ?? "",
            nativeAppleTrustedJWKS: nonEmpty(processEnvironment["APPLE_TRUSTED_JWKS"]),
            serverURL: production?.serverURL ?? nonEmpty(processEnvironment["SERVER_URL"]).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } ?? "http://localhost:3001",
            appURL: nonEmpty(processEnvironment["APP_URL"]).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } ?? "http://localhost:3000",
            mobileOAuthReturnURI: processEnvironment["MOBILE_OAUTH_RETURN_URI"],
            mobileOAuthAllowedReturnURIs: processEnvironment["MOBILE_OAUTH_ALLOWED_RETURN_URIS"]
        ))
        emailAccounts.authCore.configureDeployment(.init(
            releaseBranch: processEnvironment["SLOCK_RELEASE_BRANCH"],
            deviceLoginGate: processEnvironment["SLOCK_DEVICE_LOGIN_ENABLED"]
        ))
        let mobileEmail = MobileAppEmailUnsubscribe(notifications: emailAccounts.nativeNotifications)
        mobileEmail.configureDeployment(.init(
            secret: nonEmpty(processEnvironment["MOBILE_APP_EMAIL_UNSUBSCRIBE_SECRET"])
                ?? nonEmpty(processEnvironment["JWT_SECRET"])
                ?? mobileEmail.deploymentConfiguration.secret
        ))
        emailAccounts.nativeNotifications.configureDeployment(.init(
            enabled: processEnvironment["SLOCK_NATIVE_NOTIFICATIONS_ENABLED"].map { $0 == "true" } ?? (nodeEnv == "test"),
            attestationMode: processEnvironment["NATIVE_NOTIFICATION_ATTESTATION_MODE"],
            nodeEnv: nodeEnv
        ))
        if let jwtSecret = nonEmpty(processEnvironment["JWT_SECRET"]) {
            emailAccounts.oauthFlows.configureSigningSecret(jwtSecret)
        }
        // Restore the SAME directory that all production services and adapters use.
        // Deployment/signing configuration above exists before14codec restoration.
        let runtime: BusinessPersistenceRuntime?
        if let production {
            runtime = try await BusinessPersistenceRuntime.start(
                configuration: production.postgres, bindings: emailAccounts.makeDurableBindings(),
                // Admission is closed permanently; the process must not stay
                // alive as a 503-only zombie. systemd Restart=on-failure starts
                // a fresh process that claims a new writer epoch and reloads
                // every durable owner from PostgreSQL.
                fatalFailureHandler: { _ in exit(70) }
            )
        } else { runtime = nil }
        let database = DatabaseHealth(environment: processEnvironment)
        let ping: @Sendable () async throws -> Void = {
            if let production, let runtime {
                try await ProductionBootstrap.ping(runtime: runtime, redis: production.redis)
            } else {
                guard database.isConfigured else { throw DatabaseNotConnected() }
                try await database.ping()
            }
        }
        let tracker = DbLivenessTracker(ping: ping)
        let httpPort = Int(processEnvironment["PORT"] ?? "") ?? 8080
        if httpPort > 0 { app.serverConfiguration.port = httpPort }
        if let httpHost = nonEmpty(processEnvironment["HTTP_HOST"]) {
            app.serverConfiguration.hostname = httpHost
        }
        let realtimeHost = nonEmpty(processEnvironment["SOCKET_HOST"]) ?? (production == nil ? "127.0.0.1" : "0.0.0.0")
        let daemonHost = nonEmpty(processEnvironment["DAEMON_CONNECT_HOST"]) ?? (production == nil ? "127.0.0.1" : "0.0.0.0")
        let configuredSocketPort = Int(processEnvironment["SOCKET_PORT"] ?? "") ?? 8082
        let configuredDaemonPort = Int(processEnvironment["DAEMON_CONNECT_PORT"] ?? "") ?? 8081
        let hub: RealtimeHub? = configuredSocketPort == 0 ? nil : RealtimeHub()
        var realtimeServer: RealtimeServer?
        var machineServer: MachineConnectServer?
        var worker: ProductionEmailWorker?
        var publicationWorker: ProductionRealtimePublicationWorker?
        var executionConnection: ProductionAgentExecutionConnection?
        do {
            if let hub {
                emailAccounts.realtimeRelay.install { room, event, payload in
                    hub.emit(room: room, event: event, payloadJSON: payload)
                }
                emailAccounts.realtimeRelay.installRoomJoiner { userId, room in
                    hub.joinUserSessions(userId: userId, room: room)
                }
                emailAccounts.managedMCPToolExecution.installReadUpdateObserver { serverId, channelId, agentId, maxReadSeq in
                    guard emailAccounts.managedMCPToolExecution.shouldEmitStartupScopeRead(
                        serverId: serverId, channelId: channelId, agentId: agentId
                    ) else { return }
                    hub.emitScopeReadUpdated(
                        serverId: serverId, scopeId: channelId, agentId: agentId, maxReadSeq: maxReadSeq
                    )
                }
            }
            // configure installs the original lax observer AFTER the strict
            // startup observer, replacing the same slot on the restored owner.
            configure(
                app,
                services: FallbackServices(
                    nodeEnv: nodeEnv, tracker: tracker, pingDatabase: ping,
                    releaseEnvironment: processEnvironment,
                    publicSearchServiceBucket: production?.searchBucket,
                    emailAccounts: emailAccounts, persistence: runtime,
                    transactionalEmail: production.map { .durable(configuration: $0.email) },
                    realtime: hub, serverBaseURL: production?.serverURL
                )
            )
            let registry: MachineCommandRegistry?
            if let runtime {
                guard let production else { throw ProductionStartupError.unavailable }
                let storage = try S3AttachmentStorage(configuration: .fromEnvironment(processEnvironment))
                emailAccounts.configureAttachmentStorage(storage)
                app.addLifecycleHandler(AttachmentStorageLifecycle(storage: storage))
                try await runtime.activate()
                try await ProductionBootstrap.ping(runtime: runtime, redis: production.redis)
                let connection = try ProductionDaemonIntegration.connect(
                    execution: emailAccounts.agentExecution(persistence: runtime), runtime: runtime,
                    materializer: emailAccounts.agentExecutionMaterialization(
                        persistence: runtime, serverURL: production.serverURL
                    ),
                    // A computer coming back is the only real "Cindy woke up"
                    // moment the server sees; the same idempotent owner trigger
                    // runs there (upstream onboardingBriefingOnActivation.ts).
                    onboardingBriefing: emailAccounts.onboardingBriefing
                )
                executionConnection = connection
                registry = connection.registry
                try await runtime.execute {
                    emailAccounts.configureMachineQueries(ProductionMachineQueries(registry: connection.registry))
                }
            } else { registry = nil }
            if let hub {
                let auth = LedgerRealtimeAuth(authCore: emailAccounts.authCore, membership: emailAccounts.socketMembership)
                let admittedAuth: any RealtimeAuthorizing
                if let runtime { admittedAuth = ProductionRealtimeAuth(base: auth, runtime: runtime) }
                else { admittedAuth = auth }
                realtimeServer = try await RealtimeServer.start(
                    auth: admittedAuth, host: realtimeHost, port: configuredSocketPort, hub: hub
                )
            }
            if configuredDaemonPort != 0 {
                let lookup = LedgerMachineLookup(runtimeForms: emailAccounts.runtimeFormsAndProbes, fleet: emailAccounts.computersFleet)
                let admittedLookup: any MachineCredentialLooking
                if let runtime { admittedLookup = ProductionMachineLookup(base: lookup, runtime: runtime) }
                else { admittedLookup = lookup }
                let publishStatus: @Sendable (MatchedMachine, Bool) -> Void = { machine, online in
                    emailAccounts.setMachineOnline(machineId: machine.id, online: online)
                    let version = emailAccounts.bumpMachineStatusVersion(machineId: machine.id)
                    let status = online ? "online" : "offline"
                    let cause = online ? "" : ",\"cause\":\"socket_close\""
                    let payload = "{\"machineId\":\(machineJSONString(machine.id)),\"status\":\"\(status)\",\"statusVersion\":\(version)\(cause)}"
                    DeferredEffects.emit {
                        hub?.emit(room: "server:\(machine.serverId)", event: "machine:status", payloadJSON: payload)
                    }
                }
                if let runtime {
                    machineServer = try await MachineConnectServer.start(
                        lookup: admittedLookup, host: daemonHost, port: configuredDaemonPort,
                        onStatusCommitted: { machine, online in
                            try await runtime.execute { publishStatus(machine, online) }
                        },
                        commandRegistry: registry
                    )
                } else {
                    machineServer = try await MachineConnectServer.start(
                        lookup: admittedLookup, host: daemonHost, port: configuredDaemonPort,
                        onStatusChange: publishStatus
                    )
                }
            }
            if let runtime, let production {
                worker = ProductionEmailWorker(runtime: runtime, configuration: production.email)
                guard let hub else { throw ProductionStartupError.unavailable }
                publicationWorker = try ProductionRealtimePublicationWorker(runtime: runtime, hub: hub)
                app.addLifecycleHandler(ProductionShutdown(
                    runtime: runtime, worker: worker, publicationWorker: publicationWorker,
                    executionConnection: executionConnection,
                    machineServer: machineServer, realtimeServer: realtimeServer
                ))
            } else {
                if let machineServer { app.addLifecycleHandler(MachineConnectShutdown(server: machineServer)) }
                if let realtimeServer { app.addLifecycleHandler(RealtimeShutdown(server: realtimeServer)) }
            }
            let boundHTTPPort = app.serverConfiguration.port ?? httpPort
            let daemonDescription = machineServer.map { "\(daemonHost):\($0.port)" } ?? "disabled"
            let realtimeDescription = realtimeServer.map { "\(realtimeHost):\($0.port)" } ?? "disabled"
            FileHandle.standardOutput.write(Data(
                "raft-server ready http=127.0.0.1:\(boundHTTPPort) daemon-connect=\(daemonDescription) realtime=\(realtimeDescription)\n".utf8
            ))
            await tracker.start()
            try await app.start()
        } catch {
            await worker?.stop()
            await publicationWorker?.stop()
            await executionConnection?.worker.stop()
            try? await machineServer?.close()
            await executionConnection?.registry.close()
            await runtime?.close()
            try? await realtimeServer?.close()
            try? await app.shutdown()
            throw error
        }
    }
}
