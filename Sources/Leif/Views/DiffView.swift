import SwiftUI
import AppKit

// MARK: - Escape-aware window

private final class EscapeClosingWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() }
        else { super.keyDown(with: event) }
    }
}

// MARK: - Window controller

final class DiffWindowController: NSObject, NSWindowDelegate {
    static let shared = DiffWindowController()
    private var window: NSWindow?
    /// Saved frame so the next diff window reopens at the same position/size.
    private var lastFrame: NSRect?

    func show(left: LogEntry, right: LogEntry, isDark: Bool) {
        // Clean up any existing diff window first — prevents leaking the old one
        if window != nil { closeIfOpen() }

        let hosting = NSHostingController(rootView: DiffView(left: left, right: right))
        hosting.sizingOptions = []
        let win = EscapeClosingWindow(contentViewController: hosting)
        win.title = "JSON Diff"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.minSize = NSSize(width: 900, height: 560)
        if let frame = lastFrame {
            win.setFrame(frame, display: false)
        } else {
            let avail = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                        ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let w = max(900, min(1480, avail.width * 0.82)).rounded()
            let h = max(560, min(960, avail.height * 0.82)).rounded()
            win.setContentSize(NSSize(width: w, height: h))
            win.center()
        }
        self.window = win
        win.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Free ALL diff memory when window is closed (✕ button, Cmd+W, or Esc).
    func windowWillClose(_ notification: Notification) {
        guard let win = window else { return }
        lastFrame = win.frame

        // 1. Clear NSTextView textStorage — releases the huge NSAttributedStrings
        //    and their layout managers.
        clearTextViews(in: win.contentView)

        // 2. Detach the SwiftUI hosting controller — releases DiffView,
        //    DiffResult, and all SwiftUI state.
        win.contentViewController = nil

        // 3. Drop window ref on the NEXT run loop tick so AppKit's close
        //    animation finishes before ARC deallocs the window.
        DispatchQueue.main.async { [weak self] in
            self?.window = nil

            // 4. Force malloc to return freed pages to the OS.
            //    Without this, resident_size stays high even though objects are freed
            //    because malloc keeps pages mapped for reuse.
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    /// Programmatically close the diff window (e.g. when the main app clears logs).
    func closeIfOpen() {
        window?.close()  // triggers windowWillClose → full cleanup
    }

    /// Recursively find all NSTextViews and clear their storage.
    private func clearTextViews(in view: NSView?) {
        guard let view else { return }
        if let tv = view as? NSTextView {
            tv.textStorage?.setAttributedString(NSAttributedString())
        }
        for sub in view.subviews { clearTextViews(in: sub) }
    }
}

// MARK: - Models

private struct DiffResult {
    let leftAttr: NSAttributedString
    let rightAttr: NSAttributedString
    let summary: String
    /// Row indices (0-based into aligned lines) where changes occur — for navigation.
    let changeIndices: [Int]
}

private enum DiffState {
    case computing, noPayload, identical
    case ready(DiffResult)
}

// MARK: - Diff view

struct DiffView: View {
    let left: LogEntry
    let right: LogEntry

    @State private var diffState = DiffState.computing
    @State private var syncCoordinator = ScrollSyncCoordinator()
    @State private var currentChange = 0
    @State private var diffTask: Task<DiffResult?, Never>?
    @Environment(\.colorScheme) var cs

    var body: some View {
        VStack(spacing: 0) { topBar; Divider(); contentBody }
            .frame(minWidth: 900, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
            .background(
                Group {
                    Button("") { navigateChange(delta: 1) }.keyboardShortcut(.downArrow, modifiers: .command)
                    Button("") { navigateChange(delta: -1) }.keyboardShortcut(.upArrow, modifiers: .command)
                }
                .frame(width: 0, height: 0).opacity(0)
                .allowsHitTesting(false).accessibilityHidden(true)
            )
            .task(id: "\(left.id)|\(right.id)") { await computeDiff() }
    }

    @ViewBuilder private var contentBody: some View {
        switch diffState {
        case .computing:  ProgressView("Computing diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noPayload:  statusMsg("One or both entries have no JSON payload to diff.", icon: "exclamationmark.triangle")
        case .identical:  statusMsg("Entries are identical — no differences found.", icon: "checkmark.circle")
        case .ready(let r): sideBySide(r)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            entryCard(entry: left, label: "A", accent: removedColor).frame(maxWidth: .infinity)
            Divider().frame(height: 40)
            entryCard(entry: right, label: "B", accent: addedColor).frame(maxWidth: .infinity)
        }.frame(height: 40).background(Color(nsColor: .controlBackgroundColor))
    }

    private func entryCard(entry: LogEntry, label: String, accent: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(accent.opacity(cs == .dark ? 0.28 : 0.14))
                .foregroundColor(accent).clipShape(RoundedRectangle(cornerRadius: 3))
            LevelBadge(level: entry.level)
            if !entry.displayTimestamp.isEmpty {
                Text(entry.displayTimestamp).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            }
            Text(entry.message).font(.system(size: 11, weight: .medium)).lineLimit(1).foregroundColor(.primary)
            Spacer(minLength: 0)
        }.padding(.horizontal, 10)
    }

    // MARK: Side-by-side

    @ViewBuilder private func sideBySide(_ r: DiffResult) -> some View {
        VStack(spacing: 0) {
            infoBar(summary: r.summary, changeCount: r.changeIndices.count)
            Divider()
            HStack(spacing: 0) {
                DiffTextView(attrText: r.leftAttr, syncCoord: syncCoordinator, isLeft: true)
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                DiffTextView(attrText: r.rightAttr, syncCoord: syncCoordinator, isLeft: false)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func infoBar(summary: String, changeCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 10)).foregroundColor(.secondary)
            Text(summary).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if changeCount > 0 {
                HStack(spacing: 2) {
                    Button(action: { navigateChange(delta: -1) }) {
                        Image(systemName: "arrowtriangle.up.fill")
                            .font(.system(size: 8))
                            .frame(width: 26, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Previous change (Cmd+Up)")

                    Text("\(min(currentChange + 1, changeCount))/\(changeCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(minWidth: 36)

                    Button(action: { navigateChange(delta: 1) }) {
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 8))
                            .frame(width: 26, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Next change (Cmd+Down)")
                }
            }
            Text("Cmd+F search  |  Esc close").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.45))
        }.padding(.horizontal, 12).padding(.vertical, 6).background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
    }

    // MARK: Colors

    private var addedColor: Color { cs == .dark ? Color(red: 0.28, green: 0.90, blue: 0.50) : Color(red: 0.06, green: 0.52, blue: 0.22) }
    private var removedColor: Color { cs == .dark ? Color(red: 1.00, green: 0.38, blue: 0.38) : Color(red: 0.75, green: 0.10, blue: 0.10) }

    // MARK: Navigation

    private func navigateChange(delta: Int) {
        guard case .ready(let r) = diffState, !r.changeIndices.isEmpty else { return }
        currentChange = (currentChange + delta + r.changeIndices.count) % r.changeIndices.count
        syncCoordinator.jumpToRow(r.changeIndices[currentChange])
    }

    private func statusMsg(_ msg: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundColor(.secondary.opacity(0.5))
            Text(msg).foregroundColor(.secondary).font(.system(size: 13))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Compute diff — all heavy work in background

    private func computeDiff() async {
        // Cancel any previous in-flight diff computation
        diffTask?.cancel()

        guard let lf = left.fields, let rf = right.fields else { diffState = .noPayload; return }
        let lDict = Dictionary(uniqueKeysWithValues: lf.pairs.map { ($0.key, $0.value) })
        let rDict = Dictionary(uniqueKeysWithValues: rf.pairs.map { ($0.key, $0.value) })
        if (lDict as NSDictionary).isEqual(to: rDict as NSDictionary) { diffState = .identical; return }

        let isDark = cs == .dark
        let task = Task.detached(priority: .userInitiated) { () -> DiffResult? in
            // Pretty-print both sides
            let leftJSON = JSONFormatter.prettyPrint(lDict)
            let rightJSON = JSONFormatter.prettyPrint(rDict)

            // Check cancellation after heavy work
            if Task.isCancelled { return nil }

            let leftLines = leftJSON.components(separatedBy: "\n")
            let rightLines = rightJSON.components(separatedBy: "\n")

            // Line-level diff (Myers) → aligned output
            let aligned = LineDiffer.diff(left: leftLines, right: rightLines)
            if Task.isCancelled { return nil }
            if aligned.allSatisfy({ $0.status == .context }) { return nil }

            // Summary
            var added = 0, removed = 0, modified = 0
            for line in aligned {
                switch line.status {
                case .added: added += 1
                case .removed: removed += 1
                case .modified: modified += 1
                case .context: break
                }
            }
            let total = added + removed + modified
            let summary = "\(total) change\(total == 1 ? "" : "s")  ·  \(added) added  ·  \(removed) removed  ·  \(modified) modified"

            // Change indices: first row of each contiguous change hunk
            var changeIndices: [Int] = []
            for (i, line) in aligned.enumerated() {
                if line.status != .context {
                    if i == 0 || aligned[i - 1].status == .context {
                        changeIndices.append(i)
                    }
                }
            }

            if Task.isCancelled { return nil }

            // Build attributed strings
            let la = DiffAttrBuilder.build(aligned: aligned, isLeft: true, isDark: isDark)
            if Task.isCancelled { return nil }
            let ra = DiffAttrBuilder.build(aligned: aligned, isLeft: false, isDark: isDark)

            return DiffResult(leftAttr: la, rightAttr: ra, summary: summary, changeIndices: changeIndices)
        }
        diffTask = task

        let result = await task.value

        guard !Task.isCancelled else { return }
        if let result {
            currentChange = 0
            diffState = .ready(result)
            if !result.changeIndices.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    syncCoordinator.jumpToRow(result.changeIndices[0])
                }
            }
        } else { diffState = .identical }
    }
}

// MARK: - Attributed string builder

private enum DiffAttrBuilder {

    static func build(aligned: [AlignedDiffLine], isLeft: Bool, isDark: Bool) -> NSAttributedString {
        let baseFont: NSFont = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let baseFg: NSColor = isDark ? NSColor(calibratedWhite: 0.88, alpha: 1) : NSColor(calibratedWhite: 0.12, alpha: 1)
        let numFg: NSColor = isDark ? NSColor(calibratedWhite: 0.40, alpha: 1) : NSColor(calibratedWhite: 0.60, alpha: 1)
        let sepFg: NSColor = isDark ? NSColor(calibratedWhite: 0.25, alpha: 1) : NSColor(calibratedWhite: 0.82, alpha: 1)
        let blankBg: NSColor = isDark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.95, alpha: 1)

        // Build plain text: "NNNNN | content" per line
        // Unified row index on BOTH panels — same row = same number, like a single document.
        var plain = ""
        plain.reserveCapacity(aligned.count * 50)
        for (i, line) in aligned.enumerated() {
            if i > 0 { plain += "\n" }
            let text = isLeft ? line.leftText : line.rightText
            plain += String(format: "%5d | ", i + 1)
            plain += text
        }

        // Fixed line height ensures both panels have identical pixel height per row — critical for scroll sync.
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.minimumLineHeight = 14
        paraStyle.maximumLineHeight = 14
        paraStyle.lineSpacing = 0
        paraStyle.paragraphSpacing = 0
        paraStyle.paragraphSpacingBefore = 0

        let result = NSMutableAttributedString(string: plain, attributes: [
            .font: baseFont, .foregroundColor: baseFg, .paragraphStyle: paraStyle
        ])
        let ns = plain as NSString
        let len = ns.length

        // Walk lines: apply line numbers, diff backgrounds, syntax colors
        var pos = 0; var rowIdx = 0
        while pos < len {
            var lineEnd = pos; var ce = pos
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &ce, for: NSRange(location: pos, length: 0))
            if lineEnd <= pos { lineEnd = min(pos + 1, len) }
            let range = NSRange(location: pos, length: lineEnd - pos)

            // Line number styling
            if lineEnd - pos >= 8 {
                result.addAttribute(.foregroundColor, value: numFg, range: NSRange(location: pos, length: 6))
                result.addAttribute(.foregroundColor, value: sepFg, range: NSRange(location: pos + 6, length: 2))
            }

            // Diff background
            if rowIdx < aligned.count {
                let line = aligned[rowIdx]
                let hasContent = isLeft ? (line.leftLineNum != nil) : (line.rightLineNum != nil)

                if !hasContent {
                    // Blank placeholder row — dim background
                    result.addAttribute(.backgroundColor, value: blankBg, range: range)
                } else {
                    switch line.status {
                    case .removed where isLeft:
                        result.addAttribute(.backgroundColor, value: removedBg(isDark), range: range)
                    case .added where !isLeft:
                        result.addAttribute(.backgroundColor, value: addedBg(isDark), range: range)
                    case .modified:
                        result.addAttribute(.backgroundColor, value: modifiedBg(isDark), range: range)
                    default: break
                    }
                }
            }

            // Syntax coloring
            syntaxColor(result, ns: ns, start: pos, ce: ce, off: 8, isDark: isDark)

            pos = lineEnd; rowIdx += 1
        }

        // Return mutable directly — DiffTextView only reads, no need for an immutable copy
        // that doubles memory.
        return result
    }

    // MARK: Diff colors

    private static func removedBg(_ isDark: Bool) -> NSColor {
        isDark ? NSColor(calibratedRed: 0.60, green: 0.10, blue: 0.10, alpha: 0.50)
               : NSColor(calibratedRed: 1.00, green: 0.85, blue: 0.85, alpha: 1.00)
    }
    private static func addedBg(_ isDark: Bool) -> NSColor {
        isDark ? NSColor(calibratedRed: 0.08, green: 0.45, blue: 0.15, alpha: 0.50)
               : NSColor(calibratedRed: 0.85, green: 1.00, blue: 0.87, alpha: 1.00)
    }
    private static func modifiedBg(_ isDark: Bool) -> NSColor {
        isDark ? NSColor(calibratedRed: 0.65, green: 0.45, blue: 0.05, alpha: 0.65)
               : NSColor(calibratedRed: 1.00, green: 0.90, blue: 0.60, alpha: 1.00)
    }

    // MARK: Syntax coloring

    private static func syntaxColor(_ m: NSMutableAttributedString, ns: NSString, start: Int, ce: Int, off: Int, isDark: Bool) {
        let kC: NSColor = isDark ? NSColor(calibratedRed: 0.40, green: 0.80, blue: 1.00, alpha: 1) : NSColor(calibratedRed: 0.00, green: 0.32, blue: 0.80, alpha: 1)
        let sC: NSColor = isDark ? NSColor(calibratedRed: 0.92, green: 0.65, blue: 0.35, alpha: 1) : NSColor(calibratedRed: 0.62, green: 0.22, blue: 0.00, alpha: 1)
        let nC: NSColor = isDark ? NSColor(calibratedRed: 0.65, green: 0.92, blue: 0.48, alpha: 1) : NSColor(calibratedRed: 0.06, green: 0.44, blue: 0.06, alpha: 1)
        let bC: NSColor = isDark ? NSColor(calibratedRed: 0.82, green: 0.52, blue: 0.98, alpha: 1) : NSColor(calibratedRed: 0.48, green: 0.08, blue: 0.72, alpha: 1)
        let uC: NSColor = isDark ? NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.55, alpha: 1) : NSColor(calibratedRed: 0.46, green: 0.46, blue: 0.46, alpha: 1)
        var p = start + off; if p >= ce { return }
        while p < ce && ns.character(at: p) == 32 { p += 1 }; guard p < ce else { return }
        let c0 = ns.character(at: p)
        if c0 == 34 {
            let qs = p; p += 1
            while p < ce { let c = ns.character(at: p); if c == 92 { p = min(p+2, ce); continue }; if c == 34 { p += 1; break }; p += 1 }
            let qe = p; var q = p; while q < ce && ns.character(at: q) == 32 { q += 1 }
            if q < ce && ns.character(at: q) == 58 {
                m.addAttribute(.foregroundColor, value: kC, range: NSRange(location: qs, length: qe - qs))
                q += 1; while q < ce && ns.character(at: q) == 32 { q += 1 }
                cVal(m, ns: ns, s: q, e: ce, sC: sC, nC: nC, bC: bC, uC: uC)
            } else { m.addAttribute(.foregroundColor, value: sC, range: NSRange(location: qs, length: qe - qs)) }
        } else if c0 != 123 && c0 != 125 && c0 != 91 && c0 != 93 { cVal(m, ns: ns, s: p, e: ce, sC: sC, nC: nC, bC: bC, uC: uC) }
    }

    private static func cVal(_ m: NSMutableAttributedString, ns: NSString, s: Int, e: Int,
                              sC: NSColor, nC: NSColor, bC: NSColor, uC: NSColor) {
        guard s < e else { return }
        var end = e; while end > s { let c = ns.character(at: end-1); if c == 44 || c == 32 { end -= 1 } else { break } }
        guard end > s else { return }; let r = NSRange(location: s, length: end - s)
        switch ns.character(at: s) {
        case 34: m.addAttribute(.foregroundColor, value: sC, range: r)
        case 116, 102: m.addAttribute(.foregroundColor, value: bC, range: r)
        case 110: m.addAttribute(.foregroundColor, value: uC, range: r)
        case 123, 125, 91, 93: break
        default: m.addAttribute(.foregroundColor, value: nC, range: r)
        }
    }
}

// MARK: - Scroll sync coordinator

final class ScrollSyncCoordinator {
    weak var leftScroll: NSScrollView?; weak var rightScroll: NSScrollView?
    weak var leftTV: NSTextView?; weak var rightTV: NSTextView?
    private var isSyncing = false

