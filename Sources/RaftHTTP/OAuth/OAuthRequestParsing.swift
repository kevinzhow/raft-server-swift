import CoreFoundation
import Foundation
import RaftShared

/// Foundation is an input compatibility boundary: duplicate keys are last-wins,
/// numeric 0/1 can bridge to Bool, and payload numbers retain Foundation's exact
/// sorted rendering. No Foundation object escapes into the Sendable ledger DTO.
struct OAuthRequestBody: Sendable {
    let members: [String: JSONValue]
    let payloadJSON: String?

    /// `nil` when the text is not a JSON object.
    static func parse(_ text: String) -> OAuthRequestBody? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return nil
        }
        let payloadJSON: String?
        if let payload = object["payload"], JSONSerialization.isValidJSONObject(payload),
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            payloadJSON = String(decoding: data, as: UTF8.self)
        } else {
            payloadJSON = nil
        }
        return OAuthRequestBody(members: object.mapValues(project), payloadJSON: payloadJSON)
    }

    private static func project(_ value: Any) -> JSONValue {
        switch value {
        case let object as [String: Any]: .object(object.mapValues(project))
        case let array as [Any]: .array(array.map(project))
        case let string as String: .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                .bool(number.boolValue)
            } else if let integer = Int64(number.stringValue) {
                .integer(integer)
            } else {
                .number(number.doubleValue)
            }
        default: .null // JSONSerialization's only remaining value is NSNull.
        }
    }

    /// The member, present even when its value is JSON `null`.
    func value(_ key: String) -> JSONValue? { members[key] }

    /// The legacy `object[key] as? String`: JSON strings only.
    func string(_ key: String) -> String? {
        if case .string(let text)? = members[key] { return text }
        return nil
    }

    /// The legacy `object[key] as? Bool`: a JSON boolean, and the numbers `0`
    /// and `1` (they bridged to `NSNumber`).
    func bool(_ key: String) -> Bool? {
        switch members[key] {
        case .bool(let flag)?: flag
        case .integer(let number)?: number == 0 ? false : (number == 1 ? true : nil)
        case .number(let number)?: number == 0 ? false : (number == 1 ? true : nil)
        default: nil
        }
    }
}

/// Request-shape helpers that do not read ledger state: bearer and client
/// credentials, token-endpoint fields (form or JSON) and query strings.
enum OAuthRequestParsing {
    static func bearerToken(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : token
    }

    static func clientCredentials(
        authorization: String?,
        fields: [String: String]
    ) -> (clientId: String, clientSecret: String)? {
        if let authorization, authorization.hasPrefix("Basic ") {
            let encoded = String(authorization.dropFirst("Basic ".count))
            if let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8),
               let separator = decoded.firstIndex(of: ":"), separator != decoded.startIndex {
                return (String(decoded[..<separator]), String(decoded[decoded.index(after: separator)...]))
            }
        }
        let clientId = fields["client_id"] ?? fields["clientId"]
        let clientSecret = fields["client_secret"] ?? fields["clientSecret"]
        if let clientId, let clientSecret, !clientId.isEmpty, !clientSecret.isEmpty {
            return (clientId, clientSecret)
        }
        return nil
    }

    /// Presence matters even when the JSON value is null or not a string.
    static func jsonBodyHasKey(_ body: String, _ key: String) -> Bool {
        guard let object = OAuthRequestBody.parse(body) else { return false }
        return object.value(key) != nil
    }

    /// Token-endpoint fields: a JSON object body (string members only) or a
    /// form body. A `{`-prefixed body that is not valid JSON falls through to
    /// the form reader, as before.
    static func tokenFields(_ body: String) -> [String: String] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let object = OAuthRequestBody.parse(trimmed) {
            var fields: [String: String] = [:]
            for key in object.members.keys {
                if let text = object.string(key) { fields[key] = text }
            }
            if object.value("code_verifier") != nil { fields["code_verifier"] = fields["code_verifier"] ?? "" }
            return fields
        }
        var fields: [String: String] = [:]
        for part in trimmed.split(separator: "&", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = formDecode(pieces.first ?? "")
            let value = formDecode(pieces.count > 1 ? pieces[1] : "")
            if !name.isEmpty { fields[name] = value }
        }
        return fields
    }

    static func queryParameters(_ query: String) -> [String: String] {
        var values: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let rawName = parts.first ?? ""
            let rawValue = parts.count > 1 ? parts[1] : ""
            let name = (rawName.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawName)
            let value = (rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue)
            if !name.isEmpty { values[name] = value }
        }
        return values
    }

    private static func formDecode(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
