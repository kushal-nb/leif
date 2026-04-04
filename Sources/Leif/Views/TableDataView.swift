import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let leifFocusSearch = Notification.Name("leifFocusSearch")
}

// MARK: - Array field detected in a payload
struct ArrayField: Identifiable {
    let id = UUID()
    let keyPath: String          // e.g. "items" or "payload › items"
    let rows: [[String: Any]]
    let columns: [String]        // union of keys across all rows, sorted
}

/// Scan an OrderedFields payload for arrays of objects (direct + string-encoded JSON).
/// Recurses into nested objects (e.g. `payload.items`). `maxRecursionDepth` caps work on huge trees.
func extractArrayFields(from fields: OrderedFields, parentKey: String = "", maxRecursionDepth: Int = 64) -> [ArrayField] {
    var result: [ArrayField] = []
    guard maxRecursionDepth > 0 else { return result }

    for pair in fields.pairs {
        let label = parentKey.isEmpty ? pair.key : "\(parentKey) › \(pair.key)"

        let resolved = resolveValue(pair.value)

        switch resolved {
        case let arr as [Any]:
            let objRows = arr.compactMap { $0 as? [String: Any] }
            if !objRows.isEmpty {
                result.append(ArrayField(keyPath: label,
                                         rows: objRows,
                                         columns: unionKeys(objRows)))
            }
        case let dict as [String: Any]:
            let nested = OrderedFields(dict)
            result += extractArrayFields(from: nested, parentKey: label,
                                         maxRecursionDepth: maxRecursionDepth - 1)
        default:
            break
        }
    }
    return result
}

private func resolveValue(_ value: Any) -> Any {
    if let str = value as? String {
        let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if (t.hasPrefix("{") || t.hasPrefix("[")) && t.count > 2,
           let data = t.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            return parsed
        }
    }
    return value
}

private func unionKeys(_ rows: [[String: Any]]) -> [String] {
    // Collect all keys across all rows, then sort once — O(n×m) not O(n×m log m)
    var seen = Set<String>()
    for row in rows { seen.formUnion(row.keys) }
    return seen.sorted()
}

// MARK: - Table picker + table wrapper

struct TablePayloadView: View {
    let arrayFields: [ArrayField]
    let searchText: String
    @State private var selectedIdx = 0

