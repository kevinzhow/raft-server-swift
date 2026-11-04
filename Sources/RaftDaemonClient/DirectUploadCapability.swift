import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Direct-upload capability flow: the daemon asks the server to sign a
/// machine-scope attestation, uses it to create an upload session on the
/// worker, then uploads bytes straight to the signed URL — the server never
/// carries the data plane. Failures keep their hop (attestation/create/put) and
/// HTTP status for typed classification. Ported from the upstream daemon helper.
public struct DaemonScopeAttestation: Sendable, Equatable {
    public var attestation: String
    public var scope: String
    public var audience: String
    public var resource: String?
    public var metadata: [String: String]?
    public var expiresAt: String
    public init(attestation: String, scope: String, audience: String, resource: String? = nil,
                metadata: [String: String]? = nil, expiresAt: String) {
        self.attestation = attestation
        self.scope = scope
        self.audience = audience
        self.resource = resource
        self.metadata = metadata
        self.expiresAt = expiresAt
    }
}

public struct DirectUploadCreateResponse: @unchecked Sendable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var raw: [String: Any]
}

public enum DirectUploadStage: String, Sendable {
    case attestation, create, put
}

public final class DirectUploadError: Error, @unchecked Sendable {
    public let message: String
    public let stage: DirectUploadStage
    public let httpStatus: Int?
    public let cause: Error?
    public init(_ message: String, stage: DirectUploadStage, httpStatus: Int? = nil, cause: Error? = nil) {
        self.message = message
        self.stage = stage
        self.httpStatus = httpStatus
        self.cause = cause
    }
}

public final class HttpStatusError: Error, @unchecked Sendable {
    public let toolName: String
    public let status: Int
    public let serverError: String?
    public init(toolName: String, status: Int, serverError: String? = nil) {
        self.toolName = toolName
        self.status = status
        self.serverError = serverError
    }
}

public struct DirectUploadFailureClass: Sendable, Equatable {
    public var stage: DirectUploadStage?
    public var httpStatus: Int?
    public var httpClass: String
}

public enum DirectUploadCapability {
    public typealias Send = @Sendable (URLRequest) async throws -> (status: Int, body: Data, headers: [String: String])
    public static let defaultTimeoutMs = 30_000

    static func join(base: String, path: String) -> String {
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed + path
    }

