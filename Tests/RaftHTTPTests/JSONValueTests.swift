import Foundation
import HTTPTypes
import RaftHTTP
import Testing

@Test func canonicalJSONValueEncodesSortedObjectsAndTypedScalars() throws {
    let value = JSONValue.object([
        "z": .string("tail"),
        "a": .array([.integer(1), .bool(true), .null]),
        "m": .object(["x": .number(1.5), "n": .integer(-2)]),
    ])
    let body = try value.string()
    #expect(body == #"{"a":[1,true,null],"m":{"n":-2,"x":1.5},"z":"tail"}"#)
    #expect(try JSONValue(NSNull()).string() == "null")
    #expect(try JSONValue(NSNumber(value: true)).string() == "true")
    #expect(try JSONValue(["k": NSNumber(value: 3)]).string() == #"{"k":3}"#)
}

@Test func jsonValueReplySetsStableHeadersAndKeepsExtras() {
    let reply = HTTPReply.jsonValue(201, .object(["id": .string("m1")]), extraHeaders: ["Server-Timing": "raft;dur=1.0", "Content-Type": "text/plain"])
    #expect(reply.status == 201)
    #expect(reply.headers["Content-Type"] == "application/json; charset=utf-8")
    #expect(reply.headers["Cache-Control"] == "no-store")
    #expect(reply.headers["Server-Timing"] == "raft;dur=1.0")
    #expect(reply.headers["Content-Length"] == String(reply.body.utf8.count))
    #expect(reply.body == #"{"id":"m1"}"#)
}
