import Foundation

/// Precomputed per-commit swimlane topology for vertical commit lists ordered newest-first.
public struct CommitGraphRow: Sendable, Hashable {
    public struct Segment: Sendable, Hashable {
        public let fromLane: Int
        public let toLane: Int
        public let colorIndex: Int

        public init(fromLane: Int, toLane: Int, colorIndex: Int) {
            self.fromLane = fromLane
            self.toLane = toLane
            self.colorIndex = colorIndex
        }
    }

    public let sha: String
    public let nodeLane: Int
    public let isMerge: Bool
    public let laneCount: Int
    public let upperSegments: [Segment]
    public let lowerSegments: [Segment]

    public init(
        sha: String,
        nodeLane: Int,
        isMerge: Bool,
        laneCount: Int,
        upperSegments: [Segment],
        lowerSegments: [Segment]
    ) {
        self.sha = sha
        self.nodeLane = nodeLane
        self.isMerge = isMerge
        self.laneCount = laneCount
        self.upperSegments = upperSegments
        self.lowerSegments = lowerSegments
    }
}

/// Computes deterministic lane indices and connecting segments across a commit list.
public enum CommitGraphLayout {
    public static func build(commits: [Commit], maxLanes: Int = 8) -> [String: CommitGraphRow] {
        guard !commits.isEmpty else { return [:] }
        let cap = max(1, maxLanes)
        var activeLanes: [String?] = []
        var result: [String: CommitGraphRow] = [:]
        result.reserveCapacity(commits.count)

        func allocateLane(prefer preferred: Int? = nil) -> Int? {
            if let preferred, preferred < cap {
                while activeLanes.count <= preferred { activeLanes.append(nil) }
                if activeLanes[preferred] == nil { return preferred }
            }
            if let free = activeLanes.firstIndex(where: { $0 == nil }) {
                return free
            }
            if activeLanes.count < cap {
                activeLanes.append(nil)
                return activeLanes.count - 1
            }
            return nil
        }

        for commit in commits {
            let matching = activeLanes.indices.filter { activeLanes[$0] == commit.sha }
            let nodeLane: Int
            var upperSegments: [CommitGraphRow.Segment] = []

            if let primary = matching.first {
                nodeLane = primary
                upperSegments.append(CommitGraphRow.Segment(fromLane: primary, toLane: primary, colorIndex: primary))
                for dup in matching.dropFirst() {
                    upperSegments.append(CommitGraphRow.Segment(fromLane: dup, toLane: primary, colorIndex: dup))
                    activeLanes[dup] = nil
                }
            } else {
                nodeLane = allocateLane() ?? (cap - 1)
                if nodeLane >= activeLanes.count {
                    while activeLanes.count <= nodeLane { activeLanes.append(nil) }
                }
            }

            let matchingSet = Set(matching)
            var lowerSegments: [CommitGraphRow.Segment] = []

            // Carry all unrelated active lanes straight through this row.
            for lane in activeLanes.indices where !matchingSet.contains(lane) && lane != nodeLane {
                if activeLanes[lane] != nil {
                    upperSegments.append(CommitGraphRow.Segment(fromLane: lane, toLane: lane, colorIndex: lane))
                    lowerSegments.append(CommitGraphRow.Segment(fromLane: lane, toLane: lane, colorIndex: lane))
                }
            }

            // Clear nodeLane so primary parent can inherit it.
            activeLanes[nodeLane] = nil

            if let firstParent = commit.parents.first {
                if let existing = activeLanes.firstIndex(of: firstParent) {
                    lowerSegments.append(CommitGraphRow.Segment(fromLane: nodeLane, toLane: existing, colorIndex: nodeLane))
                } else {
                    activeLanes[nodeLane] = firstParent
                    lowerSegments.append(CommitGraphRow.Segment(fromLane: nodeLane, toLane: nodeLane, colorIndex: nodeLane))
                }
            }

            for secondaryParent in commit.parents.dropFirst() {
                if let existing = activeLanes.firstIndex(of: secondaryParent) {
                    lowerSegments.append(CommitGraphRow.Segment(fromLane: nodeLane, toLane: existing, colorIndex: existing))
                } else if let target = allocateLane() {
                    activeLanes[target] = secondaryParent
                    lowerSegments.append(CommitGraphRow.Segment(fromLane: nodeLane, toLane: target, colorIndex: target))
                } else {
                    let clamped = cap - 1
                    lowerSegments.append(CommitGraphRow.Segment(fromLane: nodeLane, toLane: clamped, colorIndex: clamped))
                }
            }

            while activeLanes.last == nil && !activeLanes.isEmpty {
                activeLanes.removeLast()
            }

            let maxSegLane = (upperSegments + lowerSegments).reduce(nodeLane) { partial, seg in
                max(partial, seg.fromLane, seg.toLane)
            }
            result[commit.sha] = CommitGraphRow(
                sha: commit.sha,
                nodeLane: nodeLane,
                isMerge: commit.parents.count > 1,
                laneCount: max(maxSegLane + 1, activeLanes.count, 1),
                upperSegments: upperSegments,
                lowerSegments: lowerSegments
            )
        }

        return result
    }
}
