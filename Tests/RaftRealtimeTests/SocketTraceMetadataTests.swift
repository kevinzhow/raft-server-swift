import Foundation
import Testing
import RaftRealtime

@Test func stripRemovesTracingEnvelopeWithoutChangingPayloadSemantics() throws {
    let payload: [String: Any] = [
        "channelId": "channel-1",
        "content": "hello",
        "_trace": ["traceparent": "00-abc-def-01", "interactionId": "interaction-1"],
        "nested": [
            "keep": true,
            "_trace": ["traceparent": "00-nested-def-01"],
        ],
        "items": [
            ["id": "item-1", "_trace": ["traceparent": "00-item-def-01"]],
            "plain",
        ],
    ]
    let stripped = try #require(stripSocketTraceMetadata(payload) as? [String: Any])
    let expected: [String: Any] = [
        "channelId": "channel-1",
        "content": "hello",
        "nested": ["keep": true],
        "items": [
            ["id": "item-1"],
            "plain",
        ],
    ]
    let strippedData = try JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys])
    let expectedData = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
    #expect(strippedData == expectedData)
    
    let nested = try #require(stripped["nested"] as? [String: Any])
    #expect(nested["_trace"] == nil)
    let items = try #require(stripped["items"] as? [Any])
    #expect((items[0] as? [String: Any])?["_trace"] == nil)
    #expect(items[1] as? String == "plain")
}
