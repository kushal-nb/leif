# Leif — Kubernetes Log Inspector

A compact macOS menu-bar utility for inspecting Kubernetes/Loki logs from Go apps using Zap logger.

## Features

- **Global hotkey** `Ctrl+Shift+Space` — show/hide from anywhere
- **CRI chunking** — reconstructs `P` (partial) / `F` (final) split log lines automatically
- **Zap log parsing** — extracts `timestamp · level · caller · message · JSON fields`
- **No-timestamp logs** — handles pastes with or without Kubernetes CRI outer timestamps
- **JSON tree view** — collapsible key/value tree with syntax colouring
- **JSON raw view** — pretty-printed JSON you can select and copy
- **Raw view** — original reconstructed log line
- **Filter bar** — text search + level filter across all entries
- **Auto-parse** — parses automatically after pasting; or press `⌘↵`
- **Copy button** — copies pretty JSON or raw line to clipboard
- **Menu bar icon** — lives in the status bar, never clutters the Dock

## Install

```bash
bash build-app.sh
cp -r dist/Leif.app /Applications/
open /Applications/Leif.app
```

Share `dist/Leif.app` with teammates — works on any Mac running macOS 13+.
No code signing account needed (ad-hoc signed).

> **First launch on a teammate's Mac:** right-click → Open → Open (to bypass Gatekeeper once).

## Usage

1. In terminal or Loki UI, copy your log lines
2. Press `Ctrl+Shift+Space` or click the menu bar icon 🔍
3. Paste into the left panel — entries appear automatically
4. Click a row to see the detail pane
5. Switch between **Tree / JSON / Raw** tabs in the detail view
6. Use the filter bar to search or filter by level

## Log formats supported

| Format | Example |
|--------|---------|
| Kubernetes CRI full | `2026-03-03T19:01:59Z stdout F 2026-03-03T19:01:59.053Z DEBUG …` |
| CRI partial chunks | `stdout P …` followed by `stdout F …` → auto-reconstructed |
| Zap dev format | `2026-03-03T19:01:59.053Z    DEBUG    caller.go:42    message    {…}` |
| Plain JSON | `{"level":"info","msg":"hello","ts":"…"}` |
| Plain text | anything else shown as-is |

## Building from source

```bash
# Debug build
swift build

# Release app bundle
bash build-app.sh
```

Requires Xcode Command Line Tools (`xcode-select --install`).
