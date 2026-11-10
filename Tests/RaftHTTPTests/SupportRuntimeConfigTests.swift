import Foundation
@testable import RaftHTTP
import RaftShared
import Testing

@Test func supportHelperRuntimeConfigPreservesStoredFoundationBytes() throws {
    let source = #"{"version":1,"flag":true,"zero":0,"ratio":0.25,"path":"a/b","envVars":{"X":"y/z"},"model":{"kind":"preset","id":"a"}}"#
    let document = AgentRuntimeConfigDocument(storedJSON: source)
    let object = try JSONSerialization.jsonObject(with: Data(source.utf8))
    let expected = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    #expect(document.serialized() == expected)
    #expect(AgentRuntimeConfigDocument.serializedEnv(["X": "y/z"]) == #"{"X":"y\/z"}"#)
    let redacted = AgentRuntimeConfigDocument.redactedConfigJSON(#"{"provider":{"apiKey":"secret","url":"a/b"},"version":1}"#)
    #expect(redacted == #"{"provider":{"apiKey":"","url":"a\/b"},"version":1}"#)
    let normalized = AgentRuntimeConfigDocument(request: .object(["version": .integer(1), "flag": .bool(true), "ratio": .number(0.25)]))?.normalized()
    #expect(normalized?.serialized().contains(#""version":1"#) == true)
    #expect(normalized?.serialized().contains(#""flag":true"#) == true)
}

private func foundationRuntimeConfigJSON(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

@Test func supportHelperRuntimeConfigNumberBoundariesMatchFoundation() throws {
    let sources = [
        #"{"number":9223372036854775807}"#,
        #"{"number":9223372036854775808}"#,
        #"{"number":18446744073709551615}"#,
        #"{"number":-9223372036854775808}"#,
        #"{"number":0.125,"negative":-3.75,"integral":1.0}"#,
        #"{"number":1.2345678901234567890123456789}"#,
        #"{"path":"a/b","flag":true,"other":false,"zero":0,"one":1}"#,
        #"{"number":1,"number":18446744073709551615,"flag":false,"flag":true}"#,
        #"{"nested":[9223372036854775808,{"number":18446744073709551615}],"provider":{"apiKey":"first","apiKey":"last","apiUrl":"a/b"}}"#,
    ]
    for source in sources {
        var object = try #require(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
        let document = AgentRuntimeConfigDocument(storedJSON: source)
        #expect(document.serialized() == (try foundationRuntimeConfigJSON(object)))

        if var provider = object["provider"] as? [String: Any], provider["apiKey"] != nil {
            provider["apiKey"] = ""
            object["provider"] = provider
        }
        #expect(AgentRuntimeConfigDocument.redactedConfigJSON(source) == (try foundationRuntimeConfigJSON(object)))
    }
}

@Test func supportHelperRuntimeConfigNormalizationAndProviderMergePreserveNumbers() throws {
    let source = #"{"runtime":"claude","number":9223372036854775808,"number":18446744073709551615,"provider":{"kind":"custom","apiKey":"","apiUrl":"https://a/b"},"envVars":{"KEEP":"a/b","ANTHROPIC_API_KEY":"secret"},"flag":true}"#
    let previous = AgentRuntimeConfigDocument(storedJSON: #"{"provider":{"apiKey":"first","apiKey":"previous"}}"#)
    var document = AgentRuntimeConfigDocument(storedJSON: source).normalized()
    document.preserveProviderAPIKey(from: previous)

    var expected = try #require(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
    expected["version"] = 1
    expected["mode"] = ["kind": "default"]
    expected["reasoningEffort"] = NSNull()
    expected["envVars"] = ["KEEP": "a/b"]
    var provider = try #require(expected["provider"] as? [String: Any])
    provider["apiKey"] = "previous"
    expected["provider"] = provider
    #expect(document.serialized() == (try foundationRuntimeConfigJSON(expected)))
    #expect(document.providerAPIKey == "previous")
    #expect(document.userEnv == ["KEEP": "a/b"])
    #expect(document.derivedEnvVars(userEnv: document.userEnv)["ANTHROPIC_API_KEY"] == "previous")
}
