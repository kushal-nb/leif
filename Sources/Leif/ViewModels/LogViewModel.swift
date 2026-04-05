import SwiftUI

// MARK: - Payload builder (shared by LogDetailView and the pre-warm task)

/// Thresholds for skipping work that does not scale (tree UI, regex syntax highlight, deep array scan).
enum PayloadBuildLimits {
    /// UTF-8 size of pasted `rawContent` — above this, use the fast path.
    static let heavyRawUTF8: Int = 384_000
}

func buildEntryPayload(_ entry: LogEntry) async -> PayloadCache.Built? {
    guard let fields = entry.fields else { return nil }
    return await withCheckedContinuation { cont in
        // `.userInitiated` — large payload work is the main thread of user focus; `.background` starves it.
        DispatchQueue.global(qos: .userInitiated).async {
            let rawBytes = entry.rawContent.utf8.count
            let heavy    = rawBytes >= PayloadBuildLimits.heavyRawUTF8
            let dict     = fields.pairs.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }

            let pp = JSONFormatter.prettyPrint(dict)

            // highlight() auto-selects: regex for small payloads, fast O(n) char-by-char for large.
            let hl = JSONHighlighter.highlight(pp)

            let nodes: [JSONNode]
            let treeNote: String?
            if heavy {
                nodes = []
                let kb = rawBytes / 1024
                treeNote = "Tree view is disabled for large payloads (~\(kb) KB). Use the JSON or Raw tab."
            } else {
                nodes = dict.keys.sorted().map { k in JSONNode.build(from: dict[k]!, key: k) }
                treeNote = nil
            }

            let af = extractArrayFields(from: OrderedFields(dict), maxRecursionDepth: heavy ? 3 : 64)

            cont.resume(returning: PayloadCache.Built(
                treeNodes: nodes, arrayFields: af, prettyJSON: pp, highlightedJSON: hl,
                treeOmittedReason: treeNote
            ))
        }
    }
}

// MARK: - Payload cache  (LRU, capped to avoid unbounded memory growth)
final class PayloadCache {
    struct Built {
        let treeNodes:           [JSONNode]
        let arrayFields:         [ArrayField]
        let prettyJSON:          String
        let highlightedJSON:     NSAttributedString
        /// Non-nil when the tree tab shows a hint instead of materializing a huge SwiftUI tree.
        let treeOmittedReason:   String?
    }

    private static let maxEntries = 200
    private let lock = NSLock()
    private var store: [UUID: Built] = [:]
    /// Doubly-linked list node for O(1) LRU tracking.
    private final class Node {
        let key: UUID
        var prev: Node?
        var next: Node?
        init(_ key: UUID) { self.key = key }
    }
    private var nodeMap: [UUID: Node] = [:]
    private var head: Node?   // most recent
    private var tail: Node?   // oldest

    /// O(1) existence check — does not touch access order.
    func has(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return store[id] != nil
    }

    func get(_ id: UUID) -> Built? {
        lock.lock()
        defer { lock.unlock() }
        guard let built = store[id] else { return nil }
        moveToHead(id)
        return built
    }

    func set(_ id: UUID, _ built: Built) {
        lock.lock()
        defer { lock.unlock() }
        if store[id] != nil {
            moveToHead(id)
        } else {
            if store.count >= Self.maxEntries, let oldest = tail {
                removeNode(oldest)
                store.removeValue(forKey: oldest.key)
                nodeMap.removeValue(forKey: oldest.key)
            }
            let node = Node(id)
            insertAtHead(node)
            nodeMap[id] = node
        }
        store[id] = built
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
        nodeMap.removeAll()
        head = nil
        tail = nil
    }

    // MARK: Linked list helpers

    private func moveToHead(_ id: UUID) {
        guard let node = nodeMap[id] else { return }
        guard node !== head else { return }
        removeNode(node)
        insertAtHead(node)
    }

    private func insertAtHead(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func removeNode(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if node === head { head = node.next }
        if node === tail { tail = node.prev }
        node.prev = nil
        node.next = nil
    }
}

// MARK: - ViewModel
@MainActor
final class LogViewModel: ObservableObject {
    @Published var rawText = ""
    @Published var entries: [LogEntry] = []
    @Published var selectedEntry: LogEntry? = nil
    @Published var isParsingBusy = false
    @Published var filterText = ""

    let payloadCache = PayloadCache()
    private var parseTask:   Task<Void, Never>? = nil
    private var prewarmTask: Task<Void, Never>? = nil

    private var lastParsedText: String = ""

    func parse() {
        let text = rawText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Skip re-parse if text is identical to last parse
        if text == lastParsedText && !entries.isEmpty { return }
        lastParsedText = text

        parseTask?.cancel()
        prewarmTask?.cancel()
        // Clear old state completely before starting fresh
        payloadCache.clear()
        selectedEntry = nil
        entries = []
        isParsingBusy = true

        parseTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                LogParser().parse(text: text)
            }.value
            if !Task.isCancelled {
                self.entries = result
                self.isParsingBusy = false
                self.selectedEntry = result.first
                self.startPrewarm(entries: result)
            }
        }
    }

    func clear() {
        parseTask?.cancel()
        prewarmTask?.cancel()
        rawText = ""
        entries = []
        selectedEntry = nil
        lastParsedText = ""
        payloadCache.clear()
    }

    // Builds every entry's payload at background priority.
    // Already-cached entries (e.g. the selected one built by LogDetailView) are skipped.
    private func startPrewarm(entries: [LogEntry]) {
        prewarmTask?.cancel()
        prewarmTask = Task(priority: .background) {
            for entry in entries {
                guard !Task.isCancelled else { return }
                guard !self.payloadCache.has(entry.id) else { continue }
                // Huge single-document payloads: build on demand when the user opens the detail pane
                // (avoids tens of seconds of CPU right after parse).
                if entry.rawContent.utf8.count >= PayloadBuildLimits.heavyRawUTF8 { continue }
                guard let built = await buildEntryPayload(entry) else { continue }
                guard !Task.isCancelled else { return }
                self.payloadCache.set(entry.id, built)
            }
        }
    }
}
