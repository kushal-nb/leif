import SwiftUI
import AppKit

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
        textView.isVerticallyResizable = true
        // autoresizingMask is set per-mode inside applyWrapping
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        applyWrapping(to: textView, scrollView: scrollView)
        applyFieldChrome(scrollView: scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let sel = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = sel
        }
        applyWrapping(to: textView, scrollView: scrollView)
        applyFieldChrome(scrollView: scrollView, textView: textView)
    }

    /// Light: white paper + gray gutter so the edit surface is obvious. Dark: system text field colors.
    private func applyFieldChrome(scrollView: NSScrollView, textView: NSTextView) {
        textView.insertionPointColor = .labelColor
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
            // Non-wrapping: text view grows rightward; scroll view provides horizontal scroll
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []          // must NOT pin to scroll view width
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
        init(_ parent: RawLogEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
