import SwiftUI

struct LogListView: View {
    let entries: [LogEntry]
    @Binding var selected: LogEntry?
    @Binding var filterText: String
    @State private var filterLevel: LogLevel? = nil
    @State private var filteredEntries: [LogEntry] = []
    @State private var diffMarked: LogEntry? = nil
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) var colorScheme

    // Key that uniquely identifies the current filter state.
    // Uses the first entry's UUID so that clear→reload with the same count
    // still produces a different key and re-triggers the filter task.
    private var filterKey: String {
        let sentinel = entries.first.map { $0.id.uuidString } ?? "empty"
        return "\(sentinel)-\(filterText)-\(filterLevel?.rawValue ?? "all")"
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .onReceive(NotificationCenter.default.publisher(for: .leifFocusSearch)) { _ in
                    searchFocused = true
                }
            Divider()
            diffMarkedBanner
            if filteredEntries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: entries.isEmpty ? "scroll" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(entries.isEmpty
                         ? "It's quiet dude, paste some logs"
                         : "Nothing survived the filter")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredEntries, selection: Binding(
                    get: { selected?.id },
                    set: { id in selected = filteredEntries.first { $0.id == id } }
                )) { entry in
                    LogRowView(entry: entry, isDiffMarked: diffMarked?.id == entry.id)
                        .tag(entry.id)
                        .contextMenu { diffContextMenu(for: entry) }
                }
                .listStyle(.plain)
            }
        }
        // Child `Task` (not `detached`). Cooperative `Task.isCancelled` checks so ⌘Q / teardown can bail quickly.
        .task(id: filterKey) {
            let snap  = entries
            let text  = filterText.leifClampedSearch(maxLength: LeifSearchLimits.listFilter)
            let level = filterLevel
            if text.isEmpty && level == nil {
                filteredEntries = snap
                return
            }
            let maybe = await Task(priority: .userInitiated) { () -> [LogEntry]? in
                var out: [LogEntry] = []
                for (i, entry) in snap.enumerated() {
                    if i % 384 == 0, Task.isCancelled { return nil }
                    let levelOK = level == nil || entry.level == level
                    let hit = levelOK && (
                        entry.message.range(of: text, options: .caseInsensitive) != nil ||
                        entry.caller?.range(of: text, options: .caseInsensitive) != nil ||
                        entry.rawContent.range(of: text, options: .caseInsensitive) != nil
                    )
                    if hit { out.append(entry) }
                }
                return out
            }.value
            guard let result = maybe, !Task.isCancelled else { return }
            filteredEntries = result
        }
        // Clear diff mark when a completely new parse is loaded
        .onChange(of: entries.first?.id) { _ in diffMarked = nil }
    }

    // MARK: - Diff context menu

    @ViewBuilder
    private func diffContextMenu(for entry: LogEntry) -> some View {
        if !entry.hasPayload {
            Text("No JSON payload — cannot diff")
                .foregroundColor(.secondary)
        } else if let marked = diffMarked {
            if marked.id == entry.id {
                Button("Unmark from Diff") { diffMarked = nil }
            } else {
                Button("Diff  A → B") {
                    DiffWindowController.shared.show(
                        left: marked, right: entry,
                        isDark: colorScheme == .dark
                    )
                    diffMarked = nil
                }
                Divider()
                Button("Change Marked Entry to This") { diffMarked = entry }
                Button("Unmark") { diffMarked = nil }
            }
        } else {
            Button("Mark as  A  for Diff") { diffMarked = entry }
        }
    }

    // MARK: - Marked-entry banner

    @ViewBuilder
    private var diffMarkedBanner: some View {
        if let marked = diffMarked {
            HStack(spacing: 7) {
                // "A" label
                Text("A")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.red.opacity(colorScheme == .dark ? 0.25 : 0.14))
                    .foregroundColor(colorScheme == .dark ? Color(red: 1.0, green: 0.4, blue: 0.4) : Color(red: 0.75, green: 0.1, blue: 0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                LevelBadge(level: marked.level)

                if !marked.displayTimestamp.isEmpty {
                    Text(marked.displayTimestamp)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text(marked.message)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                Spacer()

                Text("Right-click another JSON row → Diff A → B")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Button(action: { diffMarked = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.red.opacity(colorScheme == .dark ? 0.08 : 0.05))
            Divider()
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            TextField("Search…", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(colorScheme == .light ? Color.white : Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.12), lineWidth: 1)
                )
            Divider().frame(height: 16)
            levelPicker
            if !filterText.isEmpty || filterLevel != nil {
                Button(action: { filterText = ""; filterLevel = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text("\(filteredEntries.count)/\(entries.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 7)
    }

    private var levelPicker: some View {
        Menu {
            Button("All levels") { filterLevel = nil }
            Divider()
            ForEach(LogLevel.allCases.filter { $0 != .unknown }, id: \.self) { level in
                Button(level.rawValue) { filterLevel = level }
            }
        } label: {
            HStack(spacing: 3) {
                if let lvl = filterLevel {
                    LevelBadge(level: lvl)
                } else {
                    Text("Level")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Row view

struct LogRowView: View {
    let entry: LogEntry
    var isDiffMarked: Bool = false
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            // Diff-marked dot
            if isDiffMarked {
                Circle()
                    .fill(colorScheme == .dark ? Color(red: 1.0, green: 0.4, blue: 0.4) : Color(red: 0.75, green: 0.1, blue: 0.1))
                    .frame(width: 6, height: 6)
            } else {
                Spacer().frame(width: 6)
            }

            LevelBadge(level: entry.level)
                .frame(width: 36)

            Text(entry.displayTimestamp)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(colorScheme == .dark ? .secondary : Color.primary.opacity(0.72))
                .frame(width: 88, alignment: .leading)
                .lineLimit(1)

            if let caller = entry.caller {
                Text(caller)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(colorScheme == .dark
                        ? Color(nsColor: .systemTeal).opacity(0.85)
                        : Color(red: 0.0, green: 0.48, blue: 0.55))
                    .lineLimit(1)
                    .frame(width: 148, alignment: .leading)
            }
            Text(entry.message)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if entry.hasPayload {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}
