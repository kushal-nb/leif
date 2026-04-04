import Foundation

/// Renders any JSON value as a pretty-printed string with indentation.
enum JSONFormatter {

    static func prettyPrint(_ value: Any, indent: Int = 0) -> String {
        // Guard against deeply nested / cyclic data causing a stack overflow.
        // Real JSON rarely exceeds 30 levels; 64 is a safe ceiling.
        guard indent < 64 else { return "…" }

        let pad = String(repeating: "  ", count: indent)
        switch value {
        case let dict as [String: Any]:
            if dict.isEmpty { return "{}" }
            let lines = dict.keys.sorted().map { key -> String in
                let v = prettyPrint(dict[key]!, indent: indent + 1)
                return "\(pad)  \"\(key)\": \(v)"
            }
            return "{\n\(lines.joined(separator: ",\n"))\n\(pad)}"

        case let arr as [Any]:
            if arr.isEmpty { return "[]" }
            let lines = arr.map { "\(pad)  \(prettyPrint($0, indent: indent + 1))" }
            return "[\n\(lines.joined(separator: ",\n"))\n\(pad)]"

        // NOTE: The NSString case has been intentionally removed.
        // In Swift, `case let str as String` matches both Swift String and NSString via
        // ObjC bridging.  Having a separate NSString branch that calls
        // `prettyPrint(ns as String)` caused infinite recursion: storing a Swift String
        // as `Any` makes `is NSString` return true (transparent bridging), so the call
        // bounced between the NSString branch and itself forever until stack overflow.

        case let str as String:
            var trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            // Value is a JSON string literal whose contents are object/array text.
            if trimmed.first == "\"", trimmed.last == "\"", trimmed.count >= 2,
               let d = trimmed.data(using: .utf8),
               let inner = try? JSONSerialization.jsonObject(with: d) as? String {
                trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Auto-expand string-encoded JSON.
            // Guard: only recurse when the parsed result is a container (dict/array), never
            // when it is itself a string — that would risk another infinite-recursion cycle.
            if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) && trimmed.count > 2 {
                if let data = trimmed.data(using: .utf8),
                   let nested = try? JSONSerialization.jsonObject(with: data),
                   !(nested is String) {
                    return prettyPrint(nested, indent: indent)
                }
            }
            // Auto-expand Go struct format &{...}
            if trimmed.hasPrefix("&{") || (trimmed.hasPrefix("{") && !trimmed.contains("\"")) {
                if let parsed = GoStructParser.parse(trimmed) {
                    return prettyPrint(parsed, indent: indent)
                }
            }
            return "\"\(str.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""

        case let num as NSNumber:
            if num === kCFBooleanTrue || num === kCFBooleanFalse {
                return num.boolValue ? "true" : "false"
            }
            return num.stringValue

        case is NSNull:
            return "null"

        default:
            return "\(value)"
        }
    }

    static func jsonData(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }
}

// MARK: - Go struct fmt parser
// Handles &{Field:Value Field:Value ...} produced by Go's fmt.Sprintf("%v", struct)
enum GoStructParser {

    private static let fieldBoundaryRE = try! NSRegularExpression(
        pattern: #"(?:^| )([A-Za-z][A-Za-z0-9_]*):"#)

    /// Returns [String: Any] for a Go struct string, nil if it doesn't look like one.
    static func parse(_ raw: String) -> [String: Any]? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("&") { s = String(s.dropFirst()) }
        guard s.hasPrefix("{") && s.hasSuffix("}") && s.count > 2 else { return nil }
        s = String(s.dropFirst().dropLast())

        // Find all "FieldName:" boundaries using regex
        let ns = s as NSString
        let nsRange = NSRange(location: 0, length: ns.length)
        let matches = fieldBoundaryRE.matches(in: s, range: nsRange)
        guard !matches.isEmpty else { return nil }

        var result = [String: Any]()
        for (i, match) in matches.enumerated() {
            let key = ns.substring(with: match.range(at: 1))
            // Value spans from end of this match to start of next (or end of string)
            let valueStart = match.range.location + match.range.length
            let valueEnd = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            guard valueEnd >= valueStart else { continue }
            let raw = ns.substring(with: NSRange(location: valueStart,
                                                  length: valueEnd - valueStart))
                .trimmingCharacters(in: .whitespaces)
            result[key] = coerce(raw)
        }
        return result.isEmpty ? nil : result
    }

