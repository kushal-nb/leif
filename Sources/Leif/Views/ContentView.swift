import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var vm = LogViewModel()
    @State private var wrapInput = false
    @State private var unixEntries: [UnixEntry] = [UnixEntry()]
    @AppStorage("darkMode") private var darkMode = true
    @Environment(\.colorScheme) var colorScheme

    private struct UnixEntry: Identifiable {
        let id = UUID()
        /// Optional reminder of what this Unix time refers to (for you, not converted).
        var note: String = ""
        var input: String = ""
    }

    private func convertUnix(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let value = Double(t) else { return nil }
        let seconds = value > 1e10 ? value / 1000.0 : value
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Date(timeIntervalSince1970: seconds))
    }

    var body: some View {
        HSplitView {
            inputPanel
                .frame(minWidth: 360, idealWidth: 420, maxWidth: 520)
                // Stronger vertical divider — overlay a stripe on the trailing edge
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(colorScheme == .dark
                              ? Color.white.opacity(0.10)
                              : Color.black.opacity(0.22))
                        .frame(width: 1)
                }
            outputPanel
                .frame(minWidth: 400)
        }
        .frame(minWidth: 820, minHeight: 520)
        .onChange(of: darkMode) { dark in
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
        .onAppear {
            NSApp.appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua)
        }
    }

    // A divider that's clearly visible in both light and dark mode
    private var panelDivider: some View {
        Rectangle()
            .fill(colorScheme == .dark
                  ? Color.white.opacity(0.09)
                  : Color.black.opacity(0.14))
            .frame(height: 1)
    }

    // MARK: Left: paste area
    private var inputPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Paste Logs")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(colorScheme == .dark ? .secondary : .primary.opacity(0.75))
                Spacer()
                // Light/dark toggle
                Button(action: { darkMode.toggle() }) {
                    Image(systemName: darkMode ? "sun.min" : "moon")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(darkMode ? "Switch to light mode" : "Switch to dark mode")

                // Wrap toggle
                Button(action: { wrapInput.toggle() }) {
                    Image(systemName: wrapInput ? "text.word.spacing" : "arrow.right.to.line")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(wrapInput ? .accentColor : .secondary)
                .help(wrapInput ? "Disable wrap (scroll)" : "Enable wrap")

                if !vm.rawText.isEmpty {
                    Button("Clear") { vm.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Button(action: vm.parse) {
                    Label("Parse", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                // Bordered keeps a dark label in light mode; prominent used white on accent over the tinted bar.
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    // In light mode: blurred app icon gives a colorful ambient background
                    if colorScheme == .light {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 22)
                            .saturation(1.6)
                            .opacity(0.28)
                            .clipped()
                        // Subtle white wash so text stays readable
                        Color.white.opacity(0.45)
                        // Pink tint
                        Color.pink.opacity(0.10)
                    }
                }
            }

            panelDivider

            // Editor fills the column; chrome comes from NSScrollView/NSTextView (no extra nested box).
            RawLogEditor(text: $vm.rawText, wrapping: wrapInput, colorScheme: colorScheme)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            panelDivider

            // Status bar
            HStack(spacing: 6) {
                if vm.isParsingBusy {
                    ProgressView().scaleEffect(0.5)
                    Text("Wrangling bytes…").font(.system(size: 11)).foregroundColor(.secondary)
                } else if !vm.entries.isEmpty {
                    Text("\(vm.entries.count) suspects").font(.system(size: 11)).foregroundColor(.secondary)
                } else {
                    Text("⌘↵ to parse  ·  Ctrl+Shift+Space to summon")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            panelDivider

            // Unix → UTC converter
            unixConverterPanel
        }
    }

    // MARK: Right: parsed results + detail
    @State private var detailHeight: CGFloat = 0
    @State private var isDraggingDetail = false
    @State private var dragStartDetailHeight: CGFloat = 0

    private var outputPanel: some View {
        VStack(spacing: 0) {
            LogListView(entries: vm.entries, selected: $vm.selectedEntry, filterText: $vm.filterText)
                .frame(minHeight: 100, maxHeight: .infinity)

            // Draggable divider
            ZStack {
                Rectangle()
                    .fill(isDraggingDetail
                          ? Color.accentColor.opacity(0.30)
                          : (colorScheme == .dark
                             ? Color.white.opacity(0.07)
                             : Color.black.opacity(0.10)))
                    .frame(height: 8)
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(isDraggingDetail ? Color.accentColor : Color(nsColor: .secondaryLabelColor))
                            .frame(width: 4, height: 4)
                    }
                }
            }
            .frame(height: 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        if !isDraggingDetail {
                            isDraggingDetail = true
                            dragStartDetailHeight = detailHeight
                        }
                        detailHeight = max(0, dragStartDetailHeight - v.translation.height)
                    }
                    .onEnded { _ in isDraggingDetail = false }
            )
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() }
                else { NSCursor.pop() }
            }

            detailPane
                .frame(height: detailHeight)
                .clipped()
        }
        .onChange(of: vm.selectedEntry?.id) { _ in
            if vm.selectedEntry != nil, detailHeight < 80 {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    detailHeight = 280
                }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let entry = vm.selectedEntry {
            LogDetailView(entry: entry, cache: vm.payloadCache, searchText: vm.filterText)
        } else {
            VStack {
                Spacer()
                Image(systemName: "person.fill.questionmark")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.45))
                Text("Pick a suspect to interrogate")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                Text("select any entry from the list")
                    .foregroundColor(.secondary.opacity(0.55))
                    .font(.system(size: 11))
                Spacer()
            }
        }
    }

    // MARK: - Unix → UTC converter panel
    private var unixConverterPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("Unix → UTC")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary)
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        unixEntries.append(UnixEntry())
                    }
                } label: {
                    Label("Add row", systemImage: "plus")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.accentColor)
                .help("Add another timestamp row")
            }

            // Use ForEach($unixEntries) — not enumerated() + manual Bindings. The latter can trip
            // SwiftUI’s indexed Binding path during animated inserts/removes (Array subscript trap on main thread).
            VStack(alignment: .leading, spacing: 10) {
                ForEach($unixEntries) { $entry in
                    UnixTimestampRow(
                        note: $entry.note,
                        input: $entry.input,
                        showRemove: unixEntries.count > 1,
                        convert: convertUnix,
                        onRemove: {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                                unixEntries.removeAll { $0.id == entry.id }
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.82), value: unixEntries.map(\.id))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// One row: note + Unix side by side, UTC + remove on the right (compact).
    private struct UnixTimestampRow: View {
        @Binding var note: String
        @Binding var input: String
        let showRemove: Bool
        let convert: (String) -> String?
        let onRemove: () -> Void
        @Environment(\.colorScheme) private var colorScheme

        private var utc: String? { convert(input) }

        /// Soft pink wash behind the two editable fields so they read as one “type here” zone.
        private var inputWellFill: Color {
            colorScheme == .dark
                ? Color.pink.opacity(0.16)
                : Color.pink.opacity(0.11)
        }

        private var inputWellStroke: Color {
            Color.pink.opacity(colorScheme == .dark ? 0.38 : 0.28)
        }

        var body: some View {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    TextField("Note (optional)", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(minWidth: 72, idealWidth: 120, maxWidth: 160, alignment: .leading)
                        .help("Not converted — only helps you remember this row later.")

                    TextField("Unix s/ms", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 108, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(inputWellFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(inputWellStroke, lineWidth: 1)
                )

                Group {
                    if let t = utc {
                        Text(t)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .transition(.opacity)
                    } else {
                        Text("—")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.4))
                    }
                }
                .frame(minWidth: 96, maxWidth: .infinity, alignment: .leading)

                if showRemove {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove row")
                }
            }
        }
    }
}

// RawLogEditor → Views/RawLogEditor.swift
// PayloadCache, LogViewModel, buildEntryPayload → ViewModels/LogViewModel.swift
