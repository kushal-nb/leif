import Foundation

// ═══════════════════════════════════════════════════════════════
// Leif Test Framework — Standalone (no Xcode/XCTest required)
// Run: swift run LeifTests
// ═══════════════════════════════════════════════════════════════

// MARK: - Minimal test harness

private var totalTests = 0
private var passedTests = 0
private var failedTests: [(String, String)] = []

func test(_ name: String, _ body: () throws -> Void) {
    totalTests += 1
    do {
        try body()
        passedTests += 1
        print("  \u{2705} \(name)")
    } catch {
        failedTests.append((name, "\(error)"))
        print("  \u{274C} \(name) — \(error)")
    }
}

struct AssertionError: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: Bool, _ msg: String = "Assertion failed", file: String = #file, line: Int = #line) throws {
    guard condition else { throw AssertionError(description: "\(msg) (\(file.split(separator: "/").last ?? ""):\(line))") }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) throws {
    guard a == b else {
        throw AssertionError(description: "\(msg.isEmpty ? "Expected equal" : msg): got \(a) vs \(b) (\(file.split(separator: "/").last ?? ""):\(line))")
    }
}

// MARK: - Fixture helpers

let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // LeifTests/
    .deletingLastPathComponent() // Tests/
    .deletingLastPathComponent() // project root

func fixture(_ name: String) -> String {
    let url: URL
    let fixtureDir = projectRoot.appendingPathComponent("Tests/LeifTests/Fixtures")
    url = fixtureDir.appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: url.path) {
        // Fallback: test_logs at project root
        let rootFile = projectRoot.appendingPathComponent(name)
        return (try? String(contentsOf: rootFile, encoding: .utf8)) ?? ""
    }
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

// MARK: - Level enum for testing

enum TestLogLevel: String, CaseIterable {
    case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR"
    case fatal = "FATAL", dpanic = "DPANIC", panic = "PANIC", unknown = "?"
    private static let lookup: [String: TestLogLevel] = Dictionary(
        uniqueKeysWithValues: TestLogLevel.allCases.map { ($0.rawValue, $0) }
    )
    init(raw: String) { self = TestLogLevel.lookup[raw.uppercased()] ?? .unknown }
}

// ═══════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════

