import Foundation

// MARK: - UUID detection

// UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  (36 chars, dashes at 8/13/18/23)
// O(1) structural check — no regex needed.
func isLikelyUUID(_ s: String) -> Bool {
    guard s.count == 36 else { return false }
    let b = s.utf8
    let i = b.startIndex
    return b[b.index(i, offsetBy:  8)] == UInt8(ascii: "-")
        && b[b.index(i, offsetBy: 13)] == UInt8(ascii: "-")
        && b[b.index(i, offsetBy: 18)] == UInt8(ascii: "-")
        && b[b.index(i, offsetBy: 23)] == UInt8(ascii: "-")
}

// MARK: - Diff row model

struct DiffRow: Identifiable {
    /// Stable index-based id so SwiftUI `ForEach` does not treat every row as new each update (AttributeGraph blowups).
    let id: String
    let depth    : Int
    let key      : String?    // field name or "[i]" for array items
    let status   : Status
    let leftText : String?    // nil means "not present on this side"
    let rightText: String?
    let isContainer: Bool     // object/array header rows
    let isFocusPoint: Bool    // navigatable change
    let hint     : String?    // "Δ +7", "unique identifier changed", etc.

    enum Status {
        case unchanged
        case added             // only in right
        case removed           // only in left
        case modified          // scalar changed
        case containerChanged  // object/array that contains changes
        case containerClean    // object/array with no changes inside
    }

    /// Internal rows use a throwaway id; `JSONDiffer.diff` rewrites ids before returning.
    fileprivate static let buildingId = "__row__"

    fileprivate init(building depth: Int, key: String?, status: Status,
                     leftText: String?, rightText: String?,
                     isContainer: Bool, isFocusPoint: Bool, hint: String?) {
        self.id = DiffRow.buildingId
        self.depth = depth
        self.key = key
        self.status = status
        self.leftText = leftText
        self.rightText = rightText
        self.isContainer = isContainer
        self.isFocusPoint = isFocusPoint
        self.hint = hint
    }

    fileprivate func withStableListIndex(_ index: Int) -> DiffRow {
        DiffRow(
            id: "d-\(index)",
            depth: depth,
            key: key,
            status: status,
            leftText: leftText,
            rightText: rightText,
            isContainer: isContainer,
            isFocusPoint: isFocusPoint,
            hint: hint
        )
    }

    init(id: String, depth: Int, key: String?, status: Status,
         leftText: String?, rightText: String?,
         isContainer: Bool, isFocusPoint: Bool, hint: String?) {
        self.id = id
        self.depth = depth
        self.key = key
        self.status = status
        self.leftText = leftText
        self.rightText = rightText
        self.isContainer = isContainer
        self.isFocusPoint = isFocusPoint
        self.hint = hint
    }
}

// MARK: - Differ

enum JSONDiffer {

    /// Maximum recursion depth to prevent stack overflow on deeply nested / cyclic data.
    private static let maxDepth = 128

    // Entry point — returns a flat ordered list of DiffRows for rendering.
    static func diff(left: [String: Any], right: [String: Any]) -> [DiffRow] {
        var rows: [DiffRow] = []
        diffObject(left: left, right: right, key: nil, depth: 0, into: &rows)
        return rows.enumerated().map { $0.element.withStableListIndex($0.offset) }
    }

    // MARK: Object — appends directly to accumulator (avoids O(n²) array copies)

    private static func diffObject(left: [String: Any], right: [String: Any],
                                   key: String?, depth: Int,
                                   into rows: inout [DiffRow]) {
        guard depth < maxDepth else {
            rows.append(DiffRow(building: depth, key: key, status: .modified,
                                leftText: "{…depth limit…}", rightText: "{…depth limit…}",
                                isContainer: false, isFocusPoint: false, hint: nil))
            return
        }

        let allKeys = Set(left.keys).union(right.keys).sorted()
        // Reserve header slot; we'll fill it in after scanning children.
        let headerIdx = depth > 0 ? rows.count : -1
        if depth > 0 {
            // Placeholder — will be overwritten
            rows.append(DiffRow(building: depth, key: key, status: .containerClean,
                                leftText: nil, rightText: nil,
                                isContainer: true, isFocusPoint: false, hint: nil))
        }

        let childStart = rows.count
        for k in allKeys {
            if let l = left[k], let r = right[k] {
                diffAny(left: l, right: r, key: k, depth: depth + 1, into: &rows)
            } else if let r = right[k] {
                coloredSubtree(value: r, key: k, depth: depth + 1, status: .added, hint: nil, into: &rows)
            } else if let l = left[k] {
                coloredSubtree(value: l, key: k, depth: depth + 1, status: .removed, hint: nil, into: &rows)
            }
        }

        guard depth > 0 else { return }

        let anyChange = rows[childStart...].hasChanges
        let status: DiffRow.Status = anyChange ? .containerChanged : .containerClean
        let lSummary = "{ \(left.count) \(left.count == 1 ? "key" : "keys") }"
        let rSummary = "{ \(right.count) \(right.count == 1 ? "key" : "keys") }"
        rows[headerIdx] = DiffRow(building: depth, key: key, status: status,
                                  leftText: lSummary, rightText: rSummary,
                                  isContainer: true, isFocusPoint: false, hint: nil)
    }

