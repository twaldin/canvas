import Foundation

/// Line diff for proposed-change fences: the real range (old) against the fence body (new).
/// Myers' O((N+M)·D) shortest edit script after trimming the common prefix and suffix; within a
/// changed run, removals come before additions, as in unified diffs.
public enum NoteDiff {
    public enum Line: Equatable, Sendable {
        /// 0-based indices into the old and new arrays.
        case same(old: Int, new: Int, String)
        case removed(old: Int, String)
        case added(new: Int, String)
    }

    public static func lines(_ old: [String], _ new: [String]) -> [Line] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }

        var out: [Line] = (0..<prefix).map { .same(old: $0, new: $0, old[$0]) }
        let a = old[prefix..<(old.count - suffix)]
        let b = new[prefix..<(new.count - suffix)]
        var removed: [Line] = []
        var added: [Line] = []
        func flush() {
            out += removed
            out += added
            removed.removeAll()
            added.removeAll()
        }
        for step in script(Array(a), Array(b)) {
            switch step {
            case .keep(let i, let j):
                flush()
                out.append(.same(old: prefix + i, new: prefix + j, old[prefix + i]))
            case .delete(let i):
                removed.append(.removed(old: prefix + i, old[prefix + i]))
            case .insert(let j):
                added.append(.added(new: prefix + j, new[prefix + j]))
            }
        }
        flush()
        out += (0..<suffix).map { k in
            let i = old.count - suffix + k
            return .same(old: i, new: new.count - suffix + k, old[i])
        }
        return out
    }

    private enum Step {
        case keep(Int, Int), delete(Int), insert(Int)
    }

    private static func script(_ a: [String], _ b: [String]) -> [Step] {
        let n = a.count
        let m = b.count
        if n == 0 { return (0..<m).map { .insert($0) } }
        if m == 0 { return (0..<n).map { .delete($0) } }
        let max = n + m
        let offset = max
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []
        search: for d in 0...max {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m { break search }
            }
        }
        // Walk the trace back from (n, m), collecting steps in reverse.
        var steps: [Step] = []
        var x = n
        var y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let previousK = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) ? k + 1 : k - 1
            let previousX = d == 0 ? 0 : v[offset + previousK]
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                x -= 1
                y -= 1
                steps.append(.keep(x, y))
            }
            guard d > 0 else { break }
            if x == previousX {
                y -= 1
                steps.append(.insert(y))
            } else {
                x -= 1
                steps.append(.delete(x))
            }
        }
        return steps.reversed()
    }
}
