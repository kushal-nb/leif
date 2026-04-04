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
        guard !t.isEmpty, let value = Double(t), value.isFinite else { return nil }
        let seconds = abs(value) > 1e10 ? value / 1000.0 : value
        // Reject timestamps outside reasonable range (year 0001 to 9999)
        guard seconds >= -62135596800 && seconds <= 253402300799 else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fmt.timeZone = TimeZone(abbreviation: "UTC")!
        return fmt.string(from: Date(timeIntervalSince1970: seconds))
    }

    var body: some View {
        HSplitView {
            inputPanel
                .frame(minWidth: 360, idealWidth: 420, maxWidth: 520)
                // Stronger vertical divider - overlay a stripe on the trailing edge
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

            // Unix → UTC converter — compact rows, scrolls when exceeding 2 rows
            ScrollView(.vertical, showsIndicators: true) {
                unixConverterPanel
            }
            .frame(maxHeight: 70)
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

    // MARK: - Unix → UTC converter panel — compact inline rows
    private var unixConverterPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(unixEntries.enumerated()), id: \.element.id) { idx, entry in
                HStack(spacing: 6) {
                    if idx == 0 {
                        Image(systemName: "clock.arrow.2.circlepath")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    TextField("note", text: Binding(
                        get: { unixEntries[safe: idx]?.note ?? "" },
                        set: { if idx < unixEntries.count { unixEntries[idx].note = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                    .frame(width: 80)

                    TextField("unix s/ms", text: Binding(
                        get: { unixEntries[safe: idx]?.input ?? "" },
                        set: { if idx < unixEntries.count { unixEntries[idx].input = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 100)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)

                    if let t = convertUnix(entry.input) {
                        Text(t)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                    } else {
                        Text("-")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.3))
                    }
                    Spacer(minLength: 0)
                    if unixEntries.count > 1 {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                unixEntries.removeAll { $0.id == entry.id }
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    if idx == unixEntries.count - 1 {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                unixEntries.append(UnixEntry())
                            }
                        } label: {
                            Label("Add", systemImage: "plus")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Add another timestamp row")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// RawLogEditor → Views/RawLogEditor.swift
// PayloadCache, LogViewModel, buildEntryPayload → ViewModels/LogViewModel.swift