    // MARK: Array

    private static func diffArray(left: [Any], right: [Any],
                                  key: String?, depth: Int,
                                  into rows: inout [DiffRow]) {
        guard depth < maxDepth else {
            rows.append(DiffRow(building: depth, key: key, status: .modified,
                                leftText: "[…depth limit…]", rightText: "[…depth limit…]",
                                isContainer: false, isFocusPoint: false, hint: nil))
            return
        }

        // Reserve header slot
        let headerIdx = rows.count
        rows.append(DiffRow(building: depth, key: key, status: .containerClean,
                            leftText: nil, rightText: nil,
                            isContainer: true, isFocusPoint: false, hint: nil))

        let childStart = rows.count

        let lObjs = left.compactMap  { $0 as? [String: Any] }
        let rObjs = right.compactMap { $0 as? [String: Any] }
        let allAreObjects = lObjs.count == left.count && rObjs.count == right.count

        var matchExtra: String? = nil

        // Try UUID-keyed matching when every element is an object with the same ID field.
        if allAreObjects, let uuidField = findUUIDField(left: lObjs, right: rObjs) {

            let lByID = buildIDMap(objects: lObjs, field: uuidField)
            let rByID = buildIDMap(objects: rObjs, field: uuidField)
            var seen = Set<String>()
            var orderedIDs: [String] = []
            orderedIDs.reserveCapacity(lObjs.count + rObjs.count)
            for obj in lObjs { appendID(from: obj, field: uuidField, into: &orderedIDs, seen: &seen) }
            for obj in rObjs { appendID(from: obj, field: uuidField, into: &orderedIDs, seen: &seen) }

            for uid in orderedIDs {
                let short = String(uid.prefix(8)) + "…"
                let label = "[\(uuidField): \(short)]"
                if let l = lByID[uid], let r = rByID[uid] {
                    diffObject(left: l, right: r, key: label, depth: depth + 1, into: &rows)
                } else if let r = rByID[uid] {
                    coloredSubtree(value: r, key: label, depth: depth + 1, status: .added,
                                   hint: "item added  (id: \(uid))", into: &rows)
                } else if let l = lByID[uid] {
                    coloredSubtree(value: l, key: label, depth: depth + 1, status: .removed,
                                   hint: "item removed  (id: \(uid))", into: &rows)
                }
            }
            matchExtra = "matched by \(uuidField)"
        } else {
            // Index-based diff fallback
            let maxCount = max(left.count, right.count)
            for i in 0..<maxCount {
                if i < left.count && i < right.count {
                    diffAny(left: left[i], right: right[i], key: "[\(i)]", depth: depth + 1, into: &rows)
                } else if i < right.count {
                    coloredSubtree(value: right[i], key: "[\(i)]", depth: depth + 1, status: .added,
                                   hint: nil, into: &rows)
                } else {
                    coloredSubtree(value: left[i], key: "[\(i)]", depth: depth + 1, status: .removed,
                                   hint: nil, into: &rows)
                }
            }
        }

        let anyChange = rows[childStart...].hasChanges
        rows[headerIdx] = makeArrayHeader(key: key, depth: depth, leftCount: left.count,
                                          rightCount: right.count, hasChanges: anyChange,
                                          extra: matchExtra)
    }

    // MARK: Embedded JSON (APIs often ship nested objects as escaped strings)

    private enum EmbeddedJSON {
        case object([String: Any])
        case array([Any])
    }

    /// If `s` is a JSON object or array text, return the parsed value for structural diff.
    private static func parseEmbeddedJSON(_ s: String) -> EmbeddedJSON? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whole value is a JSON *string* literal whose contents are object/array text.
        if t.first == "\"", t.last == "\"", t.count >= 2,
           let d = t.data(using: .utf8),
           let inner = try? JSONSerialization.jsonObject(with: d) as? String {
            t = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard t.count > 2, (t.hasPrefix("{") || t.hasPrefix("[")),
              let d = t.data(using: .utf8),
              let v = try? JSONSerialization.jsonObject(with: d) else { return nil }
        if let o = v as? [String: Any] { return .object(o) }
        if let a = v as? [Any] { return .array(a) }
        // JSONSerialization can return NSDictionary/NSArray that don't match Swift casts directly
        if let o = v as? NSDictionary {
            var swift: [String: Any] = [:]
            for key in o.allKeys {
                guard let ks = key as? String else { continue }
                swift[ks] = o[key] as Any
            }
            return .object(swift)
        }
        if let a = v as? NSArray {
            return .array((0..<a.count).map { a[$0] })
        }
        return nil
    }