    /// Both panels have identical line counts → sync by absolute Y offset.
    func peerDidScroll(isLeft: Bool) {
        guard !isSyncing else { return }
        let src = isLeft ? leftScroll : rightScroll
        let tgt = isLeft ? rightScroll : leftScroll
        guard let src, let tgt else { return }
        isSyncing = true
        var origin = tgt.contentView.bounds.origin
        origin.y = src.contentView.bounds.origin.y
        tgt.contentView.setBoundsOrigin(origin)
        isSyncing = false
    }

    /// Jump to a specific row index (0-based) in both panels.
    func jumpToRow(_ row: Int) {
        guard row >= 0 else { return }
        // Search for the line number prefix of the target row
        // Row 0 = line 1, so we search for that line's prefix in the text
        for tv in [leftTV, rightTV].compactMap({ $0 }) {
            let ns = tv.string as NSString
            // Find the Nth newline to get to the row
            var pos = 0
            for _ in 0..<row {
                let r = ns.range(of: "\n", range: NSRange(location: pos, length: ns.length - pos))
                if r.location == NSNotFound { break }
                pos = r.location + 1
            }
            // Expand to full line
            var ls = pos; var le = pos
            ns.getLineStart(&ls, end: &le, contentsEnd: nil, for: NSRange(location: pos, length: 0))
            let full = NSRange(location: ls, length: le - ls)
            tv.scrollRangeToVisible(full)
            tv.showFindIndicator(for: full)
        }
    }
}

// MARK: - Diff text view

private struct DiffTextView: NSViewRepresentable {
    let attrText: NSAttributedString; let syncCoord: ScrollSyncCoordinator; let isLeft: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.drawsBackground = true; sv.backgroundColor = .textBackgroundColor
        sv.hasVerticalScroller = true; sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true; sv.borderType = .noBorder

        let tv = NSTextView()
        tv.isEditable = false; tv.isSelectable = true; tv.isRichText = true
        tv.drawsBackground = false; tv.importsGraphics = false
        tv.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.usesFindBar = true; tv.isIncrementalSearchingEnabled = true

        tv.textStorage?.setAttributedString(attrText)
        sv.documentView = tv

        if isLeft { syncCoord.leftScroll = sv; syncCoord.leftTV = tv }
        else { syncCoord.rightScroll = sv; syncCoord.rightTV = tv }

        sv.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.clipped(_:)),
                                               name: NSView.boundsDidChangeNotification, object: sv.contentView)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(isLeft: isLeft, syncCoord: syncCoord) }

    final class Coordinator: NSObject {
        let isLeft: Bool; let syncCoord: ScrollSyncCoordinator
        init(isLeft: Bool, syncCoord: ScrollSyncCoordinator) { self.isLeft = isLeft; self.syncCoord = syncCoord }
        @objc func clipped(_ note: Notification) { syncCoord.peerDidScroll(isLeft: isLeft) }
    }
}
