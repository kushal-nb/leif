import SwiftUI
import AppKit

// MARK: - Escape-aware window

/// Pressing Escape closes the diff window.
/// (If a search field is focused, SwiftUI unfocuses it on the first Escape;
///  the second Escape reaches this override and closes.)
private final class EscapeClosingWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() }
        else { super.keyDown(with: event) }
    }
}

// MARK: - Window controller

final class DiffWindowController {
    static let shared = DiffWindowController()
    private var window: NSWindow?

    func show(left: LogEntry, right: LogEntry, isDark: Bool) {
        let hosting = NSHostingController(rootView: DiffView(left: left, right: right))
        // Empty sizingOptions: NSHostingView fills whatever frame the window gives it.
        // [.minSize/.maxSize] would pin the view to its intrinsic size and break zoom.
        hosting.sizingOptions = []

        if window == nil {
            let win = EscapeClosingWindow(contentViewController: hosting)
            win.title = "JSON Diff"
            win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.minSize = NSSize(width: 900, height: 560)
            // Open at 82 % of the screen's usable area, capped at a comfortable max.
            let avail = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                        ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let w = max(900,  min(1480, avail.width  * 0.82)).rounded()
            let h = max(560,  min(960,  avail.height * 0.82)).rounded()
            win.setContentSize(NSSize(width: w, height: h))
            win.center()
            self.window = win
        } else {
            window!.contentViewController = hosting
        }

        guard let win = window else { return }
        win.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Diff state

private enum DiffState {
    case computing
    case noPayload
    case identical
    /// summary is nil when the payload exceeded the structural-diff threshold.
    case sideBySide(leftJSON: String, rightJSON: String,
                    summary: String?, changes: [DiffRow])
}

// MARK: - Diff view

struct DiffView: View {
    let left:  LogEntry
    let right: LogEntry

    @State private var diffState      = DiffState.computing
    @State private var syncCoordinator = ScrollSyncCoordinator()
    @State private var searchText     = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) var cs

    /// Skip structural diff only for very large payloads (20 MB raw).
    private let diffSizeLimit = 20_000_000

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            contentBody
        }
        // Fill the whole window; minWidth/minHeight matching window.minSize.
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        // Hidden ⌘F shortcut — focuses global search field without fighting AppKit responders.
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0)
                .allowsHitTesting(false).accessibilityHidden(true)
        )
        .task(id: "\(left.id)|\(right.id)") { await computeDiff() }
    }

    // MARK: Content

    @ViewBuilder
    private var contentBody: some View {
        switch diffState {
        case .computing:
            ProgressView("Computing diff…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noPayload:
            statusMessage("One or both entries have no JSON payload to diff.",
                          icon: "exclamationmark.triangle")
        case .identical:
            statusMessage("Entries are identical — no differences found.",
                          icon: "checkmark.circle")
        case .sideBySide(let lj, let rj, let summary, let changes):
            sideBySideBody(leftJSON: lj, rightJSON: rj, summary: summary, changes: changes)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            entryCard(entry: left,  label: "A", accent: removedColor)
                .frame(maxWidth: .infinity)
            Divider().frame(height: 40)
            entryCard(entry: right, label: "B", accent: addedColor)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 40)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func entryCard(entry: LogEntry, label: String, accent: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(accent.opacity(cs == .dark ? 0.28 : 0.14))
                .foregroundColor(accent)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            LevelBadge(level: entry.level)
            if !entry.displayTimestamp.isEmpty {
                Text(entry.displayTimestamp)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text(entry.message)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1).foregroundColor(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    // MARK: Side-by-side layout

    @ViewBuilder
    private func sideBySideBody(leftJSON: String, rightJSON: String,
                                summary: String?, changes: [DiffRow]) -> some View {
        VStack(spacing: 0) {
            infoBar(summary: summary)
            Divider()
            HStack(spacing: 0) {
                diffColumn(title: "A  —  before", titleColor: removedColor,
                           json: leftJSON, isLeft: true, changes: changes)
                Divider()
                diffColumn(title: "B  —  after", titleColor: addedColor,
                           json: rightJSON, isLeft: false, changes: changes)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Summary strip + global ⌘F search
    private func infoBar(summary: String?) -> some View {
        HStack(spacing: 8) {
            if let summary {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text(summary)
                    .font(.system(size: 10)).foregroundColor(.secondary)
            } else {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text("Payload too large for structural diff — showing formatted JSON.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(systemName: searchText.isEmpty
                      ? "magnifyingglass" : "magnifyingglass.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(searchText.isEmpty ? .secondary : .accentColor)
                TextField("Search both columns  (⌘F)", text: $searchText)
                    .font(.system(size: 11))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Esc  ·  close").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.45))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
    }

    private func diffColumn(title: String, titleColor: Color,
                            json: String, isLeft: Bool, changes: [DiffRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(titleColor.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            Divider()
            DiffTextView(text: json, syncCoord: syncCoordinator,
                         isLeft: isLeft, changes: changes,
                         isDark: cs == .dark, searchText: searchText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Colors

    private var addedColor: Color {
        cs == .dark
            ? Color(red: 0.28, green: 0.90, blue: 0.50)
            : Color(red: 0.06, green: 0.52, blue: 0.22)
    }
    private var removedColor: Color {
        cs == .dark
            ? Color(red: 1.00, green: 0.38, blue: 0.38)
            : Color(red: 0.75, green: 0.10, blue: 0.10)
    }

    // MARK: Helpers

    private func statusMessage(_ msg: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28)).foregroundColor(.secondary.opacity(0.5))
            Text(msg).foregroundColor(.secondary).font(.system(size: 13))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Compute diff

    private func computeDiff() async {
        guard let lf = left.fields, let rf = right.fields else {
            diffState = .noPayload; return
        }
        let lDict = Dictionary(uniqueKeysWithValues: lf.pairs.map { ($0.key, $0.value) })
        let rDict = Dictionary(uniqueKeysWithValues: rf.pairs.map { ($0.key, $0.value) })

        // Fast identity check
        if (lDict as NSDictionary).isEqual(to: rDict as NSDictionary) {
            diffState = .identical; return
        }

        let leftS  = Self.prettyJSON(lDict)
        let rightS = Self.prettyJSON(rDict)

        // Skip structural diff for very large payloads
        let payloadBytes = leftS.utf8.count + rightS.utf8.count
        if payloadBytes > diffSizeLimit {
            diffState = .sideBySide(leftJSON: leftS, rightJSON: rightS,
                                    summary: nil, changes: [])
            return
        }

        let rows = await Task(priority: .userInitiated) {
            JSONDiffer.diff(left: lDict, right: rDict)
        }.value
        guard !Task.isCancelled else { return }

        if rows.allSatisfy({ $0.status == .unchanged || $0.status == .containerClean }) {
            diffState = .identical; return
        }

        // ALL visually interesting rows — used for line background coloring.
        // Sidebar is gone; every change is communicated through line colors alone.
        let changes = rows.filter {
            $0.status == .added || $0.status == .removed ||
            $0.status == .modified || $0.status == .containerChanged
        }

        let focus    = changes.filter(\.isFocusPoint)
        let added    = focus.filter { $0.status == .added    }.count
        let removed  = focus.filter { $0.status == .removed  }.count
        let modified = focus.filter { $0.status == .modified }.count
        let total    = added + removed + modified
        let summary  = total == 0
            ? "No leaf changes (structure only)"
            : "\(total) change\(total == 1 ? "" : "s")  ·  \(added) added  ·  \(removed) removed  ·  \(modified) modified"

        diffState = .sideBySide(leftJSON: leftS, rightJSON: rightS,
                                summary: summary, changes: changes)
    }

    private static func prettyJSON(_ dict: [String: Any]) -> String {
        let s = JSONFormatter.prettyPrint(dict)
        return s.isEmpty ? "(empty payload)" : s
    }
}

// MARK: - Scroll sync coordinator

/// Keeps both text views scrolled to the same relative position.
/// Uses NSView.boundsDidChangeNotification on the NSClipView so that
/// mouse wheel, trackpad, and keyboard scroll are all captured.
final class ScrollSyncCoordinator {
    var leftScroll:   NSScrollView?
    var rightScroll:  NSScrollView?
    var leftTV:       NSTextView?
    var rightTV:      NSTextView?
    private var isSyncing = false

    func peerDidScroll(isLeft: Bool) {
        guard !isSyncing else { return }
        let src  = isLeft ? leftScroll  : rightScroll
        let tgt  = isLeft ? rightScroll : leftScroll
        guard let src, let tgt,
              let srcDoc = src.documentView,
              let tgtDoc = tgt.documentView else { return }
        let srcH = srcDoc.frame.height
        guard srcH > 0 else { return }
        let pct  = src.contentView.bounds.origin.y / srcH
        let tgtY = max(0, pct * tgtDoc.frame.height)
        isSyncing = true
        tgt.contentView.scroll(to: NSPoint(x: 0, y: tgtY))
        tgt.reflectScrolledClipView(tgt.contentView)
        isSyncing = false
    }

    /// Scrolls and shows a find-indicator ring on `key` in both panels.
    func jumpToKey(_ key: String) {
        guard !key.isEmpty else { return }
        let q = "\"" + key + "\""
        for tv in [leftTV, rightTV].compactMap({ $0 }) {
            let r = (tv.string as NSString).range(of: q, options: .caseInsensitive)
            guard r.location != NSNotFound else { continue }
            tv.scrollRangeToVisible(r)
            tv.showFindIndicator(for: r)
        }
    }
}

// MARK: - Diff text view

/// Read-only NSTextView with three layers of attributed-string decoration:
///   1. JSON syntax colours  (key=blue, string=amber, number=green, bool/null=purple/grey)
///   2. Diff background colours  (added=green, removed=red, modified=orange, container=yellow)
///      Keyed on (leading-space-count, key-name) so only the exact changed line is lit,
///      never a same-named key at a different nesting depth.
///   3. Search highlights  (amber background, black foreground)
private struct DiffTextView: NSViewRepresentable {
    var text:       String
    var syncCoord:  ScrollSyncCoordinator
    var isLeft:     Bool
    var changes:    [DiffRow]
    var isDark:     Bool
    var searchText: String

    // MARK: NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.drawsBackground       = true
        sv.backgroundColor       = .textBackgroundColor
        sv.hasVerticalScroller   = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers    = true
        sv.borderType            = .noBorder

        let tv = NSTextView()
        tv.isEditable              = false
        tv.isSelectable            = true
        tv.isRichText              = true     // required for background-color attributes
        tv.drawsBackground         = false
        tv.importsGraphics         = false
        tv.font                    = .monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.textContainerInset      = NSSize(width: 8, height: 8)
        tv.minSize                 = .zero
        tv.maxSize                 = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                            height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable   = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask        = [.width]
        tv.textContainer?.lineFragmentPadding  = 0
        // widthTracksTextView = true means the container width follows the text-view width,
        // which follows the scroll-view content width via autoresizingMask → correct reflow
        // when the window is resized or zoomed.
        tv.textContainer?.widthTracksTextView  = true

        apply(to: tv, search: searchText)
        sv.documentView = tv

        if isLeft { syncCoord.leftScroll  = sv; syncCoord.leftTV  = tv }
        else       { syncCoord.rightScroll = sv; syncCoord.rightTV = tv }

        // Observe clip-view bounds changes — fires for trackpad, mouse wheel, and keyboard.
        sv.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipped(_:)),
            name: NSView.boundsDidChangeNotification,
            object: sv.contentView)

        context.coordinator.renderedText   = text
        context.coordinator.renderedSearch = searchText
        context.coordinator.renderedIsDark = isDark

        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        let c = context.coordinator
        guard c.renderedText   != text   ||
              c.renderedSearch != searchText ||
              c.renderedIsDark != isDark else { return }
        c.renderedText   = text
        c.renderedSearch = searchText
        c.renderedIsDark = isDark
        apply(to: tv, search: searchText)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isLeft: isLeft, syncCoord: syncCoord)
    }

    // MARK: Apply attributed string

    private func apply(to tv: NSTextView, search: String) {
        tv.textStorage?.setAttributedString(
            Self.buildAttributed(json: text, changes: changes,
                                 isLeft: isLeft, isDark: isDark, searchText: search))
    }

    // MARK: Attributed-string builder (three passes)

    static func buildAttributed(json: String, changes: [DiffRow],
                                isLeft: Bool, isDark: Bool,
                                searchText: String) -> NSAttributedString {
        let baseFont: NSFont = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let baseFg: NSColor  = isDark
            ? NSColor(calibratedWhite: 0.88, alpha: 1)
            : NSColor(calibratedWhite: 0.12, alpha: 1)

        let result = NSMutableAttributedString(string: json, attributes: [
            .font:            baseFont,
            .foregroundColor: baseFg
        ])

        // ── Pass 1: syntax colours ────────────────────────────────────────────────
        applySyntaxColors(result, ns: json as NSString, isDark: isDark)

        // ── Pass 2: diff background colours ──────────────────────────────────────
        // Build a lookup:  leadingSpaces → [keyName → backgroundColor]
        // leadingSpaces == depth × 2  (JSONFormatter.prettyPrint invariant).
        // The two-level key means only the exact (depth, name) line is coloured —
        // a key that appears at multiple nesting levels is never mis-highlighted.
        if !changes.isEmpty {
            var colorMap = [Int: [String: NSColor]]()
            for row in changes {
                guard let key = row.key else { continue }
                let spaces = row.depth * 2
                guard let color = diffLineColor(status: row.status,
                                                isLeft: isLeft, isDark: isDark) else { continue }
                if colorMap[spaces] == nil { colorMap[spaces] = [:] }
                // Leaf changes win over containerChanged for the same (depth, key).
                if colorMap[spaces]![key] == nil { colorMap[spaces]![key] = color }
            }

            if !colorMap.isEmpty {
                let ns  = json as NSString
                let len = ns.length
                var pos = 0
                while pos < len {
                    var lineEnd = pos
                    ns.getLineStart(nil, end: &lineEnd, contentsEnd: nil,
                                    for: NSRange(location: pos, length: 0))
                    if lineEnd <= pos { lineEnd = min(pos + 1, len) }
                    let range = NSRange(location: pos, length: lineEnd - pos)
                    if let bg = matchLineColor(ns.substring(with: range), map: colorMap) {
                        result.addAttribute(.backgroundColor, value: bg, range: range)
                    }
                    pos = lineEnd
                }
            }
        }

        // ── Pass 3: search highlights ─────────────────────────────────────────────
        if !searchText.isEmpty {
            let ns  = json as NSString
            let len = ns.length
            let hlBg = isDark
                ? NSColor(calibratedHue: 0.13, saturation: 0.85, brightness: 0.95, alpha: 0.90)
                : NSColor(calibratedHue: 0.13, saturation: 0.95, brightness: 1.00, alpha: 0.92)
            let hlFg   = NSColor.black
            let hlFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
            var pos = 0
            while pos < len {
                let r = ns.range(of: searchText, options: .caseInsensitive,
                                 range: NSRange(location: pos, length: len - pos))
                guard r.location != NSNotFound, r.length > 0 else { break }
                result.addAttributes([.backgroundColor: hlBg,
                                      .foregroundColor: hlFg,
                                      .font: hlFont], range: r)
                pos = r.location + r.length
            }
        }

        return result
    }

    // MARK: Diff line-color helpers

    /// Looks up the background color for a single text line using the colorMap.
    /// 1. Count leading spaces.
    /// 2. Find the bucket for that depth.
    /// 3. Extract `"key":` from the line.
    /// 4. Return the color if the key is in the bucket.
    private static func matchLineColor(_ line: String,
                                       map: [Int: [String: NSColor]]) -> NSColor? {
        var spaces = 0
        for ch in line { if ch == " " { spaces += 1 } else { break } }
        guard let bucket = map[spaces] else { return nil }

        let trimmed = String(line.dropFirst(spaces))
        guard trimmed.hasPrefix("\"") else { return nil }
        let body = trimmed.dropFirst()                        // after opening "
        guard let closeIdx = body.firstIndex(of: "\"") else { return nil }
        let key  = String(body[body.startIndex..<closeIdx])
        let tail = body[closeIdx...].dropFirst()              // skip closing "
                       .drop(while: { $0 == " " })
        guard tail.hasPrefix(":") else { return nil }
        return bucket[key]
    }

    /// Background color for a changed line on this side of the diff.
    /// Returns nil for statuses that produce no visible background (e.g. .removed on the right).
    private static func diffLineColor(status: DiffRow.Status,
                                      isLeft: Bool, isDark: Bool) -> NSColor? {
        let a: CGFloat = isDark ? 0.30 : 0.22
        switch status {
        case .removed:
            return isLeft
                ? NSColor(calibratedRed: 0.95, green: 0.12, blue: 0.12, alpha: a)
                : nil
        case .added:
            return isLeft
                ? nil
                : NSColor(calibratedRed: 0.06, green: 0.80, blue: 0.28, alpha: a)
        case .modified:
            // Orange on both sides — value changed.
            return NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.00, alpha: a * 0.85)
        case .containerChanged:
            // Subtle yellow — "something inside this block changed".
            return NSColor(calibratedRed: 1.00, green: 0.88, blue: 0.00,
                           alpha: isDark ? 0.14 : 0.10)
        default:
            return nil
        }
    }

    // MARK: JSON syntax highlighting

    /// Applies foreground token colours.  Works directly on NSString unichar indices —
    /// no regex, no per-line String allocations.
    ///
    ///   key name      → blue/cyan
    ///   string value  → warm amber
    ///   number        → green
    ///   true/false    → purple/lavender
    ///   null          → grey
    ///   { } [ ] ,     → base colour (no override)
    private static func applySyntaxColors(_ mas: NSMutableAttributedString,
                                          ns: NSString, isDark: Bool) {
        let keyCol:  NSColor = isDark
            ? NSColor(calibratedRed: 0.40, green: 0.80, blue: 1.00, alpha: 1) // sky blue
            : NSColor(calibratedRed: 0.00, green: 0.32, blue: 0.80, alpha: 1) // royal blue
        let strCol:  NSColor = isDark
            ? NSColor(calibratedRed: 0.92, green: 0.65, blue: 0.35, alpha: 1) // amber
            : NSColor(calibratedRed: 0.62, green: 0.22, blue: 0.00, alpha: 1) // burnt orange
        let numCol:  NSColor = isDark
            ? NSColor(calibratedRed: 0.65, green: 0.92, blue: 0.48, alpha: 1) // lime
            : NSColor(calibratedRed: 0.06, green: 0.44, blue: 0.06, alpha: 1) // forest green
        let boolCol: NSColor = isDark
            ? NSColor(calibratedRed: 0.82, green: 0.52, blue: 0.98, alpha: 1) // lavender
            : NSColor(calibratedRed: 0.48, green: 0.08, blue: 0.72, alpha: 1) // deep purple
        let nullCol: NSColor = isDark
            ? NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.55, alpha: 1) // mid-grey
            : NSColor(calibratedRed: 0.46, green: 0.46, blue: 0.46, alpha: 1)

        let len = ns.length
        var pos = 0
        while pos < len {
            var lineEnd     = pos
            var contentsEnd = pos
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: pos, length: 0))
            let ce = contentsEnd

            // skip leading spaces
            var p = pos
            while p < ce && ns.character(at: p) == 32 { p += 1 }
            guard p < ce else { pos = lineEnd > pos ? lineEnd : len; continue }

            let c0 = ns.character(at: p)

            if c0 == 34 {   // '"' — a quoted token starts here
                let qStart = p
                p += 1
                while p < ce {
                    let c = ns.character(at: p)
                    if c == 92 { p += 2; continue }  // backslash — skip escaped char
                    if c == 34 { p += 1; break }      // closing "
                    p += 1
                }
                let qEnd = p  // position after closing "

                // Is this a key (followed by ':')?
                var q = p
                while q < ce && ns.character(at: q) == 32 { q += 1 }
                if q < ce && ns.character(at: q) == 58 {   // ':'
                    mas.addAttribute(.foregroundColor, value: keyCol,
                                     range: NSRange(location: qStart, length: qEnd - qStart))
                    q += 1
                    while q < ce && ns.character(at: q) == 32 { q += 1 }
                    colorValue(mas: mas, ns: ns, start: q, end: ce,
                               strCol: strCol, numCol: numCol, boolCol: boolCol, nullCol: nullCol)
                } else {
                    // String value (array element or bare root string)
                    mas.addAttribute(.foregroundColor, value: strCol,
                                     range: NSRange(location: qStart, length: qEnd - qStart))
                }
            } else if c0 != 123 && c0 != 125 && c0 != 91 && c0 != 93 {
                // Not { } [ ] — must be a bare value (number, true, false, null)
                colorValue(mas: mas, ns: ns, start: p, end: ce,
                           strCol: strCol, numCol: numCol, boolCol: boolCol, nullCol: nullCol)
            }

            pos = lineEnd > pos ? lineEnd : len
        }
    }

    private static func colorValue(mas: NSMutableAttributedString,
                                   ns: NSString, start: Int, end: Int,
                                   strCol: NSColor, numCol: NSColor,
                                   boolCol: NSColor, nullCol: NSColor) {
        guard start < end else { return }
        var e = end
        // strip trailing comma and spaces
        while e > start {
            let c = ns.character(at: e - 1)
            if c == 44 || c == 32 { e -= 1 } else { break }
        }
        guard e > start else { return }
        let range = NSRange(location: start, length: e - start)
        switch ns.character(at: start) {
        case 34:            mas.addAttribute(.foregroundColor, value: strCol,  range: range)  // "
        case 116, 102:      mas.addAttribute(.foregroundColor, value: boolCol, range: range)  // t / f
        case 110:           mas.addAttribute(.foregroundColor, value: nullCol, range: range)  // n(ull)
        case 123, 125, 91, 93: break  // { } [ ] — structural, keep base colour
        default:            mas.addAttribute(.foregroundColor, value: numCol,  range: range)  // digit/-
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject {
        let isLeft:    Bool
        let syncCoord: ScrollSyncCoordinator
        var renderedText:   String = ""
        var renderedSearch: String = ""
        var renderedIsDark: Bool   = false

        init(isLeft: Bool, syncCoord: ScrollSyncCoordinator) {
            self.isLeft    = isLeft
            self.syncCoord = syncCoord
        }

        @objc func clipped(_ note: Notification) {
            syncCoord.peerDidScroll(isLeft: isLeft)
        }
    }
}
