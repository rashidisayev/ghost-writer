import Foundation

public struct WordDiff: Sendable {
    public enum Op: Sendable, Equatable {
        case equal(String)
        case insert(String)
        case delete(String)
    }

    public let ops: [Op]

    public init(ops: [Op]) { self.ops = ops }

    /// Suppress trivial diffs — a single changed comma is noise, and showing a
    /// card for it trains users to reflexively hit Esc.
    public var hasMeaningfulChanges: Bool { changeMagnitude >= 4 }

    /// Characters actually changed. A word-level diff replaces a whole token
    /// even when one character moved, so a naive length sum scores "there" →
    /// "there," as 11. Paired delete/insert spans are compared character-wise
    /// and only the differing middle is counted.
    public var changeMagnitude: Int {
        var total = 0
        var i = 0
        while i < ops.count {
            switch ops[i] {
            case .equal:
                i += 1

            case let .delete(deleted):
                if i + 1 < ops.count, case let .insert(inserted) = ops[i + 1] {
                    total += Self.substitutionCost(deleted, inserted)
                    i += 2
                } else {
                    total += Self.trimmedCount(deleted)
                    i += 1
                }

            case let .insert(inserted):
                // wordDiff emits insertions before the delete at the same offset.
                if i + 1 < ops.count, case let .delete(deleted) = ops[i + 1] {
                    total += Self.substitutionCost(deleted, inserted)
                    i += 2
                } else {
                    total += Self.trimmedCount(inserted)
                    i += 1
                }
            }
        }
        return total
    }

    private static func trimmedCount(_ s: String) -> Int {
        s.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    /// Cost of turning `a` into `b`, ignoring the shared prefix and suffix.
    static func substitutionCost(_ a: String, _ b: String) -> Int {
        let ac = Array(a.trimmingCharacters(in: .whitespacesAndNewlines))
        let bc = Array(b.trimmingCharacters(in: .whitespacesAndNewlines))

        var prefix = 0
        while prefix < ac.count, prefix < bc.count, ac[prefix] == bc[prefix] { prefix += 1 }

        var suffix = 0
        while suffix < ac.count - prefix,
              suffix < bc.count - prefix,
              ac[ac.count - 1 - suffix] == bc[bc.count - 1 - suffix] {
            suffix += 1
        }

        return max(ac.count - prefix - suffix, bc.count - prefix - suffix)
    }
}

public enum DiffEngine {

    public static func wordDiff(_ a: String, _ b: String) -> WordDiff {
        let aw = tokenize(a)
        let bw = tokenize(b)
        // CollectionDifference is Myers under the hood — no dependency needed,
        // which matters in a process holding Accessibility permission.
        let diff = bw.difference(from: aw)

        let removals = Set(diff.removals.map(\.diffOffset))
        let insertsByOffset = Dictionary(grouping: diff.insertions, by: \.diffOffset)

        var ops: [WordDiff.Op] = []
        for (i, word) in aw.enumerated() {
            if let ins = insertsByOffset[i] {
                ops.append(.insert(ins.map(\.diffElement).joined()))
            }
            ops.append(removals.contains(i) ? .delete(word) : .equal(word))
        }
        if let tail = insertsByOffset[aw.count] {
            ops.append(.insert(tail.map(\.diffElement).joined()))
        }
        return WordDiff(ops: coalesce(ops))
    }

    /// Split into words WITH their trailing whitespace so reassembly is lossless.
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inWhitespace = false

        for ch in s {
            if ch.isWhitespace {
                current.append(ch)
                inWhitespace = true
            } else {
                if inWhitespace {
                    out.append(current)
                    current = ""
                    inWhitespace = false
                }
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Merge adjacent ops of the same kind so the rendered card shows one
    /// highlighted span per edit rather than one per word.
    static func coalesce(_ ops: [WordDiff.Op]) -> [WordDiff.Op] {
        var out: [WordDiff.Op] = []
        for op in ops {
            guard let last = out.last else { out.append(op); continue }
            switch (last, op) {
            case let (.equal(a), .equal(b)):   out[out.count - 1] = .equal(a + b)
            case let (.insert(a), .insert(b)): out[out.count - 1] = .insert(a + b)
            case let (.delete(a), .delete(b)): out[out.count - 1] = .delete(a + b)
            default: out.append(op)
            }
        }
        return out
    }
}

private extension CollectionDifference.Change {
    var diffOffset: Int {
        switch self {
        case let .insert(offset, _, _), let .remove(offset, _, _): offset
        }
    }
    var diffElement: ChangeElement {
        switch self {
        case let .insert(_, element, _), let .remove(_, element, _): element
        }
    }
}