    // MARK: Any value — unified type dispatch

    private static func diffAny(left: Any, right: Any, key: String?, depth: Int,
                                into rows: inout [DiffRow]) {
        // Normalize: resolve both sides to their structural types.
        // Strings are checked for embedded JSON so we can diff structurally.
        let lResolved = resolve(left)
        let rResolved = resolve(right)

        switch (lResolved, rResolved) {
        case let (.object(lo), .object(ro)):
            diffObject(left: lo, right: ro, key: key, depth: depth, into: &rows)
        case let (.array(la), .array(ra)):
            diffArray(left: la, right: ra, key: key, depth: depth, into: &rows)
        default:
            diffScalar(left: left, right: right, key: key, depth: depth, into: &rows)
        }
    }

    /// Resolves a value to its structural type for diffing.
    /// Strings containing embedded JSON are parsed into objects/arrays.
    private enum Resolved {
        case object([String: Any])
        case array([Any])
        case scalar(Any)
    }

    private static func resolve(_ value: Any) -> Resolved {
        // Check native container types first
        if let dict = value as? [String: Any] { return .object(dict) }
        if let arr = value as? [Any] { return .array(arr) }

        // Try parsing strings as embedded JSON
        if let s = anyAsSwiftString(value), let embedded = parseEmbeddedJSON(s) {
            switch embedded {
            case .object(let o): return .object(o)
            case .array(let a):  return .array(a)
            }
        }

        return .scalar(value)
    }

    /// `NSString` from `JSONSerialization` does not always match `as String` in `switch` patterns — normalize here.
    private static func anyAsSwiftString(_ v: Any) -> String? {
        switch v {
        case let s as String: return s
        case let s as NSString: return s as String
        default: return nil
        }
    }

    private static func diffScalar(left: Any, right: Any, key: String?, depth: Int,
                                   into rows: inout [DiffRow]) {
        let ls = scalarString(left)
        let rs = scalarString(right)
        if ls == rs {
            rows.append(DiffRow(building: depth, key: key, status: .unchanged,
                                leftText: ls, rightText: rs,
                                isContainer: false, isFocusPoint: false, hint: nil))
        } else {
            let hint = diffHint(leftStr: ls, rightStr: rs, leftVal: left, rightVal: right)
            rows.append(DiffRow(building: depth, key: key, status: .modified,
                                leftText: ls, rightText: rs,
                                isContainer: false, isFocusPoint: true, hint: hint))
        }
    }

    // MARK: Added / removed subtrees

    private static func coloredSubtree(value: Any, key: String?, depth: Int,
                                        status: DiffRow.Status, hint: String?,
                                        into rows: inout [DiffRow]) {
        guard depth < maxDepth else { return }

        let isAdded = status == .added

        // Resolve embedded JSON in strings before rendering subtrees
        let resolved = resolve(value)

        switch resolved {
        case .object(let obj):
            let summary = "{ \(obj.count) \(obj.count == 1 ? "key" : "keys") }"
            rows.append(DiffRow(building: depth, key: key, status: status,
                                leftText: isAdded ? nil : summary,
                                rightText: isAdded ? summary : nil,
                                isContainer: true, isFocusPoint: true, hint: hint))
            for k in obj.keys.sorted() {
                coloredSubtree(value: obj[k]!, key: k, depth: depth + 1,
                               status: status, hint: nil, into: &rows)
            }

        case .array(let arr):
            let summary = "[ \(arr.count) \(arr.count == 1 ? "item" : "items") ]"
            rows.append(DiffRow(building: depth, key: key, status: status,
                                leftText: isAdded ? nil : summary,
                                rightText: isAdded ? summary : nil,
                                isContainer: true, isFocusPoint: true, hint: hint))
            for (offset, element) in arr.enumerated() {
                coloredSubtree(value: element, key: "[\(offset)]", depth: depth + 1,
                               status: status, hint: nil, into: &rows)
            }

        case .scalar(let v):
            let text = scalarString(v)
            let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let h = hint ?? (isLikelyUUID(bare) ? "unique identifier" : nil)
            rows.append(DiffRow(building: depth, key: key, status: status,
                                leftText: isAdded ? nil : text,
                                rightText: isAdded ? text : nil,
                                isContainer: false, isFocusPoint: true, hint: h))
        }
    }

