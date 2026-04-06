# Leif — Kubernetes Log Inspector

A compact macOS menu-bar utility for inspecting Kubernetes/Loki logs. Paste any log format — CRI, Zap, JSON, plain text — and instantly get structured views, JSON diffs, table exports, and more.

## Features

- **Global hotkey** `Ctrl+Shift+Space` — show/hide from anywhere
- **CRI chunking** — reconstructs `P` (partial) / `F` (final) split log lines automatically
- **Multi-format parsing** — Kubernetes CRI, Loki 2-line, Zap dev, plain JSON, pretty-printed JSON
- **JSON tree view** — collapsible key/value tree with syntax colouring and search
- **JSON raw view** — pretty-printed with syntax highlighting (fast O(n) path for large payloads)
- **Side-by-side JSON diff** — GitHub-style line-level diff with aligned panels, change navigation, background colors
- **Table extraction** — detects arrays of objects, renders as sortable table, exports TSV/CSV
- **Filter bar** — text search + level filter across all entries
- **Unix timestamp converter** — convert Unix seconds/milliseconds to UTC (multi-row)
- **Auto-parse** — parses automatically after pasting; or press `Cmd+Return`
- **Copy button** — copies pretty JSON or raw line to clipboard
- **Performance monitor** — real-time memory (footprint + RSS) and CPU in the toolbar
- **Keyboard navigation** — arrow keys in log list, Tab/Enter flow in Unix converter
- **Menu bar icon** — lives in the status bar, never clutters the Dock

## Install

```bash
bash build-app.sh
cp -r dist/Leif.app /Applications/
open /Applications/Leif.app
```

Share `dist/Leif.app` with teammates — works on any Mac running macOS 13+.
No code signing account needed (ad-hoc signed).

> **First launch on a teammate's Mac:** right-click the app, then Open, then Open again (to bypass Gatekeeper once).

## Usage

1. In terminal or Loki UI, copy your log lines
2. Press `Ctrl+Shift+Space` or click the menu bar icon
3. Paste into the left panel — entries appear automatically
4. Click a row to see the detail pane (Tree / JSON / Raw tabs)
5. Use the filter bar to search or filter by level
6. Right-click a row to mark as "A", then right-click another to "Diff A vs B"

### JSON Diff

1. In the log list, right-click any row and select **"Mark as A for Diff"**
2. Right-click a second row and select **"Diff A vs B"**
3. A side-by-side diff window opens showing:
   - **Red background** — lines removed (only in A)
   - **Green background** — lines added (only in B)
   - **Orange/amber background** — lines modified (different values)
   - **Gray background** — blank placeholders (alignment padding)
4. Use **Cmd+Down / Cmd+Up** or the chevron buttons to jump between changes
5. Use **Cmd+F** to search within either panel (native AppKit find bar)
6. Press **Esc** to close

The diff uses a **Myers line-level algorithm** on pretty-printed JSON — the same approach as `git diff` and GitHub. Both panels have identical row counts with blank padding, so they scroll in perfect sync.

### Table Export

When a log entry contains arrays of objects (e.g., `"items": [{...}, {...}]`), the detail pane shows a **Table** tab:
- Columns are auto-detected from the union of all object keys
- **Copy as TSV** — paste into spreadsheets
- **Download as CSV** — RFC 4180 compliant
- Right-click rows to copy individual cells or full rows

## Log Formats Supported

| Format | Example |
|--------|---------|
| Kubernetes CRI full | `2026-03-03T19:01:59Z stdout F {"level":"info",...}` |
| CRI partial chunks | `stdout P chunk1` + `stdout F chunk2` → auto-reconstructed |
| Loki 2-line header | Timestamp line followed by content line |
| Zap dev format | `2026-03-03T19:01:59.053Z    DEBUG    caller.go:42    message    {…}` |
| Plain JSON object | `{"level":"info","msg":"hello","ts":"…"}` |
| Plain JSON array | `[{...}, {...}]` — each object becomes an entry |
| Pretty-printed JSON | Multi-line JSON document (auto-detected) |
| Go struct fmt | `&{Field:Value Field:Value}` — auto-parsed into key-value pairs |
| Plain text | Anything else — shown as-is with unknown level |

### Multi-line Log Reconstruction

Leif handles multi-line log formats in a single pass using a state machine:

