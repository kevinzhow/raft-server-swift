import Foundation
import RaftShared
import Testing
@testable import RaftHTTP

/// `LegacySortedJSON` must print the bytes `JSONSerialization` printed for the
/// same decoded payload; the reference below is the retired bridge.

private func legacyObject(_ value: JSONValue) -> Any {
    switch value {
    case .object(let members): return members.mapValues(legacyObject)
    case .array(let values): return values.map(legacyObject)
    case .string(let string): return string
    case .number(let number): return number
    case .integer(let integer): return integer
    case .bool(let boolean): return boolean
    case .null: return NSNull()
    }
}

private func legacyRender(_ value: JSONValue) -> String {
    guard let object = legacyObject(value) as? [String: Any],
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

private struct Rng: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let alphabet = [
    "a", "b", "A", "B", "e", "é", "É", "1", "2", "10", "_", "-", " ", "😀", "\u{FFFD}",
    "z", "Z", "ß", "/", ".", "\"", "\\", "\n", "\t", "\u{1}", "\u{1f}", "\u{7f}", "\u{2028}", "\u{8}", "\u{c}",
]

private func randomString(_ rng: inout Rng) -> String {
    (0..<Int.random(in: 0...5, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }.joined()
}

private func randomValue(_ rng: inout Rng, depth: Int) -> JSONValue {
    switch Int.random(in: 0..<(depth > 2 ? 6 : 8), using: &rng) {
    case 0: return .null
    case 1: return .bool(Bool.random(using: &rng))
    case 2: return .integer(Int64.random(in: -1_000_000...1_000_000, using: &rng))
    case 3:
        return .number([0.5, 1.5, -2.25, 1e21, 1e-7, 0.1, 3e15, 1e16, 12345678.9, 100.0, -0.0, 5e-324, 0.30000000000000004]
            .randomElement(using: &rng)!)
    case 4, 5: return .string(randomString(&rng))
    case 6:
        return .array((0..<Int.random(in: 0...4, using: &rng)).map { _ in randomValue(&rng, depth: depth + 1) })
    default:
        var members: [String: JSONValue] = [:]
        for _ in 0..<Int.random(in: 0...5, using: &rng) {
            members[randomString(&rng)] = randomValue(&rng, depth: depth + 1)
        }
        return .object(members)
    }
}

@Test func renderMatchesJSONSerializationSortedKeysForRandomTrees() {
    var rng = Rng(state: 0xFEED_FACE)
    var mismatches = 0
    for _ in 0..<4000 {
        let value = JSONValue.object(["root": randomValue(&rng, depth: 0), randomString(&rng): randomValue(&rng, depth: 1)])
        let mine = LegacySortedJSON.render(value)
        let legacy = legacyRender(value)
        if mine != legacy { mismatches += 1; if mismatches < 4 { Issue.record("\(String(describing: mine)) != \(legacy)") } }
    }
    #expect(mismatches == 0)
}

@Test func renderLocksTheLegacyVectors() {
    let value = JSONValue.object([
        "b": .integer(1),
        "a": .array([.number(1.0), .number(1e21), .string("a/b\u{1}\u{7f}é\"\\\n"), .null, .bool(true)]),
        "B": .object(["z": .integer(1), "y": .number(0.5)]),
        "10": .integer(10),
        "2": .integer(2),
    ])
    #expect(LegacySortedJSON.render(value)
        == "{\"2\":2,\"10\":10,\"a\":[1,1e+21,\"a\\/b\\u0001\u{7f}é\\\"\\\\\\n\",null,true],\"b\":1,\"B\":{\"y\":0.5,\"z\":1}}")
    #expect(LegacySortedJSON.render(value) == legacyRender(value))
}

@Test func nonFiniteNumbersAreUnrepresentableLikeTheLegacyWriter() {
    let value = JSONValue.object(["n": .number(.infinity)])
    #expect(LegacySortedJSON.render(value) == nil)
    #expect(legacyRender(value) == "{}")
}
