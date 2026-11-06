import Foundation
import RaftHTTP
import Testing

// `OrderedJSON` is the canonical ordered-body tree. These tests lock the three
// properties a migrated domain depends on: the legacy `jsonString` escaping,
// declared member order, and nesting/scalar bridging.

private struct NestedBody: JSONBodyConvertible {
    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("id", 7),
        ])
    }
}

@Test func orderedJSONEscapesExactlyLikeTheLegacyJSONStringEscaper() {
    #expect(OrderedJSON.string("plain").render() == "\"plain\"")
    #expect(OrderedJSON.string("").render() == "\"\"")
    #expect(OrderedJSON.string("a\"b\\c\nd\re\tf\u{08}g\u{0C}h").render()
        == "\"a\\\"b\\\\c\\nd\\re\\tf\\bg\\fh\"")
    // Every other C0 control is a `\u00xx` escape, and the two JavaScript line
    // separators keep the legacy escape too.
    #expect(OrderedJSON.string("\u{01}\u{1F}").render() == "\"\\u0001\\u001f\"")
    #expect(OrderedJSON.string("\u{2028}\u{2029}").render() == "\"\\u2028\\u2029\"")
    // The legacy escaper never escapes a solidus, and non-ASCII stays literal.
    #expect(OrderedJSON.string("https://example.com/a/b").render()
        == "\"https://example.com/a/b\"")
    #expect(OrderedJSON.string("héllo 😀").render() == "\"héllo 😀\"")
    // Object keys use the same escaper as values.
    #expect(OrderedJSON.object([OrderedJSONField("a\"b", 1)]).render() == #"{"a\"b":1}"#)
}

@Test func orderedJSONPrintsMembersInDeclaredOrderNotSortedOrder() {
    let body = OrderedJSON.object([
        OrderedJSONField("z", 1),
        OrderedJSONField("a", "x"),
        OrderedJSONField("m", .array([.int(2), .bool(false), .null])),
    ])
    #expect(body.render() == #"{"z":1,"a":"x","m":[2,false,null]}"#)
}

@Test func orderedJSONNestsBodiesAndBridgesScalars() {
    let body = OrderedJSON.object([
        OrderedJSONField("nested", NestedBody()),
        OrderedJSONField("flag", true),
        OrderedJSONField("count", -3),
        OrderedJSONField("ratio", 0.5),
        OrderedJSONField("text", "v"),
        OrderedJSONField("nothing", .null),
        OrderedJSONField("fragment", .raw(#"{"already":1}"#)),
        OrderedJSONField("list", .array([.string("a"), .int(1)])),
    ])
    #expect(body.render()
        == #"{"nested":{"ok":true,"id":7},"flag":true,"count":-3,"ratio":0.5,"text":"v","nothing":null,"fragment":{"already":1},"list":["a",1]}"#)
}

@Test func orderedJSONObjectOmitsAbsentOptionalsAndPrintsNullableOnes() {
    var body = OrderedJSONObject()
    body.append("kept", "v")
    body.append("omitted", ifPresent: String?.none)
    body.append("nullable", optional: String?.none)
    body.append("present", ifPresent: "here")
    body.append("nullablePresent", optional: "here")
    body.append("count", ifPresent: Int?.none)
    #expect(body.json.render()
        == #"{"kept":"v","nullable":null,"present":"here","nullablePresent":"here"}"#)
}

@Test func orderedJSONRendersFiniteDoublesAndRejectsNonFiniteValuesAsNull() {
    #expect(OrderedJSON.double(1).render() == "1.0")
    #expect(OrderedJSON.double(0.1).render() == "0.1")
    #expect(OrderedJSON.double(-2.5).render() == "-2.5")
    #expect(OrderedJSON.double(.nan).render() == "null")
    #expect(OrderedJSON.double(.infinity).render() == "null")
}

@Test func orderedJSONEscapingMatchesTheLegacyFallbackBodyEscaper() {
    // `AppFallback`/the public directory bodies still render through the module
    // `jsonString`; a quote and a newline must look the same in both trees.
    let legacy = "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}"
    let canonical = OrderedJSON.object([
        OrderedJSONField("error", "Missing or invalid Authorization header"),
        OrderedJSONField("code", "auth_required"),
    ]).render()
    #expect(legacy == canonical)
}
