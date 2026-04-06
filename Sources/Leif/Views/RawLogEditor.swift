import SwiftUI
import AppKit

extension Notification.Name {
    static let leifFlushEditor = Notification.Name("leifFlushEditor")
}

// MARK: - Raw log text editor (non-wrapping by default, horizontally scrollable)

struct RawLogEditor: NSViewRepresentable {
    @Binding var text: String
    var wrapping: Bool
    var colorScheme: ColorScheme

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        applyWrapping(to: textView, scrollView: scrollView)
        applyFieldChrome(scrollView: scrollView, textView: textView)

        // Listen for explicit flush from teardownOldState — directly clears
        // the NSTextView without waiting for SwiftUI's update cycle.
        NotificationCenter.default.addObserver(context.coordinator,
            selector: #selector(Coordinator.forceFlush(_:)),
            name: .leifFlushEditor, object: nil)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let tvLen = (textView.string as NSString).length
        let bindLen = (text as NSString).length
        if tvLen != bindLen || textView.string != text {
            let sel = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = sel
            if text.isEmpty {
                DispatchQueue.main.async {
                    scrollView.window?.makeFirstResponder(textView)
                }
            }
        }
        applyWrapping(to: textView, scrollView: scrollView)
        applyFieldChrome(scrollView: scrollView, textView: textView)
    }

    private func applyFieldChrome(scrollView: NSScrollView, textView: NSTextView) {
        textView.insertionPointColor = colorScheme == .dark
            ? NSColor(calibratedWhite: 0.95, alpha: 1)
            : NSColor(calibratedWhite: 0.10, alpha: 1)
        scrollView.drawsBackground = true
        let clip = scrollView.contentView
        clip.drawsBackground = true
        if colorScheme == .light {
            textView.backgroundColor = .white
            let gutter = NSColor(calibratedWhite: 0.93, alpha: 1)
            scrollView.backgroundColor = gutter
            clip.backgroundColor = gutter
        } else {
            let bg = NSColor.textBackgroundColor
            textView.backgroundColor = bg
            scrollView.backgroundColor = bg
            clip.backgroundColor = bg
        }
    }

    private func applyWrapping(to textView: NSTextView, scrollView: NSScrollView) {
        if wrapping {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                      height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = CGSize(
                width: scrollView.contentSize.width,
                height: .greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = false
        } else {
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                      height: CGFloat.greatestFiniteMagnitude)
            textView.minSize = NSSize(width: 0,
                                      height: scrollView.contentSize.height)
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RawLogEditor
        weak var textView: NSTextView?
        init(_ parent: RawLogEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isFlushing else { return }
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        /// Immediately clear the NSTextView text storage + layout manager caches.
        /// Uses isFlushing flag to prevent textDidChange from zeroing the binding.
        var isFlushing = false

        @objc func forceFlush(_ notification: Notification) {
            guard let tv = textView else { return }
            isFlushing = true
            tv.textStorage?.setAttributedString(NSAttributedString())
            isFlushing = false
        }
    }
}