    /// Best-effort type coercion for a Go fmt value string.
    private static func coerce(_ s: String) -> Any {
        if s == "<nil>" || s == "nil" { return NSNull() }
        if s == "true"  { return true  }
        if s == "false" { return false }
        if let n = Int(s)    { return n }
        if let n = Double(s) { return n }
        // Nested &{...} or {...} — recurse
        if s.hasPrefix("&{") || (s.hasPrefix("{") && !s.contains("\"")) {
            if let nested = parse(s) { return nested }
        }
        return s
    }
}

// MARK: - JSON tree node
indirect enum JSONNode: Identifiable {
    case scalar(id: UUID, key: String?, value: String, type: NodeType)
    case object(id: UUID, key: String?, children: [JSONNode], badge: String?)
    case array(id: UUID, key: String?, children: [JSONNode])

    var id: UUID {
        switch self {
        case .scalar(let id, _, _, _): return id
        case .object(let id, _, _, _): return id
        case .array(let id, _, _): return id
        }
    }

    enum NodeType { case string, number, bool, null }

    var key: String? {
        switch self {
        case .scalar(_, let k, _, _): return k
        case .object(_, let k, _, _): return k
        case .array(_, let k, _): return k
        }
    }

    var isLeaf: Bool {
        if case .scalar = self { return true }
        return false
    }

    static func build(from value: Any, key: String? = nil) -> JSONNode {
        switch value {
        case let dict as [String: Any]:
            let children = dict.keys.sorted().map { k in build(from: dict[k]!, key: k) }
            return .object(id: UUID(), key: key, children: children, badge: nil)

        case let arr as [Any]:
            let children = arr.enumerated().map { idx, v in build(from: v, key: "[\(idx)]") }
            return .array(id: UUID(), key: key, children: children)

        case let str as String:
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)

            // 1. String-encoded JSON object/array
            if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) && trimmed.count > 2 {
                if let data = trimmed.data(using: .utf8),
                   let nested = try? JSONSerialization.jsonObject(with: data) {
                    let inner = build(from: nested, key: nil)
                    switch inner {
                    case .object(let id, _, let ch, _):
                        return .object(id: id, key: key, children: ch, badge: "JSON")
                    case .array(let id, _, let ch):
                        return .array(id: id, key: key, children: ch)
                    default: break
                    }
                }
            }

            // 2. Go struct fmt dump: &{Field:Value ...} or plain {Field:Value ...}
            if trimmed.hasPrefix("&{") || (trimmed.hasPrefix("{") && !trimmed.contains("\"") && trimmed.contains(":")) {
                if let goFields = GoStructParser.parse(trimmed) {
                    let children = goFields.keys.sorted().map { k in build(from: goFields[k]!, key: k) }
                    return .object(id: UUID(), key: key, children: children, badge: "Go")
                }
            }

            return .scalar(id: UUID(), key: key, value: str, type: .string)

        case let num as NSNumber:
            if num === kCFBooleanTrue || num === kCFBooleanFalse {
                return .scalar(id: UUID(), key: key, value: num.boolValue ? "true" : "false", type: .bool)
            }
            return .scalar(id: UUID(), key: key, value: num.stringValue, type: .number)

        case is NSNull:
            return .scalar(id: UUID(), key: key, value: "null", type: .null)

        default:
            return .scalar(id: UUID(), key: key, value: "\(value)", type: .string)
        }
    }
}