    // MARK: Hints

    private static func diffHint(leftStr: String, rightStr: String, leftVal: Any, rightVal: Any) -> String? {
        let ls = leftStr.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let rs = rightStr.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if isLikelyUUID(ls) || isLikelyUUID(rs) { return "unique identifier changed" }

        // Numeric delta — skip booleans (NSNumber wraps bools too)
        let lNum = leftVal  as? NSNumber
        let rNum = rightVal as? NSNumber
        if let l = lNum, let r = rNum,
           l !== kCFBooleanTrue,  l !== kCFBooleanFalse,
           r !== kCFBooleanTrue,  r !== kCFBooleanFalse {
            let delta = r.doubleValue - l.doubleValue
            let sign  = delta >= 0 ? "+" : ""
            if l.doubleValue == l.doubleValue.rounded(.towardZero) &&
               r.doubleValue == r.doubleValue.rounded(.towardZero) {
                return "Δ \(sign)\(Int(delta))"
            }
            return String(format: "Δ %@%.4g", sign, delta)
        }
        return nil
    }

    // MARK: Scalar formatting

    static func scalarString(_ v: Any) -> String {
        switch v {
        case let s as String: return "\"\(escapeJSONString(s))\""
        case let n as NSNumber:
            if n === kCFBooleanTrue  { return "true"  }
            if n === kCFBooleanFalse { return "false" }
            return n.stringValue
        case is NSNull: return "null"
        case let obj as [String: Any]:
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: .sortedKeys),
               let s = String(data: d, encoding: .utf8) { return s }
            return "{…}"
        case let arr as [Any]:
            if let d = try? JSONSerialization.data(withJSONObject: arr),
               let s = String(data: d, encoding: .utf8) { return s }
            return "[…]"
        default: return "\(v)"
        }
    }

    /// Escapes special characters in a string for valid JSON representation.
    private static func escapeJSONString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.asciiValue.map({ $0 < 0x20 }) == true {
                    out += String(format: "\\u%04x", ch.asciiValue!)
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }

    // MARK: UUID field detection

    /// Searches left and right object arrays for a field that holds UUID values in every object.
    /// Avoids concatenating the two arrays.
    private static func findUUIDField(left: [[String: Any]], right: [[String: Any]]) -> String? {
        guard let first = left.first ?? right.first else { return nil }
        let preferred = ["id", "ID", "uuid", "UUID", "_id", "identifier", "key", "ref", "userId", "user_id"]
        let candidates = preferred + first.keys.sorted()
        for field in candidates {
            let leftOK  = left.allSatisfy  { ($0[field] as? String).map(isLikelyUUID) == true }
            let rightOK = right.allSatisfy { ($0[field] as? String).map(isLikelyUUID) == true }
            if leftOK && rightOK { return field }
        }
        return nil
    }

    private static func buildIDMap(objects: [[String: Any]], field: String) -> [String: [String: Any]] {
        Dictionary(objects.compactMap { obj -> (String, [String: Any])? in
            guard let uid = obj[field] as? String else { return nil }
            return (uid.lowercased(), obj)
        }, uniquingKeysWith: { first, _ in first })
    }

    private static func appendID(from obj: [String: Any], field: String,
                                  into list: inout [String], seen: inout Set<String>) {
        guard let uid = (obj[field] as? String)?.lowercased(), !seen.contains(uid) else { return }
        list.append(uid); seen.insert(uid)
    }

    private static func makeArrayHeader(key: String?, depth: Int, leftCount: Int, rightCount: Int,
                                        hasChanges: Bool, extra: String?) -> DiffRow {
        let lSummary = "[ \(leftCount) \(leftCount == 1 ? "item" : "items") ]"
        let rSummary = "[ \(rightCount) \(rightCount == 1 ? "item" : "items") ]"
        var hint: String? = nil
        if leftCount != rightCount {
            let delta = rightCount - leftCount
            hint = "Δ \(delta > 0 ? "+" : "")\(delta) items"
            if let ex = extra { hint! += "  ·  \(ex)" }
        } else if let ex = extra {
            hint = ex
        }
        return DiffRow(building: depth, key: key,
                       status: hasChanges ? .containerChanged : .containerClean,
                       leftText: lSummary, rightText: rSummary,
                       isContainer: true, isFocusPoint: false, hint: hint)
    }
}

// MARK: - ArraySlice convenience (avoids scanning full array from start)

private extension ArraySlice where Element == DiffRow {
    var hasChanges: Bool {
        contains { $0.isFocusPoint || $0.status == .containerChanged }
    }
}