    var body: some View {
        VStack(spacing: 0) {
            // Array picker bar
            HStack(spacing: 8) {
                Text("Array:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if arrayFields.count == 1 {
                    Text(arrayFields[0].keyPath)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                } else {
                    Picker("", selection: $selectedIdx) {
                        ForEach(arrayFields.indices, id: \.self) { i in
                            Text(arrayFields[i].keyPath).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                Spacer()
                let af = arrayFields[safe: selectedIdx]
                Text("\(af?.rows.count ?? 0) rows · \(af?.columns.count ?? 0) cols")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                if let af = af {
                    // Copy clipboard (TSV)
                    Button(action: { copyTSV(af) }) {
                        Label("Copy", systemImage: "doc.on.clipboard")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    // Download CSV file
                    Button(action: { downloadCSV(af) }) {
                        Label("Download CSV", systemImage: "arrow.down.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if let af = arrayFields[safe: selectedIdx] {
                DynamicTableView(rows: af.rows, columns: af.columns, searchText: searchText)
            }
        }
    }

    // MARK: - Copy TSV to clipboard
    private func copyTSV(_ af: ArrayField) {
        var lines = [af.columns.joined(separator: "\t")]
        for row in af.rows {
            let values = af.columns.map { cellString(row[$0]) }
            lines.append(values.joined(separator: "\t"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Save CSV file via save panel
    private func downloadCSV(_ af: ArrayField) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.canCreateDirectories = true
        let safeName = af.keyPath
            .replacingOccurrences(of: " › ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        panel.nameFieldStringValue = "\(safeName).csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? buildCSV(af).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func buildCSV(_ af: ArrayField) -> String {
        func escape(_ s: String) -> String {
            guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
            else { return s }
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        var lines = [af.columns.map(escape).joined(separator: ",")]
        for row in af.rows {
            lines.append(af.columns.map { escape(cellString(row[$0])) }.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - NSTableView wrapper

struct DynamicTableView: NSViewRepresentable {
    let rows: [[String: Any]]
    let columns: [String]
    let searchText: String

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = ReorderableTableView()
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing  = true
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 20
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.style = .plain
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.gridColor = NSColor.separatorColor

        // Row number column
        let numCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("#"))
        numCol.title = "#"
        numCol.width = 36
        numCol.minWidth = 28
        numCol.maxWidth = 50
        tableView.addTableColumn(numCol)

        for colID in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colID))
            col.title = colID
            col.width = initialWidth(for: colID)
            col.minWidth = 40
            tableView.addTableColumn(col)
        }

        tableView.dataSource = context.coordinator
        tableView.delegate   = context.coordinator
        context.coordinator.tableView = tableView

        let scroll = NSScrollView()
        scroll.documentView  = tableView
        scroll.hasVerticalScroller   = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers    = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tableView = scroll.documentView as? NSTableView else { return }
        let c = context.coordinator
        let dataChanged   = c.rows.count != rows.count || c.columns != columns
        let searchChanged = c.searchText != searchText

        if dataChanged {
            c.rows = []
            tableView.reloadData()

            c.columns = columns
            c.searchText = searchText
            let existing = tableView.tableColumns.map { $0.identifier.rawValue }
            let wanted   = ["#"] + columns
            if existing != wanted {
                for col in tableView.tableColumns { tableView.removeTableColumn(col) }
                let numCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("#"))
                numCol.title = "#"; numCol.width = 36; numCol.minWidth = 28; numCol.maxWidth = 50
                tableView.addTableColumn(numCol)
                for colID in columns {
                    let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colID))
                    col.title = colID
                    col.width = initialWidth(for: colID)
                    col.minWidth = 40
                    tableView.addTableColumn(col)
                }
            }

            c.rows = rows
            tableView.reloadData()
        } else if searchChanged {
            c.searchText = searchText
            tableView.reloadData()
            // Scroll to first matching row
            if !searchText.isEmpty {
                let query = searchText
                let coordinator = c
                DispatchQueue.main.async {
                    for (idx, row) in coordinator.rows.enumerated() {
                        let hit = coordinator.columns.contains {
                            cellString(row[$0]).localizedCaseInsensitiveContains(query)
                        }
                        if hit { tableView.scrollRowToVisible(idx); break }
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rows: rows, columns: columns, searchText: searchText)
    }

    private func initialWidth(for key: String) -> CGFloat {
        let narrow = ["id","type","status","marker","offset","segment_id","fps","fixed_duration","duration"]
        return narrow.contains(key) ? 72 : 130
    }

    // MARK: Coordinator
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [[String: Any]]
        var columns: [String]
        var searchText: String
        weak var tableView: NSTableView?

        init(rows: [[String: Any]], columns: [String], searchText: String) {
            self.rows = rows
            self.columns = columns
            self.searchText = searchText
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let colID = tableColumn?.identifier.rawValue else { return nil }

            let cell: NSTextField
            if let reused = tableView.makeView(withIdentifier: tableColumn!.identifier, owner: nil) as? NSTextField {
                cell = reused
            } else {
                cell = NSTextField()
                cell.identifier    = tableColumn!.identifier
                cell.isBordered    = false
                cell.isEditable    = false
                cell.isSelectable  = true   // allow text selection via mouse
                cell.backgroundColor = .clear
                cell.font          = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                cell.lineBreakMode = .byTruncatingTail
                cell.maximumNumberOfLines = 1
                cell.cell?.wraps   = false
                cell.cell?.isScrollable = true
            }

            if colID == "#" {
                cell.stringValue    = "\(row + 1)"
                cell.textColor      = NSColor.tertiaryLabelColor
                cell.drawsBackground = false
            } else {
                let value = rows[row][colID]
                let str   = cellString(value)
                cell.stringValue = str
                cell.textColor   = cellColor(value)

                // Highlight cells that match the current search term
                if !searchText.isEmpty && str.localizedCaseInsensitiveContains(searchText) {
                    cell.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.30)
                    cell.drawsBackground = true
                } else {
                    cell.drawsBackground = false
                }
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 20 }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
    }
}

// MARK: - Subclass to enable right-click copy + Cmd+F focus-search
final class ReorderableTableView: NSTableView {

    // Cmd+F while table is focused → focus the filter search field
    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        if cmd, event.charactersIgnoringModifiers == "f" {
            NotificationCenter.default.post(name: .leifFocusSearch, object: nil)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        let row = self.row(at: pt)
        let col = self.column(at: pt)
        guard row >= 0, col >= 0 else { return super.menu(for: event) }

        let menu = NSMenu()

        if let cell = view(atColumn: col, row: row, makeIfNecessary: false) as? NSTextField {
            let val = cell.stringValue
            let copyCell = NSMenuItem(title: "Copy \"\(val.prefix(40))\"",
                                      action: #selector(copyValue(_:)),
                                      keyEquivalent: "")
            copyCell.representedObject = val
            copyCell.target = self
            menu.addItem(copyCell)
        }

        let copyRow = NSMenuItem(title: "Copy Row (tab-separated)",
                                 action: #selector(copyRow(_:)),
                                 keyEquivalent: "")
        copyRow.representedObject = NSNumber(value: row)
        copyRow.target = self
        menu.addItem(copyRow)

        return menu
    }

    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let val = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(val, forType: .string)
    }

    @objc private func copyRow(_ sender: NSMenuItem) {
        guard let rowNum = (sender.representedObject as? NSNumber)?.intValue,
              let ds = dataSource as? DynamicTableView.Coordinator else { return }
        let row = ds.rows[rowNum]
        let vals = ds.columns.map { cellString(row[$0]) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(vals.joined(separator: "\t"), forType: .string)
    }
}

// MARK: - Shared helpers
func cellString(_ value: Any?) -> String {
    guard let v = value else { return "" }
    switch v {
    case is NSNull:           return "null"
    case let s as String:     return cellStringForTable(s)
    case let n as NSNumber:
        if n === kCFBooleanTrue  { return "true" }
        if n === kCFBooleanFalse { return "false" }
        return n.stringValue
    case let arr as [Any]:    return "[\(arr.count) items]"
    case let d as [String: Any]: return "{\(d.count) keys}"
    default:                  return "\(v)"
    }
}

private func cellColor(_ value: Any?) -> NSColor {
    guard let v = value else { return .labelColor }
    switch v {
    case let n as NSNumber:
        if n === kCFBooleanTrue  { return NSColor.systemGreen }
        if n === kCFBooleanFalse { return NSColor.systemRed }
        return NSColor.systemBlue
    case is NSNull: return NSColor.tertiaryLabelColor
    case let s as String where s.isEmpty: return NSColor.tertiaryLabelColor
    default: return NSColor.labelColor
    }
}

/// Table cells are single-line; summarize huge string-encoded JSON instead of one escaped blob.
private func cellStringForTable(_ s: String) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.count > 200,
          (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
          trimmed.count > 2,
          let data = trimmed.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) else {
        return s
    }
    switch obj {
    case let d as [String: Any]:
        return "JSON object · \(d.count) keys · \(s.count) chars"
    case let a as [Any]:
        return "JSON array · \(a.count) items · \(s.count) chars"
    default:
        return s
    }
}

// MARK: - Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
