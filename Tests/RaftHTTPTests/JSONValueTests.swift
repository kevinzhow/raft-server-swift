import Foundation
import RaftShared
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
