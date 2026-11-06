import Foundation

/// One `{"key":value}` member of an `OrderedJSON.object`.
///
/// The member position in the array is the published position in the printed
/// object. The convenience initializers bridge the JSON scalars so a body
/// builder reads like the legacy `"{…}"` literal it replaces.
public struct OrderedJSONField: Sendable, Equatable {
    public let key: String
    public let value: OrderedJSON

    public init(_ key: String, _ value: OrderedJSON) {
        self.key = key
        self.value = value
    }

    public init(_ key: String, _ value: String) {
        self.init(key, .string(value))
    }

    public init(_ key: String, _ value: Int) {
        self.init(key, .int(value))
    }

    public init(_ key: String, _ value: Double) {
        self.init(key, .double(value))
    }

    public init(_ key: String, _ value: Bool) {
        self.init(key, .bool(value))
    }

    /// A member that publishes JSON `null` when the value is absent. Use this
    /// for an upstream field that is present but nullable; an absent optional
    /// member (omitted from the object) is `OrderedJSONObject`'s
    /// `append(_:ifPresent:)`.
    public init(_ key: String, optional value: String?) {
        self.init(key, value.map(OrderedJSON.string) ?? .null)
    }

    public init(_ key: String, optional value: Int?) {
        self.init(key, value.map(OrderedJSON.int) ?? .null)
    }

    public init(_ key: String, optional value: Double?) {
        self.init(key, value.map(OrderedJSON.double) ?? .null)
    }

    public init(_ key: String, optional value: Bool?) {
        self.init(key, value.map(OrderedJSON.bool) ?? .null)
    }

    /// A member whose value is another ordered body.
    public init(_ key: String, _ value: some JSONBodyConvertible) {
        self.init(key, value.jsonBody)
    }
}

/// A JSON tree that prints object members in declared order.
///
/// Linux Foundation's `JSONEncoder` stores keyed containers in a hash
/// container, so the same `Codable` value can print the same object with a
/// different member order on two calls. A body whose published order is not
/// alphabetical (or is alphabetical but must stay stable) is built as this
/// tree, and `Sources/RaftHTTPServer/Features/Respond.swift` prints it once.
///
/// Strings render through the module's legacy `jsonString` escaper (defined in
/// `Fallback.swift`), so escaping stays byte-identical to the hand-written
/// bodies the port started with. Rendering has no whitespace and no trailing
/// newline.
public indirect enum OrderedJSON: Sendable, Equatable {
    /// Members print in array order. Duplicate keys are preserved as written;
    /// do not use them for a published object.
    case object([OrderedJSONField])
    case array([OrderedJSON])
    case string(String)
    case int(Int)
    /// `value.description` when finite, otherwise `null` (JSON has no NaN or
    /// infinity spelling).
    case double(Double)
    case bool(Bool)
    case null
    /// A fragment that is already valid JSON text. The tree cannot reorder or
    /// escape it, so this is only for a value the domain has already rendered
    /// with `OrderedJSON`/`jsonString`; every other case is preferred.
    case raw(String)

    /// The exact published JSON text.
    public func render() -> String {
        switch self {
        case .object(let fields):
            var out = "{"
            for (index, field) in fields.enumerated() {
                if index > 0 { out += "," }
                out += jsonString(field.key)
                out += ":"
                out += field.value.render()
            }
            return out + "}"
        case .array(let values):
            return "[" + values.map { $0.render() }.joined(separator: ",") + "]"
        case .string(let value):
            return jsonString(value)
        case .int(let value):
            return String(value)
        case .double(let value):
            return value.isFinite ? value.description : "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .raw(let value):
            return value
        }
    }

    /// A string, or the JSON `null` an absent nullable field publishes.
    public static func stringOrNull(_ value: String?) -> OrderedJSON {
        value.map(OrderedJSON.string) ?? .null
    }

    public static func intOrNull(_ value: Int?) -> OrderedJSON {
        value.map(OrderedJSON.int) ?? .null
    }

    public static func doubleOrNull(_ value: Double?) -> OrderedJSON {
        value.map(OrderedJSON.double) ?? .null
    }

    public static func boolOrNull(_ value: Bool?) -> OrderedJSON {
        value.map(OrderedJSON.bool) ?? .null
    }

    /// A nested ordered body, or the JSON `null` when it is absent.
    public static func bodyOrNull(_ value: (some JSONBodyConvertible)?) -> OrderedJSON {
        value?.jsonBody ?? .null
    }
}

/// A response body that owns its published JSON bytes.
///
/// A conforming type selects the ordered overload of
/// `Sources/RaftHTTPServer/Features/Respond.swift`, which renders `jsonBody`
/// directly instead of running `JSONEncoder`. Every published key — including
/// a literal `null` — has to appear in the tree; nothing is filled in.
public protocol JSONBodyConvertible: Sendable {
    /// The exact body tree, members in the upstream order.
    var jsonBody: OrderedJSON { get }
}

/// A mutable object builder that keeps member order.
///
/// ```swift
/// var body = OrderedJSONObject()
/// body.append("status", "accepted")
/// body.append("receipt_id", receiptId)
/// body.append("route_basis", ifPresent: routeBasis)   // omitted when nil
/// body.append("route_target", optional: routeTarget)  // JSON null when nil
/// return body.json
/// ```
public struct OrderedJSONObject: Sendable, Equatable {
    public private(set) var fields: [OrderedJSONField]

    public init() {
        self.fields = []
    }

    public init(_ fields: [OrderedJSONField]) {
        self.fields = fields
    }

    public mutating func append(_ key: String, _ value: OrderedJSON) {
        fields.append(OrderedJSONField(key, value))
    }

    public mutating func append(_ key: String, _ value: String) {
        fields.append(OrderedJSONField(key, value))
    }

    public mutating func append(_ key: String, _ value: Int) {
        fields.append(OrderedJSONField(key, value))
    }

    public mutating func append(_ key: String, _ value: Double) {
        fields.append(OrderedJSONField(key, value))
    }

    public mutating func append(_ key: String, _ value: Bool) {
        fields.append(OrderedJSONField(key, value))
    }

    public mutating func append(_ key: String, _ value: some JSONBodyConvertible) {
        fields.append(OrderedJSONField(key, value.jsonBody))
    }

    /// A member that publishes JSON `null` when the value is absent.
    public mutating func append(_ key: String, optional value: String?) {
        fields.append(OrderedJSONField(key, optional: value))
    }

    public mutating func append(_ key: String, optional value: Int?) {
        fields.append(OrderedJSONField(key, optional: value))
    }

    public mutating func append(_ key: String, optional value: Double?) {
        fields.append(OrderedJSONField(key, optional: value))
    }

    public mutating func append(_ key: String, optional value: Bool?) {
        fields.append(OrderedJSONField(key, optional: value))
    }

    /// A member that is omitted entirely when the value is absent.
    public mutating func append(_ key: String, ifPresent value: String?) {
        if let value { fields.append(OrderedJSONField(key, value)) }
    }

    public mutating func append(_ key: String, ifPresent value: Int?) {
        if let value { fields.append(OrderedJSONField(key, value)) }
    }

    public mutating func append(_ key: String, ifPresent value: Double?) {
        if let value { fields.append(OrderedJSONField(key, value)) }
    }

    public mutating func append(_ key: String, ifPresent value: Bool?) {
        if let value { fields.append(OrderedJSONField(key, value)) }
    }

    public mutating func append(_ key: String, ifPresent value: OrderedJSON?) {
        if let value { fields.append(OrderedJSONField(key, value)) }
    }

    /// The ordered object value.
    public var json: OrderedJSON {
        .object(fields)
    }
}