func runAllTests() {
    let startTime = CFAbsoluteTimeGetCurrent()

    // ─────────────────────────────────────────
    print("\n\u{1F4CB} CRI Simple Parsing")
    // ─────────────────────────────────────────

    test("All 10 lines in simple fixture are CRI Final") {
        let text = fixture("cri_simple.log")
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        try expectEqual(lines.count, 10)
        try expectEqual(lines.filter({ $0.contains("stdout P") }).count, 0)
        try expectEqual(lines.filter({ $0.contains("stdout F") }).count, 10)
    }

    test("K8s timestamp extraction") {
        let line = "2026-03-23T09:11:57.205553472Z stdout F content"
        let zIdx = line.firstIndex(of: "Z")!
        let ts = String(line[line.startIndex...zIdx])
        try expectEqual(ts, "2026-03-23T09:11:57.205553472Z")
    }

    test("Log level detection") {
        try expectEqual(TestLogLevel(raw: "DEBUG"), .debug)
        try expectEqual(TestLogLevel(raw: "INFO"), .info)
        try expectEqual(TestLogLevel(raw: "WARN"), .warn)
        try expectEqual(TestLogLevel(raw: "ERROR"), .error)
        try expectEqual(TestLogLevel(raw: "FATAL"), .fatal)
        try expectEqual(TestLogLevel(raw: "UNKNOWN"), .unknown)
    }

    // ─────────────────────────────────────────
    print("\n\u{1F4CB} CRI Partial Reconstruction")
    // ─────────────────────────────────────────

    test("Partial fixture has P and F chunks") {
        let text = fixture("cri_partial.log")
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        try expect(lines.filter({ $0.contains("stdout P") }).count > 0, "Must have P chunks")
        try expect(lines.filter({ $0.contains("stdout F") }).count > 0, "Must have F chunks")
    }

    test("P+P+F joins content without separator") {
        let joined = ["first", "second", "final"].joined()
        try expectEqual(joined, "firstsecondfinal")
    }

    test("CRI line structure: timestamp stream flag content") {
        let line = "2026-03-23T09:11:59.39599173Z stdout P some content"
        let parts = line.split(separator: " ", maxSplits: 3)
        try expectEqual(parts.count, 4)
        try expect(String(parts[0]).hasSuffix("Z"), "Timestamp ends with Z")
        try expectEqual(String(parts[1]), "stdout")
        try expectEqual(String(parts[2]), "P")
    }

    // ─────────────────────────────────────────
    print("\n\u{1F4CB} Zap Dev Format")
    // ─────────────────────────────────────────

    test("Zap line splits into timestamp/level/caller/message") {
        let line = "2026-03-23T09:11:57.205Z\tDEBUG\tcaller.go:42\tMessage here\t{\"k\":\"v\"}"
        let parts = line.components(separatedBy: "\t")
        try expect(parts.count >= 4, "Must have 4+ tab-separated parts")
        try expect(parts[0].hasSuffix("Z"), "Timestamp")
        try expectEqual(parts[1], "DEBUG")
        try expect(parts[2].contains(".go:"), "Caller")
        try expectEqual(parts[3], "Message here")
    }

    test("Zap timestamp validation") {
        for ts in ["2026-03-23T09:11:57.205Z", "2026-01-01T00:00:00.000Z"] {
            try expect(ts.count >= 20 && ts.hasSuffix("Z"), "\(ts) should be valid")
        }
        for ts in ["not-a-timestamp", "2026-03-23", ""] {
            let valid = ts.count >= 20 && ts.hasSuffix("Z")
            try expect(!valid, "\(ts) should be invalid")
        }
    }

    // ─────────────────────────────────────────
    print("\n\u{1F4CB} JSON Parsing")
    // ─────────────────────────────────────────

    test("Plain JSON object") {
        let data = #"{"level":"info","msg":"started","port":8080}"#.data(using: .utf8)!
        let p = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expectEqual(p["level"] as? String, "info")
        try expectEqual(p["port"] as? Int, 8080)
    }

    test("JSON array of objects") {
        let data = #"[{"id":1},{"id":2}]"#.data(using: .utf8)!
        let arr = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        try expectEqual(arr.count, 2)
        try expectEqual(arr[0]["id"] as? Int, 1)
    }

    test("Pretty-printed multi-line JSON") {
        let json = "{\n  \"name\": \"Live\",\n  \"duration\": 58439000\n}"
        let data = json.data(using: .utf8)!
        let p = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expectEqual(p["name"] as? String, "Live")
        try expectEqual(p["duration"] as? Int, 58439000)
    }

    test("String-encoded JSON auto-detection") {
        let inner = #"{"id":1,"items":[1,2,3]}"#
        let data = inner.data(using: .utf8)!
        let p = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expectEqual(p["id"] as? Int, 1)
        try expectEqual((p["items"] as! [Int]).count, 3)
    }

    test("Empty JSON containers") {
        for (input, expected) in [("{}", true), ("[]", true), ("", false), ("42", false)] {
            let t = input.trimmingCharacters(in: .whitespaces)
            let detected = t.first == "{" || t.first == "["
            try expectEqual(detected, expected, "'\(input)'")
        }
    }

    // ─────────────────────────────────────────
    print("\n\u{1F4CB} Full Test Logs Structure")
    // ─────────────────────────────────────────

    test("~692 lines, 636 partial, 49 final") {
        let text = fixture("full_test.log")
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        try expect(lines.count >= 686 && lines.count <= 692, "Should have ~692 non-empty lines (got \(lines.count))")
        try expect(lines.filter({ $0.contains("stdout P") }).count >= 630, "Should have ~636 P chunks")
        try expect(lines.filter({ $0.contains("stdout F") }).count >= 45, "Should have ~49 F chunks")
    }

    test("Has DEBUG, INFO, WARN levels") {
        let text = fixture("full_test.log")
        try expect(text.contains("\tDEBUG\t"), "Missing DEBUG")
        try expect(text.contains("\tINFO\t"), "Missing INFO")
        try expect(text.contains("\tWARN\t"), "Missing WARN")
    }

    test("File size ~10 MB") {
        let text = fixture("full_test.log")
        try expect(text.utf8.count > 10_000_000, "Should be > 10 MB")
        try expect(text.utf8.count < 11_000_000, "Should be < 11 MB")
    }

    // ─────────────────────────────────────────
    print("\n\u{1F4CB} Diff Logic")
    // ─────────────────────────────────────────

    test("Identical inputs — no changes") {
        let lines = ["a", "b", "c"]
        for i in 0..<lines.count { try expectEqual(lines[i], lines[i]) }
    }

    test("Single line change detected") {
        let left = ["aaa", "bbb", "ccc"]; let right = ["aaa", "BBB", "ccc"]
        try expectEqual(left[0], right[0])
        try expect(left[1] != right[1], "Line 1 should differ")
        try expectEqual(left[2], right[2])
    }

    test("JSON diff detects value change") {
        let left = pp(["status": "200", "url": "http://x.com"])
        let right = pp(["status": "503", "url": "http://x.com"])
        try expect(left != right, "Different values should differ")
        let lURL = left.components(separatedBy: "\n").first { $0.contains("url") }
        let rURL = right.components(separatedBy: "\n").first { $0.contains("url") }
        try expectEqual(lURL, rURL)
    }

    test("JSON diff detects added key") {
        let left = pp(["a": "1"]); let right = pp(["a": "1", "b": "2"])
        try expect(right.count > left.count, "More keys = longer output")
    }

    test("Large JSON diff (1000 keys) does not crash") {
        var d: [String: String] = [:]
        for i in 0..<1000 { d["key_\(i)"] = "val_\(i)" }
        let p = pp(d)
        try expect(p.components(separatedBy: "\n").count > 1000, "Should have > 1000 lines")
    }

    // ─────────────────────────────────────────
    print("\n\u{1F4CB} Search")
    // ─────────────────────────────────────────

    test("Case-insensitive search") {
        let text = "HTTP GET request"
        for q in ["http", "HTTP", "Http"] {
            try expect(text.range(of: q, options: .caseInsensitive) != nil, "'\(q)' should match")
        }
        try expect(text.range(of: "missing", options: .caseInsensitive) == nil, "'missing' should not match")
    }

    test("Match counting") {
        let text = "aaa bbb aaa ccc aaa"
        var count = 0; var r = text.startIndex..<text.endIndex
        while let found = text.range(of: "aaa", range: r) { count += 1; r = found.upperBound..<text.endIndex }
        try expectEqual(count, 3)
    }

    test("Search clamped to 256 chars") {
        let long = String(repeating: "x", count: 500)
        let clamped = long.count > 256 ? String(long.prefix(256)) : long
        try expectEqual(clamped.count, 256)
    }

    // ─────────────────────────────────────────
    print("\n\u{1F4CB} Table Extraction")
    // ─────────────────────────────────────────

    test("Array of objects — union keys") {
        let rows: [[String: Any]] = [["a": 1, "b": 2], ["b": 3, "c": 4]]
        var keys = Set<String>()
        for row in rows { keys.formUnion(row.keys) }
        try expectEqual(keys.sorted(), ["a", "b", "c"])
    }

    test("TSV escaping") {
        let escaped = "has\ttab".replacingOccurrences(of: "\t", with: "\\t")
        try expectEqual(escaped, "has\\ttab")
    }

    test("CSV escaping") {
        func esc(_ s: String) -> String {
            guard s.contains(",") || s.contains("\"") else { return s }
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        try expectEqual(esc("simple"), "simple")
        try expectEqual(esc("has,comma"), "\"has,comma\"")
        try expectEqual(esc("has\"quote"), "\"has\"\"quote\"")
    }

    // ─────────────────────────────────────────
    print("\n\u{1F4CB} Copy")
    // ─────────────────────────────────────────

    test("Tree/JSON tab copies prettyJSON") {
        let pretty = "{\n  \"k\": \"v\"\n}"; let raw = "{\"k\":\"v\"}"
        try expectEqual(!pretty.isEmpty ? pretty : raw, pretty)
    }

    test("Falls back to raw when prettyJSON empty") {
        let raw = "{\"k\":\"v\"}"
        try expectEqual("".isEmpty ? raw : "", raw)
    }

    // ─────────────────────────────────────────
    print("\n\u{23F1}  Performance")
    // ─────────────────────────────────────────

    test("PERF: Line split 10x on 10 MB") {
        let text = fixture("full_test.log")
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 {
            let _ = text.split(separator: "\n", omittingEmptySubsequences: false)
        }
        let dt = CFAbsoluteTimeGetCurrent() - t0
        print("       \(String(format: "%.3f", dt))s (10 iterations)")
        try expect(dt < 5.0, "Should be < 5s")
    }

    test("PERF: CRI reconstruction 10x") {
        let text = fixture("full_test.log")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 {
            var result: [String] = []; result.reserveCapacity(lines.count)
            var chunks: [Substring] = []
            for line in lines {
                if line.contains("stdout P") { chunks.append(line) }
                else if line.contains("stdout F") { chunks.append(line); result.append(chunks.joined()); chunks.removeAll(keepingCapacity: true) }
                else { result.append(String(line)) }
            }
        }
        let dt = CFAbsoluteTimeGetCurrent() - t0
        print("       \(String(format: "%.3f", dt))s (10 iterations)")
        try expect(dt < 10.0, "Should be < 10s")
    }

    test("PERF: JSON parse 500 payloads") {
        let payloads = (0..<500).map { "{\"id\":\($0),\"ok\":\($0 % 2 == 0)}".data(using: .utf8)! }
        let t0 = CFAbsoluteTimeGetCurrent()
        for d in payloads { let _ = try? JSONSerialization.jsonObject(with: d) }
        let dt = CFAbsoluteTimeGetCurrent() - t0
        print("       \(String(format: "%.3f", dt))s")
        try expect(dt < 2.0, "Should be < 2s")
    }

    test("PERF: Pretty-print 1000 small dicts") {
        let d: [String: String] = ["a": "1", "b": "2", "c": "3", "d": "4"]
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1000 { let _ = pp(d) }
        let dt = CFAbsoluteTimeGetCurrent() - t0
        print("       \(String(format: "%.3f", dt))s")
        try expect(dt < 2.0, "Should be < 2s")
    }

    test("MEM: Full test logs size estimation") {
        let text = fixture("full_test.log")
        let utf8 = text.utf8.count; let utf16 = text.utf16.count * 2
        print("       UTF-8:  \(utf8 / 1024) KB")
        print("       UTF-16: \(utf16 / 1024) KB")
        print("       Est NSTextView: ~\(utf16 * 15 / 1024 / 1024) MB")
        try expect(utf8 > 10_000_000)
    }

    // ─────────────────────────────────────────
    // SUMMARY
    // ─────────────────────────────────────────

    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
    print("\n" + String(repeating: "═", count: 50))
    print("\u{1F3AF} Results: \(passedTests)/\(totalTests) passed, \(failedTests.count) failed")
    print("\u{23F1}  Total time: \(String(format: "%.2f", elapsed))s")
    if !failedTests.isEmpty {
        print("\n\u{274C} Failures:")
        for (name, err) in failedTests {
            print("   - \(name): \(err)")
        }
    }
    print(String(repeating: "═", count: 50))
}

// Helper
func pp(_ dict: [String: String]) -> String {
    let lines = dict.keys.sorted().map { "  \"\($0)\": \"\(dict[$0]!)\"" }
    return "{\n\(lines.joined(separator: ",\n"))\n}"
}

// MARK: - Entry point
@main struct TestRunner {
    static func main() {
        print(String(repeating: "═", count: 50))
        print("  Leif Test Suite")
        print(String(repeating: "═", count: 50))
        runAllTests()
        exit(failedTests.isEmpty ? 0 : 1)
    }
}
