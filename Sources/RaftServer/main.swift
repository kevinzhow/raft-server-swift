import Configuration
import Foundation
import Logging
import RaftConnectAuth
import RaftHTTP
import RaftHTTPServer
import RaftMachineSocket
import RaftRealtime
import Vapor

#if canImport(Glibc)
import Glibc
#endif

private struct DatabaseNotConnected: Error {}

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
    static func main() async throws {
        let config = ConfigReader(providers: [
            CommandLineArgumentsProvider(),
            EnvironmentVariablesProvider(),
        ])
        LoggingSystem.bootstrap { StreamLogHandler.standardOutput(label: $0) }
        let environment = try Environment.detect(from: config)
        let app = try Application(environment, configReader: config)
        let processEnvironment = ProcessInfo.processInfo.environment
        let nodeEnv = processEnvironment["NODE_ENV"] ?? "development"
        let emailAccounts = EmailLoginDirectory()
        emailAccounts.mobileOAuthReturnURI = processEnvironment["MOBILE_OAUTH_RETURN_URI"]
        emailAccounts.releaseBranch = processEnvironment["SLOCK_RELEASE_BRANCH"]
        emailAccounts.deviceLoginGate = processEnvironment["SLOCK_DEVICE_LOGIN_ENABLED"]
        emailAccounts.mobileOAuthAllowedReturnURIs = processEnvironment["MOBILE_OAUTH_ALLOWED_RETURN_URIS"]
        emailAccounts.configuredSocialAuthProviders = configuredSocialAuthProviders(processEnvironment)
        emailAccounts.appleClientId = nonEmpty(processEnvironment["APPLE_CLIENT_ID"]) ?? nonEmpty(processEnvironment["APPLE_WEB_CLIENT_ID"]) ?? ""
        emailAccounts.nativeAppleClientId = nonEmpty(processEnvironment["APPLE_IOS_CLIENT_ID"]) ?? ""
        emailAccounts.nativeAppleClientSecret = nonEmpty(processEnvironment["APPLE_IOS_CLIENT_SECRET"]) ?? ""
        emailAccounts.nativeAppleStateSecret = nonEmpty(processEnvironment["NATIVE_APPLE_AUTH_STATE_SECRET"])
            ?? nonEmpty(processEnvironment["SOCIAL_AUTH_STATE_SECRET"])
            ?? nonEmpty(processEnvironment["JWT_SECRET"])
            ?? ""
        emailAccounts.mobileAppEmailUnsubscribeSecret = nonEmpty(processEnvironment["MOBILE_APP_EMAIL_UNSUBSCRIBE_SECRET"])
            ?? nonEmpty(processEnvironment["JWT_SECRET"])
            ?? emailAccounts.mobileAppEmailUnsubscribeSecret
        if processEnvironment["SLOCK_NATIVE_NOTIFICATIONS_ENABLED"] != nil {
            emailAccounts.nativeNotificationsEnabled = processEnvironment["SLOCK_NATIVE_NOTIFICATIONS_ENABLED"] == "true"
        } else {
            emailAccounts.nativeNotificationsEnabled = nodeEnv == "test"
        }
        emailAccounts.nativeNotificationNodeEnv = nodeEnv
        if let attestationMode = processEnvironment["NATIVE_NOTIFICATION_ATTESTATION_MODE"] {
            emailAccounts.nativeNotificationAttestationMode = attestationMode
        }
        if let jwtSecret = nonEmpty(processEnvironment["JWT_SECRET"]) {
            emailAccounts.oauth.jwtSecret = jwtSecret
        }
        if let serverURL = nonEmpty(processEnvironment["SERVER_URL"]) {
            emailAccounts.serverURL = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        }
        if let appURL = nonEmpty(processEnvironment["APP_URL"]) {
            emailAccounts.appURL = appURL.hasSuffix("/") ? String(appURL.dropLast()) : appURL
        }
        let ping: @Sendable () async throws -> Void = { throw DatabaseNotConnected() }
        let tracker = DbLivenessTracker(ping: ping)
        let httpPort = Int(processEnvironment["PORT"] ?? "") ?? 8080
        if httpPort > 0 {
            app.serverConfiguration.port = httpPort
        }
        let configuredDaemonPort = Int(processEnvironment["DAEMON_CONNECT_PORT"] ?? "") ?? 8081
        let machineServer: MachineConnectServer?
        if configuredDaemonPort == 0 {
            machineServer = nil
        } else {
            machineServer = try await MachineConnectServer.start(
                lookup: LedgerMachineLookup(accounts: emailAccounts),
                port: configuredDaemonPort
            )
        }
        let configuredSocketPort = Int(processEnvironment["SOCKET_PORT"] ?? "") ?? 8082
        let realtimeServer: RealtimeServer?
        if configuredSocketPort == 0 {
            realtimeServer = nil
        } else {
            realtimeServer = try await RealtimeServer.start(
                auth: LedgerRealtimeAuth(accounts: emailAccounts),
                port: configuredSocketPort
            )
        }
        if let realtimeServer {
            emailAccounts.realtimeEmitter = { room, event, payload in
                realtimeServer.hub.emit(room: room, event: event, payloadJSON: payload)
            }
            emailAccounts.onAgentReadUpdated = { serverId, channelId, agentId, maxReadSeq in
                guard emailAccounts.readReceiptsEnabled(serverId: serverId),
                      let channel = emailAccounts.oauth.channelInfo(id: channelId),
                      channel.serverId == serverId,
                      channel.name != "all",
                      let type = emailAccounts.oauth.channelType(id: channelId),
                      ["channel", "private", "dm"].contains(type),
                      emailAccounts.oauth.channelAgentIds(channelId: channelId).contains(agentId)
                else { return }
                realtimeServer.hub.emitScopeReadUpdated(
                    serverId: serverId,
                    scopeId: channelId,
                    agentId: agentId,
                    maxReadSeq: maxReadSeq
                )
            }
        }
        configure(
            app,
            services: FallbackServices(
                nodeEnv: nodeEnv,
                tracker: tracker,
                pingDatabase: ping,
                releaseEnvironment: processEnvironment,
                emailAccounts: emailAccounts,
                realtime: realtimeServer?.hub
            )
        )
        if let machineServer {
            app.addLifecycleHandler(MachineConnectShutdown(server: machineServer))
        }
        if let realtimeServer {
            app.addLifecycleHandler(RealtimeShutdown(server: realtimeServer))
        }
        let boundHTTPPort = app.serverConfiguration.port ?? httpPort
        let daemonDescription = machineServer.map { "127.0.0.1:\($0.port)" } ?? "disabled"
        let realtimeDescription = realtimeServer.map { "127.0.0.1:\($0.port)" } ?? "disabled"
        FileHandle.standardOutput.write(
            Data("raft-server ready http=127.0.0.1:\(boundHTTPPort) daemon-connect=\(daemonDescription) realtime=\(realtimeDescription)\n".utf8)
        )
        await tracker.start()
        do {
            try await app.start()
        } catch {
            if let machineServer {
                try? await machineServer.close()
            }
            if let realtimeServer {
                try? await realtimeServer.close()
            }
            try? await app.shutdown()
            throw error
        }
    }
}
