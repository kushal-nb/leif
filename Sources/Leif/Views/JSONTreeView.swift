import SwiftUI

// MARK: - Inline search highlight helper
// Returns a Text with matching substrings highlighted in yellow.
private func treeHL(_ text: String, query: String, baseColor: Color, font: Font) -> Text {
    var attrStr = AttributedString(text)
    attrStr.foregroundColor = baseColor
    attrStr.font = font

    if !query.isEmpty {
        var start = attrStr.startIndex
        while start < attrStr.endIndex {
            guard let range = attrStr[start...].range(of: query, options: .caseInsensitive)
            else { break }
            attrStr[range].backgroundColor = Color.yellow.opacity(0.7)
            attrStr[range].foregroundColor = Color.black
            let next = range.upperBound
            guard next > start else { break }
            start = next
        }
    }
    return Text(attrStr)
}

// MARK: - JSON Tree / Table

struct JSONNodeView: View {
    let node: JSONNode
    let depth: Int
    let searchText: String
    @State private var expanded = false

    var body: some View {
        switch node {
        case .scalar(_, let key, let value, let type):
            ScalarRow(key: key, value: value, nodeType: type, depth: depth, searchText: searchText)

        case .object(_, let key, let children, let badge):
            CollapsibleRow(
                key: key,
                summary: "{ \(children.count) keys }",
                symbol: "curlybraces",
                badge: badge,
                depth: depth,
                searchText: searchText,
                expanded: $expanded
            ) {
                ForEach(children) { child in
                    JSONNodeView(node: child, depth: depth + 1, searchText: searchText)
                }
            }

        case .array(_, let key, let children):
            CollapsibleRow(
                key: key,
                summary: "[ \(children.count) items ]",
                symbol: "list.bullet",
                badge: nil,
                depth: depth,
                searchText: searchText,
                expanded: $expanded
            ) {
                ForEach(children) { child in
                    JSONNodeView(node: child, depth: depth + 1, searchText: searchText)
                }
            }
        }
    }
}

private struct CollapsibleRow<Content: View>: View {
    let key: String?
    let summary: String
    let symbol: String
    let badge: String?
    let depth: Int
    let searchText: String
    @Binding var expanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                indentSpacer
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 12)
                if let key = key {
                    treeHL(key, query: searchText, baseColor: .primary,
                           font: .system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Text(":")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12, design: .monospaced))
                }
                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }

            if expanded {
                content()
            }
        }
    }

    private var indentSpacer: some View {
        Spacer().frame(width: CGFloat(depth) * 16)
    }
}

private struct ScalarRow: View {
    let key: String?
    let value: String
    let nodeType: JSONNode.NodeType
    let depth: Int
    let searchText: String
    @State private var expanded = false
    @Environment(\.colorScheme) var colorScheme