**Kubernetes CRI partial/final chunks:**
When container runtimes split long log lines, they emit `P` (partial) chunks followed by a `F` (final) chunk. Leif automatically reconstructs these:
```
2026-03-03T19:01:59Z stdout P {"level":"info","msg":"this is a very lo
2026-03-03T19:01:59Z stdout P ng message that was split across multipl
2026-03-03T19:01:59Z stdout F e chunks by the container runtime"}
```
All three lines become a single log entry with the full JSON payload reassembled.

**Loki 2-line header format:**
When copying from Loki/Grafana, logs often come as two lines — a timestamp header followed by the actual content:
```
2026-03-22T09:00:00.000Z
{"level":"info","msg":"something happened","data":{"key":"value"}}
```
Leif detects the timestamp-only header line (fast pre-check: starts with a year digit like `2026-`, then regex validation), stores the timestamp, and combines it with the next line to produce a single entry. The timestamp from the header becomes the entry's `k8sTimestamp`.

**Pretty-printed JSON documents:**
If the entire pasted text is a valid JSON object or array, Leif detects it as a whole document rather than trying to parse line-by-line:
```json
{
  "level": "info",
  "msg": "hello",
  "data": {
    "nested": true
  }
}
```
This becomes a single entry with the full structure available in the Tree/JSON tabs.

**String-encoded nested JSON:**
When a JSON value is itself a JSON string (common in message buses and APIs), Leif auto-expands it:
```json
{
  "payload": "{\"inner_key\": \"inner_value\", \"count\": 42}"
}
```
The `payload` field is automatically parsed and rendered as a nested tree — no manual copy-paste needed.

## Architecture

### Project Structure

```
Sources/Leif/
├── LeifApp.swift                  — App entry, menu bar, global hotkey, window management
├── LeifSearchLimits.swift         — Search string length limits
├── Models/
│   └── LogEntry.swift             — LogEntry, LogLevel, OrderedFields
├── Parser/
│   ├── LogParser.swift            — Multi-format parser (CRI, Loki, Zap, JSON)
│   └── JSONFormatter.swift        — Pretty-printer, Go struct parser, JSONNode tree
├── Hotkey/
│   └── HotkeyManager.swift        — Global Ctrl+Shift+Space via Carbon API
├── ViewModels/
│   ├── LogViewModel.swift         — State management, LRU payload cache, pre-warming
│   └── PerformanceMonitor.swift   — Real-time CPU & memory metrics (phys_footprint + RSS)
├── Views/
│   ├── ContentView.swift          — 3-panel layout, Unix converter with keyboard nav
│   ├── LogListView.swift          — Filtered list, diff marking, context menus
│   ├── JSONTreeView.swift         — Tree/JSON/Raw tabs, syntax highlighting, search
│   ├── DiffView.swift             — Side-by-side diff window, scroll sync, navigation
│   ├── TableDataView.swift        — Array detection, dynamic table, TSV/CSV export
│   ├── RawLogEditor.swift         — NSTextView-based editable input
│   └── PerformanceOverlay.swift   — Toolbar memory/CPU badge with expandable detail
└── Diff/
    └── LineDiffer.swift           — Myers O(ND) line diff with sparse history
```

**16 files, ~4,000 lines. Zero external dependencies** — pure SwiftUI + AppKit.

### Data Flow

