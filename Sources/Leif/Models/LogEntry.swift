import Foundation
import SwiftUI

enum LogLevel: String, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
    case fatal = "FATAL"
    case dpanic = "DPANIC"
    case panic = "PANIC"
    case unknown = "?"

    private static let lookup: [String: LogLevel] = Dictionary(
        uniqueKeysWithValues: LogLevel.allCases.map { ($0.rawValue, $0) }
    )

    init(raw: String) {
        self = LogLevel.lookup[raw.uppercased()] ?? .unknown
    }

    var color: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .blue
        case .warn: return Color.orange
        case .error, .fatal, .dpanic, .panic: return .red
        case .unknown: return .primary
        }
    }

    /// Darker variant for light mode where the default colors are too faint
    var darkColor: Color {
        switch self {
        case .debug: return Color(nsColor: .darkGray)
        case .info: return Color(red: 0.0, green: 0.35, blue: 0.85)
        case .warn: return Color(red: 0.75, green: 0.4, blue: 0.0)
        case .error, .fatal, .dpanic, .panic: return Color(red: 0.75, green: 0.1, blue: 0.1)
        case .unknown: return .primary
        }
    }

    var badge: String {
        switch self {
        case .debug: return "DBG"
        case .info: return "INF"
        case .warn: return "WRN"
        case .error: return "ERR"
        case .fatal: return "FTL"
        case .dpanic: return "DPN"
        case .panic: return "PNC"
        case .unknown: return "???"
        }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let lineIndex: Int
    let k8sTimestamp: String?   // CRI outer timestamp
    let appTimestamp: String?   // Zapper/app inner timestamp (ms portion shown)
    let level: LogLevel
    let caller: String?
    let message: String
    let fields: OrderedFields?  // JSON fields from payload
    let rawContent: String      // Reconstructed full log content line
    let displayTimestamp: String // Pre-computed once at parse time

    init(lineIndex: Int, k8sTimestamp: String?, appTimestamp: String?,
         level: LogLevel, caller: String?, message: String,
         fields: OrderedFields?, rawContent: String) {
        self.lineIndex      = lineIndex
        self.k8sTimestamp   = k8sTimestamp
        self.appTimestamp   = appTimestamp
        self.level          = level
        self.caller         = caller
        self.message        = message
        self.fields         = fields
        self.rawContent     = rawContent
        // Extract HH:mm:ss.SSS after the 'T' — no regex, just index arithmetic
        let ts = appTimestamp ?? k8sTimestamp ?? ""
        if let tIdx = ts.firstIndex(of: "T") {
            let start = ts.index(after: tIdx)
            let end   = ts.index(start, offsetBy: 12, limitedBy: ts.endIndex) ?? ts.endIndex
            self.displayTimestamp = String(ts[start..<end])
        } else {
            self.displayTimestamp = ts
        }
    }

    var hasPayload: Bool { fields != nil && !fields!.pairs.isEmpty }
}

// Preserves insertion order while allowing keyed access
struct OrderedFields {
    struct Pair: Identifiable {
        let id = UUID()
        let key: String
        let value: Any
    }
    var pairs: [Pair]

    init(_ dict: [String: Any]) {
        // Sort keys so output is stable across platforms
        pairs = dict.keys.sorted().map { Pair(key: $0, value: dict[$0]!) }
    }

    subscript(key: String) -> Any? {
        pairs.first(where: { $0.key == key })?.value
    }
}