    private static let longThreshold = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                Spacer().frame(width: CGFloat(depth) * 16 + 16)
                if let key = key {
                    treeHL(key, query: searchText, baseColor: .primary,
                           font: .system(size: 12, design: .monospaced))
                        .fixedSize()
                        .textSelection(.enabled)
                    Text(":")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12, design: .monospaced))
                }
                if isLong && !expanded {
                    HStack(spacing: 4) {
                        treeHL(previewValue, query: searchText, baseColor: valueColor,
                               font: .system(size: 12, design: .monospaced))
                            .lineLimit(1)
                        Button(action: { expanded = true }) {
                            Text("show all")
                                .font(.system(size: 10))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    treeHL(displayValue, query: searchText, baseColor: valueColor,
                           font: .system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(expanded ? nil : 3)
                    if isLong && expanded {
                        Button(action: { expanded = false }) {
                            Text("collapse")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
            }
        }
        .padding(.vertical, 1)
    }

    private var isLong: Bool { value.count > Self.longThreshold }

    private var displayValue: String {
        nodeType == .string ? "\"\(value)\"" : value
    }

    private var previewValue: String {
        let preview = String(value.prefix(Self.longThreshold))
        return nodeType == .string ? "\"\(preview)…\"" : "\(preview)…"
    }

    private var valueColor: Color {
        let dark = colorScheme == .dark
        switch nodeType {
        case .string:
            return dark ? Color(nsColor: .systemGreen).opacity(0.9)
                        : Color(red: 0.05, green: 0.42, blue: 0.12)
        case .number:
            return dark ? Color(nsColor: .systemBlue)
                        : Color(red: 0.0, green: 0.22, blue: 0.72)
        case .bool:
            return dark ? Color(nsColor: .systemOrange)
                        : Color(red: 0.60, green: 0.27, blue: 0.0)
        case .null:
            return .secondary
        }
    }
}

// MARK: - Full detail pane for a log entry

enum DetailTab: String {
    case tree  = "Tree"
    case table = "Table"
    case json  = "JSON"
    case raw   = "Raw"

    var color: Color {
        switch self {
        case .tree:  return Color(nsColor: .systemTeal)
        case .table: return Color(nsColor: .systemPurple)
        case .json:  return Color(nsColor: .systemGreen)
        case .raw:   return Color(nsColor: .systemOrange)
        }
    }

    var icon: String {
        switch self {
        case .tree:  return "tree"
        case .table: return "tablecells"
        case .json:  return "curlybraces"
        case .raw:   return "doc.plaintext"
        }
    }
}

/// Timestamp / caller chips so light mode doesn’t read as “floating” gray shadow text.
@ViewBuilder
private func detailMetaChip<Content: View>(
    colorScheme: ColorScheme,
    @ViewBuilder content: () -> Content
) -> some View {
    content()
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(colorScheme == .light ? Color.white : Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.12), lineWidth: 1)
        )
}

struct LogDetailView: View {
    let entry: LogEntry
    let cache: PayloadCache
    let searchText: String

    @State private var tab: DetailTab = .json
    @State private var copyMsg: String? = nil
    @State private var matchIndex = 0          // current match for JSON/Raw nav
    @State private var totalMatches = 0        // cached, recomputed only on actual input change
    @Environment(\.colorScheme) var colorScheme

    @State private var treeNodes:         [JSONNode]          = []
    @State private var arrayFields:       [ArrayField]        = []
    @State private var prettyJSON:        String              = ""
    @State private var highlightedJSON:   NSAttributedString  = NSAttributedString()
    @State private var isBuilding:        Bool                = false
    @State private var treeOmittedReason: String?           = nil

    // Count occurrences of searchText in the active text view
    private func countMatches(in text: String) -> Int {
        guard !searchText.isEmpty, !text.isEmpty else { return 0 }
        let ns = text as NSString
        let len = ns.length
        var count = 0, loc = 0
        while loc < len {
            let r = ns.range(of: searchText, options: .caseInsensitive,
                             range: NSRange(location: loc, length: len - loc))
            guard r.location != NSNotFound else { break }
            count += 1
            loc = r.location + max(1, r.length)
        }
        return count
    }

    // Called whenever tab, searchText, or prettyJSON changes — updates totalMatches once
    // instead of recomputing it on every render pass.
    private func recalcTotalMatches() {
        guard !searchText.isEmpty, tab == .json || tab == .raw else { totalMatches = 0; return }
        totalMatches = countMatches(in: tab == .raw ? entry.rawContent : prettyJSON)
    }

    private func nextMatch() {
        guard totalMatches > 0 else { return }
        matchIndex = (matchIndex + 1) % totalMatches
    }
    private func prevMatch() {
        guard totalMatches > 0 else { return }
        matchIndex = (matchIndex - 1 + totalMatches) % totalMatches
    }

