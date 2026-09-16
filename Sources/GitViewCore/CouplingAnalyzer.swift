import Foundation

/// Two units that tend to change in the same commits.
public struct CouplingPair: Hashable, Sendable, Identifiable {
    public var id: String { "\(a.uuidString)|\(b.uuidString)" }
    /// Ordered so that (a, b) and (b, a) are the same pair.
    public let a: UUID
    public let b: UUID
    /// Commits that touched both units.
    public let sharedCommits: Int
    /// Shared commits weighted by recency with the risk model's half-life. This is the
    /// trustworthy number: a pair needs *two* correct line attributions, so step 3's 42%
    /// precision on 5-year-old commits compounds to roughly 18% for pairs.
    public let weight: Double
    /// `sharedCommits / min(commits of a, commits of b)` — how much of the less-changed
    /// unit's history is shared. 1.0 means one never changes without the other.
    public let strength: Double
    public let lastShared: Date
    public let crossFile: Bool
    public let crossDirectory: Bool
}

public struct CouplingIndex: Sendable {
    /// Pairs meeting `minSharedCommits`, most heavily weighted first.
    public let pairs: [CouplingPair]
    /// Commits touching more than `maxUnitsPerCommit` units — sweeps, not coupling.
    public let skippedCommits: Int
    /// Commits touching 2...max units, i.e. the ones that produced pairs.
    public let pairingCommits: Int
    public let halfLife: TimeInterval
    /// Indices of the commits skipped as sweeps, so lookups agree with `sharedCommits`.
    public let sweepCommits: Set<Int32>

    /// Commits touching both units that were counted toward the pair, newest first.
    /// Sweeps are excluded, so this count matches `pair.sharedCommits`.
    public func sharedCommits(of pair: CouplingPair, in churn: ChurnIndex) -> [Commit] {
        sharedIndices(of: pair, in: churn).filter { !sweepCommits.contains($0) }.map { churn.commits[Int($0)] }
    }

    /// Commits touching both units that were *not* counted because they were sweeps.
    public func sweepSharedCommits(of pair: CouplingPair, in churn: ChurnIndex) -> [Commit] {
        sharedIndices(of: pair, in: churn).filter { sweepCommits.contains($0) }.map { churn.commits[Int($0)] }
    }

    private func sharedIndices(of pair: CouplingPair, in churn: ChurnIndex) -> [Int32] {
        let a = churn.touchesByUnit[pair.a] ?? []
        let b = Set(churn.touchesByUnit[pair.b] ?? [])
        return a.filter(b.contains)
    }
}

/// Counts, per commit, every pair of units touched together.
public struct CouplingAnalyzer: Sendable {
    /// Above this many units a commit is a sweep (formatting, rename, license header) and
    /// says nothing about which units belong together. It would also cost N² pairs.
    public var maxUnitsPerCommit = 50
    public var minSharedCommits = 2
    public var halfLife: TimeInterval = 365 * 86_400

    public init(maxUnitsPerCommit: Int = 50, minSharedCommits: Int = 2, halfLife: TimeInterval = 365 * 86_400) {
        self.maxUnitsPerCommit = maxUnitsPerCommit
        self.minSharedCommits = minSharedCommits
        self.halfLife = halfLife
    }

    public func analyze(units: [CodeUnit], churn: ChurnIndex, now: Date) -> CouplingIndex {
        // Type declarations are excluded: a type co-changes with every method inside it by
        // construction, which is containment, not coupling.
        let eligible = units.filter { $0.kind != .class && churn.commitCount(for: $0) > 0 }
        let unitIndex = Dictionary(uniqueKeysWithValues: eligible.enumerated().map { ($1.id, Int32($0)) })

        // Invert unit -> commits into commit -> units.
        var unitsByCommit = [[Int32]](repeating: [], count: churn.commits.count)
        for unit in eligible {
            let index = unitIndex[unit.id]!
            for commit in churn.touchesByUnit[unit.id] ?? [] {
                unitsByCommit[Int(commit)].append(index)
            }
        }

        struct Accumulator { var count = 0; var weight = 0.0; var last = Date.distantPast }
        var accumulators: [UInt64: Accumulator] = [:]
        var sweeps = Set<Int32>()
        var pairing = 0

        for (commitIndex, touched) in unitsByCommit.enumerated() where touched.count >= 2 {
            if touched.count > maxUnitsPerCommit { sweeps.insert(Int32(commitIndex)); continue }
            pairing += 1
            let commit = churn.commits[commitIndex]
            let weight = pow(0.5, now.timeIntervalSince(commit.date) / halfLife)
            let sorted = touched.sorted()
            for i in 0..<(sorted.count - 1) {
                for j in (i + 1)..<sorted.count {
                    let key = UInt64(UInt32(bitPattern: sorted[i])) << 32 | UInt64(UInt32(bitPattern: sorted[j]))
                    var acc = accumulators[key, default: Accumulator()]
                    acc.count += 1
                    acc.weight += weight
                    acc.last = max(acc.last, commit.date)
                    accumulators[key] = acc
                }
            }
        }

        let pairs: [CouplingPair] = accumulators.compactMap { key, acc in
            guard acc.count >= minSharedCommits else { return nil }
            let first = eligible[Int(key >> 32)]
            let second = eligible[Int(key & 0xFFFF_FFFF)]
            let smaller = min(churn.commitCount(for: first), churn.commitCount(for: second))
            return CouplingPair(
                a: first.id, b: second.id,
                sharedCommits: acc.count,
                weight: acc.weight,
                strength: smaller > 0 ? Double(acc.count) / Double(smaller) : 0,
                lastShared: acc.last,
                crossFile: first.filePath != second.filePath,
                crossDirectory: Self.directory(of: first.filePath) != Self.directory(of: second.filePath)
            )
        }
        .sorted {
            $0.weight != $1.weight ? $0.weight > $1.weight
                : ($0.sharedCommits != $1.sharedCommits ? $0.sharedCommits > $1.sharedCommits : $0.id < $1.id)
        }

        return CouplingIndex(pairs: pairs, skippedCommits: sweeps.count, pairingCommits: pairing,
                             halfLife: halfLife, sweepCommits: sweeps)
    }

    public static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}