    static func jsonHeaders(apiKey: String?) -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        if let apiKey { headers["Authorization"] = "Bearer \(apiKey)" }
        return headers
    }

    static func request(url: String, method: String, headers: [String: String], body: Data?) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        return request
    }

    /// Ask the server for a signed machine-scope attestation.
    public static func requestDaemonScopeAttestation(
        serverUrl: String,
        apiKey: String,
        scope: String,
        metadata: [String: String]? = nil,
        send: Send
    ) async throws -> DaemonScopeAttestation {
        var payload: [String: Any] = ["scope": scope]
        if let metadata { payload["metadata"] = metadata }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = request(
            url: join(base: serverUrl, path: "/internal/machine/scope-attestation"),
            method: "POST", headers: jsonHeaders(apiKey: apiKey), body: body
        )
        let response: (status: Int, body: Data, headers: [String: String])
        do {
            response = try await send(request)
        } catch {
            throw DirectUploadError("Failed to request daemon scope attestation", stage: .attestation, cause: error)
        }
        guard (200..<300).contains(response.status) else {
            throw DirectUploadError(
                "Failed to request daemon scope attestation (\(response.status))",
                stage: .attestation, httpStatus: response.status
            )
        }
        guard let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let attestation = object["attestation"] as? String,
              let scopeValue = object["scope"] as? String,
              let audience = object["audience"] as? String,
              let expiresAt = object["expiresAt"] as? String
        else {
            throw DirectUploadError("Failed to request daemon scope attestation", stage: .attestation)
        }
        var metadataOut: [String: String]?
        if let raw = object["metadata"] as? [String: String] { metadataOut = raw }
        return DaemonScopeAttestation(
            attestation: attestation, scope: scopeValue, audience: audience,
            resource: object["resource"] as? String, metadata: metadataOut, expiresAt: expiresAt
        )
    }

    /// Sign, then create the upload session on the worker (server stays out of
    /// the data plane).
    public static func createDirectUploadSession(
        serverUrl: String,
        apiKey: String,
        workerUrl: String,
        scope: String,
        createPath: String = "/api/uploads",
        body: [String: Any],
        attestationMetadata: [String: String]? = nil,
        verifyCapability: ((DaemonScopeAttestation) throws -> Void)? = nil,
        send: Send
    ) async throws -> (capability: DaemonScopeAttestation, response: DirectUploadCreateResponse) {
        let capability = try await requestDaemonScopeAttestation(
            serverUrl: serverUrl, apiKey: apiKey, scope: scope, metadata: attestationMetadata, send: send
        )
        try verifyCapability?(capability)
        var payload = body
        payload["attestation"] = capability.attestation
        let requestBody = try JSONSerialization.data(withJSONObject: payload)
        let request = request(
            url: join(base: workerUrl, path: createPath),
            method: "POST", headers: jsonHeaders(apiKey: nil), body: requestBody
        )
        let response: (status: Int, body: Data, headers: [String: String])
        do {
            response = try await send(request)
        } catch {
            throw DirectUploadError("Failed to create direct upload session", stage: .create, cause: error)
        }
        guard (200..<300).contains(response.status) else {
            throw DirectUploadError(
                "Failed to create direct upload session (\(response.status))", stage: .create, httpStatus: response.status
            )
        }
        guard let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let upload = object["upload"] as? [String: Any],
              let method = upload["method"] as? String,
              let url = upload["url"] as? String
        else {
            throw DirectUploadError("Failed to create direct upload session", stage: .create)
        }
        let headers = (upload["headers"] as? [String: String]) ?? [:]
        return (capability, DirectUploadCreateResponse(method: method, url: url, headers: headers, raw: object))
    }

    /// Attestation → create → PUT the bytes to the signed URL.
    public static func uploadWithSignedCapability(
        serverUrl: String,
        apiKey: String,
        workerUrl: String,
        scope: String,
        createPath: String = "/api/uploads",
        createBody: [String: Any],
        attestationMetadata: [String: String]? = nil,
        uploadBody: Data,
        verifyCapability: ((DaemonScopeAttestation) throws -> Void)? = nil,
        verifySession: ((DaemonScopeAttestation, DirectUploadCreateResponse) throws -> Void)? = nil,
        send: Send
    ) async throws -> (capability: DaemonScopeAttestation, session: DirectUploadCreateResponse, uploadStatus: Int) {
        let created = try await createDirectUploadSession(
            serverUrl: serverUrl, apiKey: apiKey, workerUrl: workerUrl, scope: scope,
            createPath: createPath, body: createBody, attestationMetadata: attestationMetadata,
            verifyCapability: verifyCapability, send: send
        )
        try verifySession?(created.capability, created.response)
        var request = URLRequest(url: URL(string: created.response.url)!)
        request.httpMethod = created.response.method
        for (name, value) in created.response.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = uploadBody
        let response: (status: Int, body: Data, headers: [String: String])
        do {
            response = try await send(request)
        } catch {
            throw DirectUploadError("Failed to upload with signed capability", stage: .put, cause: error)
        }
        guard (200..<300).contains(response.status) else {
            throw DirectUploadError(
                "Failed to upload with signed capability (\(response.status))", stage: .put, httpStatus: response.status
            )
        }
        return (created.capability, created.response, response.status)
    }

    /// Typed classification of a failure; never parses messages for status.
    public static func classify(_ error: Error) -> DirectUploadFailureClass {
        var chain: [Error] = [error]
        var current: Error? = error
        var depth = 0
        while let error = current, depth < 4 {
            if let direct = error as? DirectUploadError {
                if let httpStatus = direct.httpStatus {
                    return .init(stage: direct.stage, httpStatus: httpStatus,
                                 httpClass: httpStatus >= 500 ? "5xx" : "4xx")
                }
                if let cause = direct.cause {
                    chain.append(cause)
                    current = cause
                    depth += 1
                    continue
                }
                return .init(stage: direct.stage, httpStatus: nil, httpClass: classifyNetwork(cause: direct.cause))
            }
            if let http = error as? HttpStatusError {
                return .init(stage: nil, httpStatus: http.status,
                             httpClass: http.status >= 500 ? "5xx" : http.status >= 400 ? "4xx" : "other")
            }
            if error is URLError { return .init(stage: nil, httpStatus: nil, httpClass: "network") }
            return .init(stage: nil, httpStatus: nil, httpClass: "other")
        }
        return .init(stage: nil, httpStatus: nil, httpClass: "other")
    }

    static func classifyNetwork(cause: Error?) -> String {
        if cause is URLError { return "network" }
        if cause is HttpStatusError { return "other" }
        return "other"
    }
}