    private var availableTabs: [DetailTab] {
        var tabs: [DetailTab] = [.tree]
        if !arrayFields.isEmpty { tabs.append(.table) }
        tabs += [.json, .raw]
        return tabs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            if entry.hasPayload {
                Divider()
                payloadView
            }
        }
        .onChange(of: entry.id)    { _ in isBuilding = true; tab = .json; matchIndex = 0; totalMatches = 0; treeOmittedReason = nil }
        .onChange(of: searchText)  { _ in matchIndex = 0; recalcTotalMatches() }
        .onChange(of: tab)         { _ in matchIndex = 0; recalcTotalMatches() }
        .task(id: entry.id) { await buildPayload() }
    }

    // MARK: - Background build with persistent cache
    private func buildPayload() async {
        // Cache is pre-warmed for all entries after parse — this should almost always be a hit.
        if let built = cache.get(entry.id) {
            treeNodes          = built.treeNodes
            arrayFields        = built.arrayFields
            prettyJSON         = built.prettyJSON
            highlightedJSON    = built.highlightedJSON
            treeOmittedReason  = built.treeOmittedReason
            isBuilding         = false
            recalcTotalMatches()
            return
        }

        // Cache miss (e.g. first-ever click before pre-warm reaches this entry).
        guard let built = await buildEntryPayload(entry) else { isBuilding = false; return }
        guard !Task.isCancelled else { return }

        cache.set(entry.id, built)
        treeNodes          = built.treeNodes
        arrayFields        = built.arrayFields
        prettyJSON         = built.prettyJSON
        highlightedJSON    = built.highlightedJSON
        treeOmittedReason  = built.treeOmittedReason
        isBuilding         = false
        recalcTotalMatches()
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(spacing: 0) {
            // Level-colored accent strip
            Rectangle()
                .fill(entry.level.color.opacity(colorScheme == .dark ? 0.55 : 0.65))
                .frame(height: 2)

            // Row 1: log meta + message
            HStack(spacing: 6) {
                LevelBadge(level: entry.level)
                if let ts = entry.appTimestamp {
                    Text(ts)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if let caller = entry.caller {
                    Text(caller)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(colorScheme == .dark
                            ? Color(nsColor: .systemTeal)
                            : Color(red: 0.0, green: 0.38, blue: 0.48))
                        .lineLimit(1)
                }
                Text(entry.message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                colorScheme == .dark
                    ? Color.white.opacity(0.04)
                    : entry.level.color.opacity(0.06)
            )

            // Row 2: tab bar + search nav + copy (only when payload exists)
            if entry.hasPayload {
                Divider()
                HStack(spacing: 6) {
                    // Tab buttons with icon + label
                    HStack(spacing: 2) {
                        ForEach(availableTabs, id: \.rawValue) { t in
                            let active = tab == t
                            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { tab = t } }) {
                                HStack(spacing: 4) {
                                    Image(systemName: t.icon)
                                        .font(.system(size: 10, weight: active ? .semibold : .regular))
                                    Text(t.rawValue)
                                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(active ? t.color.opacity(colorScheme == .dark ? 0.18 : 0.14) : Color.clear)
                                .foregroundColor(active ? t.color : .secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(active ? t.color.opacity(colorScheme == .dark ? 0.45 : 0.55) : Color.clear,
                                                lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .help(t.rawValue)
                            .disabled(isBuilding && t != .raw)
                        }
                    }
                    .padding(3)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: colorScheme == .dark ? 0.5 : 0.75))

                    if isBuilding {
                        ProgressView().scaleEffect(0.5)
                    }

                    Spacer(minLength: 0)

                    // Search match navigation
                    if !searchText.isEmpty, (tab == .json || tab == .raw), totalMatches > 0 {
                        HStack(spacing: 2) {
                            Button(action: prevMatch) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 9, weight: .semibold))
                            }.buttonStyle(.plain).foregroundColor(.secondary)
                            Text("\(matchIndex + 1)/\(totalMatches)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary).frame(minWidth: 28)
                            Button(action: nextMatch) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                            }.buttonStyle(.plain).foregroundColor(.secondary)
                        }
                    }

                    copyButton
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    // MARK: - Payload tabs
    @ViewBuilder
    private var payloadView: some View {
        if isBuilding {
            VStack(spacing: 8) {
                Spacer()
                ProgressView()
                Text("Decoding the chaos…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            // All tab views stay alive in the ZStack — only opacity + hit-testing change.
            // This prevents NSTextView from being destroyed and re-laid-out on every tab switch,
            // which was the main cause of jank when toggling back to JSON/Raw.
            ZStack {
                ScrollView {
                    if let note = treeOmittedReason {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(treeNodes) { node in
                                JSONNodeView(node: node, depth: 0, searchText: searchText)
                                    .padding(.horizontal, 12)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
                .opacity(tab == .tree ? 1 : 0)
                .allowsHitTesting(tab == .tree)

                if !arrayFields.isEmpty {
                    TablePayloadView(arrayFields: arrayFields, searchText: searchText)
                        .opacity(tab == .table ? 1 : 0)
                        .allowsHitTesting(tab == .table)
                }

                SyntaxHighlightedJSONView(attributedText: highlightedJSON,
                                          searchText: searchText, matchIndex: matchIndex)
                    .opacity(tab == .json ? 1 : 0)
                    .allowsHitTesting(tab == .json)

                ReadOnlyCodeView(text: entry.rawContent,
                                 searchText: searchText, matchIndex: matchIndex)
                    .opacity(tab == .raw ? 1 : 0)
                    .allowsHitTesting(tab == .raw)
            }
        }
    }

    // MARK: - Copy
    private var copyButton: some View {
        Button(action: copyPayload) {
            Label(copyMsg ?? "Copy", systemImage: "doc.on.clipboard")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
    }

    private func copyPayload() {
        // Copy pretty JSON for tree/json tabs; raw for raw/table
        let text: String
        switch tab {
        case .json, .tree:
            text = !prettyJSON.isEmpty ? prettyJSON : entry.rawContent
        case .raw, .table:
            text = entry.rawContent
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyMsg = "Yoink!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copyMsg = nil }
    }
}

struct LevelBadge: View {
    let level: LogLevel
    @Environment(\.colorScheme) var colorScheme
    var body: some View {
        Text(level.badge)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(level.color.opacity(colorScheme == .dark ? 0.20 : 0.18))
            .foregroundColor(colorScheme == .dark ? level.color : level.darkColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Shared helpers for searchable text views

/// Scrolls an NSTextView to the Nth case-insensitive match of `query`.
private func scrollToNthMatch(in tv: NSTextView, query: String, index: Int) {
    DispatchQueue.main.async {
        guard !query.isEmpty else {
            tv.scrollRangeToVisible(NSRange(location: 0, length: 0)); return
        }
        let ns = tv.string as NSString
        let len = ns.length
        var loc = 0, count = 0
        while loc < len {
            let r = ns.range(of: query, options: .caseInsensitive,
                             range: NSRange(location: loc, length: len - loc))
            guard r.location != NSNotFound else { break }
            if count == index { tv.scrollRangeToVisible(r); return }
            count += 1
            loc = r.location + max(1, r.length)
        }
    }
}

/// Creates a read-only NSTextView inside an NSScrollView with standard config.
private func makeReadOnlyScrollableTextView(richText: Bool = false) -> (NSScrollView, NSTextView) {
    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.isRichText = richText
    textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.backgroundColor = NSColor.textBackgroundColor
    textView.drawsBackground = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.layoutManager?.allowsNonContiguousLayout = true

    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    return (scroll, textView)
}

/// Tracks whether the base text, search query, or match index changed between updates.
final class SearchableTextCoordinator {
    var lastBase   = ""
    var lastSearch = ""
    var lastIndex  = 0

    /// Returns which inputs changed. Resets tracking state as a side-effect.
    func detectChanges(base: String, search: String, index: Int) -> (base: Bool, search: Bool, index: Bool)? {
        let bc = lastBase   != base
        let sc = lastSearch != search
        let ic = lastIndex  != index
        guard bc || sc || ic else { return nil }
        lastBase   = base
        lastSearch = search
        lastIndex  = index
        return (bc, sc, ic)
    }
}

// MARK: - Read-only code view with optional search highlight
struct ReadOnlyCodeView: NSViewRepresentable {
    let text: String
    let searchText: String
    let matchIndex: Int

    func makeCoordinator() -> SearchableTextCoordinator { SearchableTextCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        makeReadOnlyScrollableTextView().0
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        guard context.coordinator.detectChanges(base: text, search: searchText, index: matchIndex) != nil else { return }

        // Apply syntax coloring if the content looks like JSON.
        // highlight() auto-selects fast O(n) path for large payloads.
        let trimmedFirst = text.trimmingCharacters(in: .whitespacesAndNewlines).first
        let looksLikeJSON = trimmedFirst == "{" || trimmedFirst == "["

        if searchText.isEmpty {
            let attrStr = looksLikeJSON
                ? JSONHighlighter.highlight(text)
                : JSONHighlighter.plainMonospace(text)
            tv.textStorage?.setAttributedString(attrStr)
        } else {
            let base = looksLikeJSON
                ? (JSONHighlighter.highlight(text).mutableCopy() as! NSMutableAttributedString)
                : (JSONHighlighter.plainMonospace(text).mutableCopy() as! NSMutableAttributedString)
            tv.textStorage?.setAttributedString(JSONHighlighter.addSearchHighlights(base, search: searchText))
        }

        scrollToNthMatch(in: tv, query: searchText, index: matchIndex)
    }
}

// MARK: - Syntax-highlighted JSON view with search support

struct SyntaxHighlightedJSONView: NSViewRepresentable {
    let attributedText: NSAttributedString
    let searchText: String
    let matchIndex: Int

    func makeCoordinator() -> SearchableTextCoordinator { SearchableTextCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // Do NOT set attributedText here — updateNSView runs immediately after and handles it,
        // avoiding a redundant double layout pass on every creation.
        makeReadOnlyScrollableTextView(richText: true).0
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        guard let changes = context.coordinator.detectChanges(
            base: attributedText.string, search: searchText, index: matchIndex
        ) else { return }

        if changes.base || changes.search {
            let display = searchText.isEmpty
                ? attributedText
                : JSONHighlighter.addSearchHighlights(attributedText, search: searchText)
            tv.textStorage?.setAttributedString(display)
        }

        scrollToNthMatch(in: tv, query: searchText, index: matchIndex)
    }
}

// MARK: - JSON syntax highlighter (runs on background thread, result is cached)

enum JSONHighlighter {
    // Dynamic colors — matching the diff view's rich color scheme.
    // Keys: sky blue (dark) / royal blue (light)
    private static let keyColor = NSColor(name: nil) { t in
        t.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.40, green: 0.80, blue: 1.00, alpha: 1)
            : NSColor(calibratedRed: 0.00, green: 0.32, blue: 0.80, alpha: 1)
    }
    // Strings: amber (dark) / burnt orange (light)
    private static let stringColor = NSColor(name: nil) { t in
        t.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.92, green: 0.65, blue: 0.35, alpha: 1)
            : NSColor(calibratedRed: 0.62, green: 0.22, blue: 0.00, alpha: 1)
    }
    // Numbers: lime (dark) / forest green (light)
    private static let numberColor = NSColor(name: nil) { t in
        t.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.65, green: 0.92, blue: 0.48, alpha: 1)
            : NSColor(calibratedRed: 0.06, green: 0.44, blue: 0.06, alpha: 1)
    }
    // Booleans: lavender (dark) / deep purple (light)
    private static let boolColor = NSColor(name: nil) { t in
        t.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.82, green: 0.52, blue: 0.98, alpha: 1)
            : NSColor(calibratedRed: 0.48, green: 0.08, blue: 0.72, alpha: 1)
    }

    private static let numberRegex = try! NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#)
    private static let boolRegex   = try! NSRegularExpression(pattern: #"\b(?:true|false)\b"#)
    private static let nullRegex   = try! NSRegularExpression(pattern: #"\bnull\b"#)
    private static let stringRegex = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
    private static let keyRegex    = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"(?=\s*:)"#)

    /// Monospace body text without any coloring.
    static func plainMonospace(_ text: String) -> NSAttributedString {
        let ms = NSMutableAttributedString(string: text)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let whole = NSRange(text.startIndex..., in: text)
        ms.addAttribute(.font, value: font, range: whole)
        ms.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        return ms.copy() as! NSAttributedString
    }

    /// Syntax highlight — uses regex for small payloads, fast char-by-char for large ones.
    static func highlight(_ text: String) -> NSAttributedString {
        // For payloads > 384KB, use the fast O(n) char-by-char highlighter (same as diff view).
        // Regex is 5 full-text passes — too slow for multi-MB strings.
        if text.utf8.count >= 384_000 {
            return highlightFast(text)
        }
        let ms = NSMutableAttributedString(string: text)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let whole = NSRange(text.startIndex..., in: text)

        ms.addAttribute(.font,            value: font,                    range: whole)
        ms.addAttribute(.foregroundColor, value: NSColor.labelColor,      range: whole)

        apply(numberRegex, color: numberColor, to: ms, in: text)
        apply(boolRegex,   color: boolColor,   to: ms, in: text)
        apply(nullRegex,   color: NSColor.tertiaryLabelColor, to: ms, in: text)
        apply(stringRegex, color: stringColor, to: ms, in: text)
        apply(keyRegex,    color: keyColor,    to: ms, in: text)

        return ms.copy() as! NSAttributedString
    }

    /// Fast O(n) syntax highlighter — single pass, char-by-char, no regex.
    /// Works on any payload size including multi-MB. Same approach as the diff view.
    static func highlightFast(_ text: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let ms = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor
        ])
        let ns = text as NSString
        let len = ns.length
        var pos = 0

        while pos < len {
            var lineEnd = pos, contentsEnd = pos
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: pos, length: 0))
            let ce = contentsEnd

            var p = pos
            while p < ce && ns.character(at: p) == 32 { p += 1 }
            guard p < ce else { pos = lineEnd > pos ? lineEnd : len; continue }

            let c0 = ns.character(at: p)
            if c0 == 34 { // '"'
                let qStart = p; p += 1
                while p < ce {
                    let c = ns.character(at: p)
                    if c == 92 { p = min(p + 2, ce); continue }
                    if c == 34 { p += 1; break }
                    p += 1
                }
                let qEnd = p
                var q = p
                while q < ce && ns.character(at: q) == 32 { q += 1 }
                if q < ce && ns.character(at: q) == 58 { // ':'
                    ms.addAttribute(.foregroundColor, value: keyColor,
                                    range: NSRange(location: qStart, length: qEnd - qStart))
                    q += 1
                    while q < ce && ns.character(at: q) == 32 { q += 1 }
                    colorValueFast(ms, ns: ns, s: q, e: ce)
                } else {
                    ms.addAttribute(.foregroundColor, value: stringColor,
                                    range: NSRange(location: qStart, length: qEnd - qStart))
                }
            } else if c0 != 123 && c0 != 125 && c0 != 91 && c0 != 93 {
                colorValueFast(ms, ns: ns, s: p, e: ce)
            }
            pos = lineEnd > pos ? lineEnd : len
        }
        return ms.copy() as! NSAttributedString
    }

    private static func colorValueFast(_ ms: NSMutableAttributedString, ns: NSString, s: Int, e: Int) {
        guard s < e else { return }
        var end = e
        while end > s { let c = ns.character(at: end - 1); if c == 44 || c == 32 { end -= 1 } else { break } }
        guard end > s else { return }
        let r = NSRange(location: s, length: end - s)
        switch ns.character(at: s) {
        case 34:            ms.addAttribute(.foregroundColor, value: stringColor, range: r)
        case 116, 102:      ms.addAttribute(.foregroundColor, value: boolColor,   range: r)
        case 110:           ms.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
        case 123, 125, 91, 93: break
        default:            ms.addAttribute(.foregroundColor, value: numberColor, range: r)
        }
    }

    /// Applies case-insensitive search highlight on top of an existing attributed string.
    static func addSearchHighlights(_ base: NSAttributedString, search: String) -> NSAttributedString {
        guard !search.isEmpty else { return base }
        let ms  = (base.mutableCopy() as! NSMutableAttributedString)
        let ns  = base.string as NSString
        let len = ns.length
        var loc = 0
        while loc < len {
            let found = ns.range(of: search, options: .caseInsensitive,
                                 range: NSRange(location: loc, length: len - loc))
            guard found.location != NSNotFound else { break }
            ms.addAttribute(.backgroundColor,
                            value: NSColor.systemYellow.withAlphaComponent(0.55), range: found)
            ms.addAttribute(.foregroundColor, value: NSColor.black, range: found)
            loc = found.location + max(1, found.length)
        }
        return ms.copy() as! NSAttributedString
    }

    private static func apply(_ regex: NSRegularExpression, color: NSColor,
                               to ms: NSMutableAttributedString, in text: String) {
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            ms.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