```
Raw text (paste)
    │
    ▼
LogParser.parse()              ← Concurrent parsing (all CPU cores)
    │                             Detects format: CRI → Loki → Zap → JSON → plain
    │                             Reconstructs CRI P/F chunks
    ▼
[LogEntry]                     ← Stored in LogViewModel.entries
    │
    ├─▶ LogListView            ← Filtered display, level badges, diff marking
    │       │
    │       ▼
    │   PayloadCache           ← LRU (20 entries), background pre-warming
    │       │
    │       ▼
    │   LogDetailView          ← Tree / JSON / Raw / Table tabs
    │
    └─▶ DiffView (on demand)
            │
            ├── JSONFormatter.prettyPrint() × 2
            ├── LineDiffer.diff()           ← Myers O(ND), max 20K edits
            ├── DiffAttrBuilder.build() × 2 ← NSAttributedString with colors
            └── Side-by-side NSTextView panels
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| No external dependencies | Single binary, no version conflicts, simple distribution |
| Menu bar only (no Dock) | Quick access utility; global hotkey for instant show/hide |
| LRU payload cache (20) | Pre-warms in background; balances memory vs cache hit rate |
| Single @State per detail view | One `Built` struct instead of 6 separate @State vars — no duplicate copies |
| `phys_footprint` memory metric | Same as Activity Monitor; unlike `resident_size`, drops when memory is freed |
| `Task.detached` for payload build | Cooperates with Swift cancellation (replaced non-cancellable GCD blocks) |
| Diff window auto-closes on clear | Prevents stale LogEntry refs from holding memory after logs are cleared |
| Concurrent parsing | Uses all CPU cores via `DispatchQueue.concurrentPerform` |
| Myers line diff (not structural) | Same algorithm as git/GitHub; correct for any JSON structure including arrays of objects with repeated keys |
| Fixed 14px line height in diff | Ensures both panels have identical pixel height per row for scroll sync |
| Edit distance cap (20K) | Prevents memory blowup on very different large payloads; falls back to full red/green |
| NSTextView (not SwiftUI Text) | Handles 200K+ lines efficiently; native find bar; attributed string support |
| Background `Task.detached` for diff | Pretty-print + Myers + attributed string building never blocks main thread |

### Diff Architecture

The diff view uses a **line-level diff** (not structural JSON diff) for rendering:

1. **Pretty-print** both JSON payloads independently via `JSONFormatter.prettyPrint()`
2. **Split** into line arrays
3. **Myers diff** produces edit script: which lines are equal, added, removed
4. **Align** edits into `[AlignedDiffLine]` — both panels get the same number of rows
5. **Pair** adjacent deletes+inserts as "modified" (shows old value left, new value right)
6. **Build** `NSAttributedString` with background colors directly from alignment status
7. **Scroll sync** uses absolute Y offset (identical row count + fixed line height = perfect alignment)

### Performance Characteristics

| Scenario | Approach |
|----------|----------|
| Parsing 10K+ log lines | Concurrent `DispatchQueue.concurrentPerform` across all cores |
| Payload > 384 KB | Fast O(n) syntax highlighter instead of 5-pass regex |
| JSON diff 200K+ lines | Myers with 20K edit cap; sparse history; `Task.detached` background |
| Payload cache | LRU with 20 entries; doubly-linked list for O(1) eviction |
| Attributed string | Built once in background; NSTextView renders with non-contiguous layout |
| Detail tabs | Only active tab's view is alive (switch, not ZStack) — saves ~300 MB |
| Text change detection | Hash-based comparison in NSViewRepresentable coordinators |

### Memory Management

- **`phys_footprint`** metric (same as Activity Monitor) for accurate real-time display
- **Diff window cleanup**: clears NSTextView text storage, detaches SwiftUI hosting controller, nils window on next run loop tick, calls `malloc_zone_pressure_relief`
- **Cancellable tasks**: `Task.detached` replaces `withCheckedContinuation` + GCD for proper cancellation
- **Single @State**: detail view stores one `Built` struct instead of 6 separate @State copies

## Testing

```bash
swift run LeifTests
```

Standalone test suite (no Xcode required). 34 tests across 10 categories:

| Category | Tests | Coverage |
|----------|-------|----------|
| CRI Simple | 3 | F-line parsing, timestamps, level detection |
| CRI Partial | 3 | P+F chunk reconstruction, content joining |
| Zap Format | 2 | Tab-separated fields, timestamp validation |
| JSON Parsing | 5 | Objects, arrays, multi-line, string-encoded, empty |
| Full Logs | 3 | 692-line structure, level distribution, file size |
| Diff Logic | 5 | Identical/changed/added/removed, 1000-key stress |
| Search | 3 | Case-insensitive, match counting, length clamping |
| Table | 3 | Array detection, union keys, TSV/CSV escaping |
| Copy | 2 | Tab-specific copy, raw fallback |
| Performance | 5 | Parse speed, CRI reconstruction, JSON parse, pretty-print, memory |

Test fixtures in `Tests/LeifTests/Fixtures/` use real Kubernetes CRI log data.

## TODO

- [ ] Arbitrary JSON diff — paste two raw JSON strings directly (not tied to log entries)
- [ ] Inline word-level diff highlighting within modified lines (highlight the specific changed characters, not just the whole line)
- [ ] Export diff as HTML or image for sharing
- [ ] Bookmark/pin important log entries across sessions
- [ ] Multi-file support — drag & drop multiple log files
- [ ] Regex search in filter bar
- [ ] Dark/light mode toggle in diff window
- [ ] Keyboard shortcut customization

## Building from Source

```bash
# Debug build (fast, for development)
swift build

# Release app bundle (universal binary: arm64 + x86_64)
bash build-app.sh

# The app is at dist/Leif.app
open dist/Leif.app
```

Requires Xcode Command Line Tools (`xcode-select --install`). No Xcode project needed — builds with Swift Package Manager.
