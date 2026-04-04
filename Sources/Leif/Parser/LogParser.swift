import Foundation

// MARK: - CRI chunk type
private struct CRILine {
    let k8sTimestamp: String
    let isPartial: Bool   // true = P, false = F
    let content: String
}

// MARK: - Parser
final class LogParser {

    private static let levelWords    = Set(["DEBUG","INFO","WARN","WARNING","ERROR","FATAL","DPANIC","PANIC"])
    // Compiled once — reused across all lines on all threads (NSRegularExpression is thread-safe for matching)
    private static let zapperSplitter = try! NSRegularExpression(pattern: #"\t|    +"#)

    // Loki header regex — only invoked after isLokiHeaderCandidate() passes the fast pre-check
    private static let lokiHeaderRE = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?)\s*(\{[^}]*\})?\s*$"#)

    func parse(text: String) -> [LogEntry] {
        // Pretty-printed JSON is one logical value across many lines; avoid per-line work.
        if let whole = parseWholeJSONDocumentIfPresent(text) { return whole }

        // split returns Substrings — zero-copy views into `text`, no line copies at this stage
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // Single pass: Loki 2-line reconstruction + CRI P/F merging
        let reconstructed = reconstructLines(rawLines)
        // Parse every line independently on all available cores.
        var results = [LogEntry?](repeating: nil, count: reconstructed.count)
        results.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: reconstructed.count) { i in
                // reconstructLines already trimmed — no redundant trim here
                let line = reconstructed[i]
                guard !line.isEmpty else { return }
                buf[i] = parseSingleLine(line, index: i)
            }
        }
        return results.compactMap { $0 }
    }

    /// Single `JSONSerialization` pass when the trimmed buffer is one JSON object or array
    /// (e.g. pretty-printed across 200k lines). Returns `nil` to fall back to line-oriented parsing.
    private func parseWholeJSONDocumentIfPresent(_ text: String) -> [LogEntry]? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") { trimmed.removeFirst() }
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.first == "{" || trimmed.first == "[" else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let dict = root as? [String: Any] {
            return [logEntryFromJSONDict(dict, lineIndex: 0, k8sTS: nil, rawContent: text)]
        }
        if let arr = root as? [Any] {
            if arr.isEmpty {
                return [LogEntry(lineIndex: 0, k8sTimestamp: nil, appTimestamp: nil,
                                 level: .unknown, caller: nil, message: "JSON array (empty)",
                                 fields: nil, rawContent: text)]
            }
            let dicts = arr.compactMap { $0 as? [String: Any] }
            if dicts.count == arr.count {
                return dicts.enumerated().map { i, json in
                    let raw: String
                    if let d = try? JSONSerialization.data(withJSONObject: json, options: []),
                       let s = String(data: d, encoding: .utf8) {
                        raw = s
                    } else {
                        raw = "{}"
                    }
                    return logEntryFromJSONDict(json, lineIndex: i, k8sTS: nil, rawContent: raw)
                }
            }
            return [LogEntry(lineIndex: 0, k8sTimestamp: nil, appTimestamp: nil,
                             level: .unknown, caller: nil,
                             message: "JSON array (\(arr.count) items)",
                             fields: nil, rawContent: text)]
        }
        return nil
    }

    // MARK: Single-pass reconstruction (Loki 2-line + CRI P/F merging)

    // Fast pre-check: Loki headers always start with a year digit (1xxx or 2xxx) + dash at 4.
    // Avoids running lokiHeaderRE on lines that can't possibly be headers.
    private static func isLokiHeaderCandidate(_ t: String) -> Bool {
        let u = t.utf8
        guard u.count >= 10 else { return false }
        let b = u.startIndex
        let c0 = u[b]
        return (c0 == UInt8(ascii: "1") || c0 == UInt8(ascii: "2"))
            && u[u.index(b, offsetBy: 4)] == UInt8(ascii: "-")
    }

    private func reconstructLines(_ rawLines: [Substring]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(rawLines.count)

        // Loki state
        var pendingLokiTS: String? = nil
        // CRI partial state
        var partialChunks: [String] = []
        var partialK8sTS:   String? = nil
        var partialOuterTS: String? = nil

        func flushPartial() {
            guard !partialChunks.isEmpty else { return }
            result.append(partialChunks.joined())
            partialChunks.removeAll(keepingCapacity: true)
            partialK8sTS   = nil
            partialOuterTS = nil
        }

        for raw in rawLines {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }

            // --- Loki 2-line format ---
            // Header line carries the timestamp; next line is the actual content.
            var outerTS: String? = nil
            if let lts = pendingLokiTS {
                outerTS = lts
                pendingLokiTS = nil
            } else if Self.isLokiHeaderCandidate(t) {
                let ns = t as NSString
                if let m = Self.lokiHeaderRE.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) {
                    pendingLokiTS = ns.substring(with: m.range(at: 1))
                    continue    // consume header line, don't emit it
                }
            }

            // --- CRI P/F reconstruction (manual byte parser, no regex) ---
            if let cri = Self.matchCRIFast(t) {
                if cri.isPartial {
                    if partialChunks.isEmpty {
                        partialK8sTS   = cri.k8sTimestamp
                        partialOuterTS = outerTS
                    }
                    partialChunks.append(cri.content)
                } else {
                    // Final chunk — join all partial pieces in one pass
                    partialChunks.append(cri.content)
                    let full = partialChunks.joined()
                    partialChunks.removeAll(keepingCapacity: true)
                    let k8sTs = partialK8sTS ?? cri.k8sTimestamp
                    partialK8sTS = nil
                    let finalOuterTS = partialOuterTS ?? outerTS ?? k8sTs
                    partialOuterTS = nil
                    result.append("__CRI_TS__\(finalOuterTS)__SEP__\(full)")
                }
            } else {
                // Not CRI — flush any pending partial (malformed logs), then emit
                flushPartial()
                if let ts = outerTS {
                    result.append("__CRI_TS__\(ts)__SEP__\(t)")
                } else {
                    result.append(t)
                }
            }
        }
        flushPartial()
        return result
    }

    // MARK: Fast manual CRI parser — zero regex, pure byte scan
    // CRI line format: <timestamp>Z <stdout|stderr> <P|F> [content]
    // Everything before content is pure ASCII → UTF-8 byte offset == character offset.
    private static func matchCRIFast(_ line: String) -> CRILine? {
        let u = line.utf8
        let count = u.count
        guard count >= 28 else { return nil }   // minimum viable CRI line length

        let b = u.startIndex
        // Structural timestamp pre-check at fixed byte positions
        guard u[u.index(b, offsetBy:  4)] == UInt8(ascii: "-"),
              u[u.index(b, offsetBy:  7)] == UInt8(ascii: "-"),
              u[u.index(b, offsetBy: 10)] == UInt8(ascii: "T"),
              u[u.index(b, offsetBy: 13)] == UInt8(ascii: ":"),
              u[u.index(b, offsetBy: 16)] == UInt8(ascii: ":") else { return nil }

        // Scan for 'Z' ending the timestamp (expected between offsets 19..29)
        var i = u.index(b, offsetBy: 19)
        let maxTSEnd = u.index(b, offsetBy: min(29, count - 1))
        while i <= maxTSEnd, u[i] != UInt8(ascii: "Z") { u.formIndex(after: &i) }
        guard i <= maxTSEnd else { return nil }
        u.formIndex(after: &i)  // move past 'Z'
        let tsLen = u.distance(from: b, to: i)
        let tsStr = String(line.prefix(tsLen))

        // Skip whitespace after timestamp
        while i < u.endIndex, u[i] == UInt8(ascii: " ") || u[i] == UInt8(ascii: "\t") { u.formIndex(after: &i) }
        guard i < u.endIndex else { return nil }

        // Match "stdout" or "stderr" — both exactly 6 bytes
        guard u.distance(from: i, to: u.endIndex) >= 7 else { return nil }
        let streamEnd = u.index(i, offsetBy: 6)
        let stream = u[i..<streamEnd]
        guard stream.elementsEqual("stdout".utf8) || stream.elementsEqual("stderr".utf8) else { return nil }
        i = streamEnd

        // Skip whitespace
        while i < u.endIndex, u[i] == UInt8(ascii: " ") || u[i] == UInt8(ascii: "\t") { u.formIndex(after: &i) }
        guard i < u.endIndex else { return nil }

        // Match P or F
        let flag = u[i]
        guard flag == UInt8(ascii: "P") || flag == UInt8(ascii: "F") else { return nil }
        let isPartial = flag == UInt8(ascii: "P")
        u.formIndex(after: &i)

        // Skip optional whitespace after P/F flag
        while i < u.endIndex, u[i] == UInt8(ascii: " ") || u[i] == UInt8(ascii: "\t") { u.formIndex(after: &i) }

        // Everything remaining is content.
        // CRI prefix is pure ASCII → byte offset == character offset → dropFirst is safe.
        let contentOffset = u.distance(from: b, to: i)
        let content = contentOffset < count ? String(line.dropFirst(contentOffset)) : ""
        return CRILine(k8sTimestamp: tsStr, isPartial: isPartial, content: content)
    }

    // MARK: Single line parsing
    private static let criTSPrefix = "__CRI_TS__"
    private static let criSep      = "__SEP__"

    private func parseSingleLine(_ line: String, index: Int) -> LogEntry {
        var k8sTS: String? = nil
        var workLine = line
        if line.hasPrefix(Self.criTSPrefix) {
            let after = line[line.index(line.startIndex, offsetBy: Self.criTSPrefix.count)...]
            if let s = after.range(of: Self.criSep) {
                k8sTS    = String(after[after.startIndex..<s.lowerBound])
                workLine = String(after[s.upperBound...])
            }
        }
        if let entry = parseZapper(workLine, index: index, k8sTS: k8sTS) { return entry }
        if let entry = parseJSON(workLine, index: index, k8sTS: k8sTS)   { return entry }
        return LogEntry(lineIndex: index, k8sTimestamp: k8sTS, appTimestamp: nil,
                        level: .unknown, caller: nil, message: workLine, fields: nil, rawContent: workLine)
    }

    // MARK: Zapper dev-format parser
    // Format: <ts>    <LEVEL>    <caller>    <message>    <optional JSON>
    private func parseZapper(_ line: String, index: Int, k8sTS: String?) -> LogEntry? {
        let splitter = Self.zapperSplitter
        let ns = line as NSString
        let nsRange = NSRange(location: 0, length: ns.length)
        var parts: [String] = []
        var lastEnd = 0
        for m in splitter.matches(in: line, range: nsRange) {
            let partRange = NSRange(location: lastEnd, length: m.range.location - lastEnd)
            let part = ns.substring(with: partRange).trimmingCharacters(in: .whitespaces)
            if !part.isEmpty { parts.append(part) }
            lastEnd = m.range.location + m.range.length
        }
        let tail = ns.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }

        guard parts.count >= 2 else { return nil }
        guard isZapTimestamp(parts[0]) else { return nil }
        let appTS = parts[0]

        let levelStr = parts[1].uppercased()
        guard Self.levelWords.contains(levelStr) else { return nil }
        let level = LogLevel(raw: levelStr)

        var idx = 2
        var caller: String? = nil
        if idx < parts.count && looksLikeCaller(parts[idx]) { caller = parts[idx]; idx += 1 }
        guard idx < parts.count else { return nil }

        let rest = parts[idx...].joined(separator: "    ")
        let (message, fields) = splitMessageAndJSON(rest)
        return LogEntry(lineIndex: index, k8sTimestamp: k8sTS, appTimestamp: appTS, level: level,
                        caller: caller, message: message,
                        fields: fields.map { OrderedFields($0) }, rawContent: line)
    }

    // MARK: Plain JSON parser
    private func logEntryFromJSONDict(_ json: [String: Any], lineIndex: Int, k8sTS: String?, rawContent: String) -> LogEntry {
        // "ts" may be a Unix float (Zap production encoder) or an ISO string (Zap dev encoder)
        let appTS: String?
        if let tsStr = json["ts"] as? String {
            appTS = tsStr
        } else if let tsNum = json["ts"] as? Double {
            appTS = Self.unixToISO(tsNum)
        } else {
            appTS = (json["timestamp"] as? String) ?? (json["time"] as? String)
        }
        let msg    = (json["msg"] as? String) ?? (json["message"] as? String) ?? ""
        let lvl    = (json["level"] as? String) ?? (json["lvl"] as? String) ?? "?"
        let caller = json["caller"] as? String
        return LogEntry(lineIndex: lineIndex, k8sTimestamp: k8sTS, appTimestamp: appTS,
                        level: LogLevel(raw: lvl), caller: caller, message: msg,
                        fields: OrderedFields(json), rawContent: rawContent)
    }

    private func parseJSON(_ line: String, index: Int, k8sTS: String?) -> LogEntry? {
        guard line.hasPrefix("{") else { return nil }
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return logEntryFromJSONDict(json, lineIndex: index, k8sTS: k8sTS, rawContent: line)
    }

    // Convert Unix epoch (Double) → "2026-03-23T09:11:59.376Z".
    // Uses gmtime_r (re-entrant, thread-safe) — safe inside concurrentPerform.
    private static func unixToISO(_ unix: Double) -> String {
        var t  = time_t(unix)
        var tm = tm()
        gmtime_r(&t, &tm)
        let ms = Int((unix - floor(unix)) * 1000)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                      tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                      tm.tm_hour, tm.tm_min, tm.tm_sec, ms)
    }

    // MARK: Helpers

    // O(1) structural check — no regex.
    // Zap timestamp: 2026-03-03T19:01:59.053Z
    private func isZapTimestamp(_ s: String) -> Bool {
        let b = s.utf8
        guard b.count >= 20 else { return false }
        let i = b.startIndex
        return b[b.index(i, offsetBy:  4)] == UInt8(ascii: "-")
            && b[b.index(i, offsetBy:  7)] == UInt8(ascii: "-")
            && b[b.index(i, offsetBy: 10)] == UInt8(ascii: "T")
            && b[b.index(i, offsetBy: 13)] == UInt8(ascii: ":")
            && b[b.index(i, offsetBy: 16)] == UInt8(ascii: ":")
            && b[b.index(b.endIndex, offsetBy: -1)] == UInt8(ascii: "Z")
    }

    private func looksLikeCaller(_ s: String) -> Bool {
        return s.contains(".go:") || s.contains(".swift:") || s.contains(".ts:") ||
               (s.contains("/") && s.contains(":") && !s.hasPrefix("http"))
    }

    /// Split "message text    {\"key\":\"val\"}" into (message, json?)
    func splitMessageAndJSON(_ text: String) -> (String, [String: Any]?) {
        guard let jsonStart = findOutermostJSONObjectStart(in: text) else {
            return (text.trimmingCharacters(in: .whitespaces), nil)
        }
        let jsonStr = String(text[jsonStart...])
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (text.trimmingCharacters(in: .whitespaces), nil)
        }
        let msg = String(text[..<jsonStart]).trimmingCharacters(in: .whitespaces)
        return (msg, json)
    }

    private func findOutermostJSONObjectStart(in text: String) -> String.Index? {
        // Iterate UTF-8 bytes instead of Unicode grapheme clusters — much faster for
        // JSON which is ASCII-structural. All matched chars ({, }, ", \) are single bytes.
        var depth = 0
        var inStr = false
        var esc = false
        var candidate: String.Index? = nil
        let u = text.utf8
        var i = u.startIndex

        while i < u.endIndex {
            let byte  = u[i]
            let here  = i           // save index before advancing
            u.formIndex(after: &i)
            if esc { esc = false; continue }
            if byte == UInt8(ascii: "\\") && inStr { esc = true; continue }
            if byte == UInt8(ascii: "\"") { inStr.toggle(); continue }
            if inStr { continue }
            if byte == UInt8(ascii: "{") {
                if depth == 0 { candidate = here }  // { is ASCII → valid String.Index
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                if depth > 0 { depth -= 1 }
            }
        }
        return candidate
    }
}
