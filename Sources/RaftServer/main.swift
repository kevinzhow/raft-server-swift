import Configuration
import Foundation
import Logging
import RaftHTTP
import RaftHTTPServer
import Vapor

private struct DatabaseNotConnected: Error {}

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
        configure(
            app,
            services: FallbackServices(
                nodeEnv: nodeEnv,
                tracker: tracker,
                pingDatabase: ping,
                releaseEnvironment: processEnvironment,
                emailAccounts: emailAccounts
            )
        )
        await tracker.start()
        do {
            try await app.start()
        } catch {
            try? await app.shutdown()
            throw error
        }
    }
}
