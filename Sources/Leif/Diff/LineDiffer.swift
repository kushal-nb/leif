import Foundation

/// Result of a line-level diff: one entry per aligned row in the output.
struct AlignedDiffLine {
    let leftLineNum:  Int?     // nil = blank placeholder (line was added on right)
    let rightLineNum: Int?     // nil = blank placeholder (line was removed from left)
    let leftText:     String   // empty string for blank rows
    let rightText:    String   // empty string for blank rows
    let status:       Status

    enum Status {
        case context            // identical on both sides
        case added              // only on right (green)
        case removed            // only on left (red)
        case modified           // different on both sides (orange)
    }
}

/// Myers line diff with aligned output for side-by-side rendering.
enum LineDiffer {

    static func diff(left: [String], right: [String]) -> [AlignedDiffLine] {
        let edits = computeEdits(old: left, new: right)
        return alignEdits(edits, left: left, right: right)
    }

    // MARK: - Edit types

    private enum Edit {
        case equal(oldIdx: Int, newIdx: Int)
        case delete(oldIdx: Int)
        case insert(newIdx: Int)
    }

    // MARK: - LCS-based diff (simple, correct, bounded)

    /// Computes edits using a simplified Myers O(ND) algorithm with a max-edit cap.
    private static func computeEdits(old: [String], new: [String]) -> [Edit] {
        let n = old.count, m = new.count
        if n == 0 && m == 0 { return [] }
        if n == 0 { return (0..<m).map { .insert(newIdx: $0) } }
        if m == 0 { return (0..<n).map { .delete(oldIdx: $0) } }

        // For performance: if both are very large, use a simpler LCS approach
        // with a cap on edit distance
        // Cap edit distance: for very similar JSONs D is small and fast.
        // For large payloads with many differences, cap to avoid O(D * vSize) memory.
        let maxD = min(n + m, 20_000)

        // V: maps diagonal k → furthest x reached. Indexed as v[k + offset].
        let offset = maxD + 1
        let vSize = 2 * offset + 1
        var v = [Int](repeating: 0, count: vSize)
        v[offset + 1] = 0

        // Store snapshots of v for backtracking
        var history: [[Int]] = []

        var finalD = -1
        outer: for d in 0...maxD {
            history.append(Array(v))
            for k in stride(from: -d, through: d, by: 2) {
                let idx = k + offset
                guard idx > 0 && idx < vSize - 1 else { continue }

                var x: Int
                if k == -d || (k != d && v[idx - 1] < v[idx + 1]) {
                    x = v[idx + 1]       // came from diagonal k+1 (insert)
                } else {
                    x = v[idx - 1] + 1   // came from diagonal k-1 (delete)
                }
                var y = x - k

                // Extend along diagonal (matching lines)
                while x < n && y < m && old[x] == new[y] {
                    x += 1; y += 1
                }

                v[idx] = x

                if x >= n && y >= m {
                    finalD = d
                    break outer
                }
            }
        }

        if finalD < 0 {
            // Exceeded max edits — treat as fully different
            var result: [Edit] = []
            for i in 0..<n { result.append(.delete(oldIdx: i)) }
            for j in 0..<m { result.append(.insert(newIdx: j)) }
            return result
        }

        // Backtrack through history to recover the edit script
        var x = n, y = m
        var edits: [Edit] = []

        for d in stride(from: finalD, through: 1, by: -1) {
            let prev = history[d - 1]
            let k = x - y
            let idx = k + offset

            // Determine which direction we came from
            let fromInsert: Bool
            if k == -d {
                fromInsert = true
            } else if k == d {
                fromInsert = false
            } else if idx > 0 && idx < vSize - 1 {
                fromInsert = prev[idx - 1] < prev[idx + 1]
            } else {
                fromInsert = idx <= 0
            }

            let prevK = fromInsert ? k + 1 : k - 1
            let prevIdx = prevK + offset
            guard prevIdx >= 0 && prevIdx < vSize else {
                // Safety: can't backtrack, emit remaining as changes
                break
            }
            let prevX = prev[prevIdx]
            let prevY = prevX - prevK

            // Diagonal moves (equal lines) — walk backwards
            while x > max(prevX, 0) && y > max(prevY, 0) && x > 0 && y > 0 {
                x -= 1; y -= 1
                edits.append(.equal(oldIdx: x, newIdx: y))
            }

            // The actual edit
            if fromInsert {
                if y > 0 { y -= 1; edits.append(.insert(newIdx: y)) }
            } else {
                if x > 0 { x -= 1; edits.append(.delete(oldIdx: x)) }
            }
        }

        // Remaining diagonal at d=0
        while x > 0 && y > 0 {
            x -= 1; y -= 1
            edits.append(.equal(oldIdx: x, newIdx: y))
        }
        while x > 0 { x -= 1; edits.append(.delete(oldIdx: x)) }
        while y > 0 { y -= 1; edits.append(.insert(newIdx: y)) }

        edits.reverse()
        return edits
    }

    // MARK: - Align edits into side-by-side output

    private static func alignEdits(_ edits: [Edit], left: [String], right: [String]) -> [AlignedDiffLine] {
        var result: [AlignedDiffLine] = []
        result.reserveCapacity(edits.count)

        var i = 0
        while i < edits.count {
            switch edits[i] {
            case .equal(let oi, let ni):
                guard oi < left.count && ni < right.count else { i += 1; continue }
                result.append(AlignedDiffLine(
                    leftLineNum: oi + 1, rightLineNum: ni + 1,
                    leftText: left[oi], rightText: right[ni], status: .context))
                i += 1

            case .delete:
                // Collect consecutive deletes
                var deletes: [Int] = []
                while i < edits.count, case .delete(let oi) = edits[i] { deletes.append(oi); i += 1 }
                // Collect consecutive inserts that follow
                var inserts: [Int] = []
                while i < edits.count, case .insert(let ni) = edits[i] { inserts.append(ni); i += 1 }

                // Pair deletes with inserts as "modified"
                let paired = min(deletes.count, inserts.count)
                for p in 0..<paired {
                    let oi = deletes[p]; let ni = inserts[p]
                    guard oi < left.count && ni < right.count else { continue }
                    result.append(AlignedDiffLine(
                        leftLineNum: oi + 1, rightLineNum: ni + 1,
                        leftText: left[oi], rightText: right[ni], status: .modified))
                }
                // Remaining unpaired deletes
                for p in paired..<deletes.count {
                    let oi = deletes[p]
                    guard oi < left.count else { continue }
                    result.append(AlignedDiffLine(
                        leftLineNum: oi + 1, rightLineNum: nil,
                        leftText: left[oi], rightText: "", status: .removed))
                }
                // Remaining unpaired inserts
                for p in paired..<inserts.count {
                    let ni = inserts[p]
                    guard ni < right.count else { continue }
                    result.append(AlignedDiffLine(
                        leftLineNum: nil, rightLineNum: ni + 1,
                        leftText: "", rightText: right[ni], status: .added))
                }

            case .insert(let ni):
                guard ni < right.count else { i += 1; continue }
                result.append(AlignedDiffLine(
                    leftLineNum: nil, rightLineNum: ni + 1,
                    leftText: "", rightText: right[ni], status: .added))
                i += 1
            }
        }
        return result
    }
}
