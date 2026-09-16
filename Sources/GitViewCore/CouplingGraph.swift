import Foundation

/// Nodes and edges for drawing coupling. Built from the strongest pairs only: a graph of
/// thousands of edges is unreadable, and layout cost grows with node count squared.
public struct CouplingGraph: Sendable {
    public struct Node: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let label: String
        public let directory: String
        /// Size input (commit count); the view maps it to a radius.
        public let size: Double
        public let degree: Int
    }

    public struct Edge: Hashable, Sendable {
        public let a: UUID
        public let b: UUID
        public let weight: Double
        public let sharedCommits: Int
        public let crossDirectory: Bool
        public let pairID: String
    }

    public let nodes: [Node]
    public let edges: [Edge]
    /// Pairs beyond `maxEdges` that were left out, so the view can say so.
    public let droppedEdges: Int

    /// - Parameter pairs: strongest first, as `CouplingIndex.pairs` is sorted.
    public init(pairs: [CouplingPair], maxEdges: Int,
                unit: (UUID) -> CodeUnit?, size: (UUID) -> Double) {
        let kept = pairs.prefix(max(maxEdges, 0))
        droppedEdges = max(0, pairs.count - kept.count)

        var degree: [UUID: Int] = [:]
        var edges: [Edge] = []
        for pair in kept where unit(pair.a) != nil && unit(pair.b) != nil {
            edges.append(Edge(a: pair.a, b: pair.b, weight: pair.weight, sharedCommits: pair.sharedCommits,
                              crossDirectory: pair.crossDirectory, pairID: pair.id))
            degree[pair.a, default: 0] += 1
            degree[pair.b, default: 0] += 1
        }
        self.edges = edges
        // Ordered by a key that is stable across launches (unit ids are fresh UUIDs every
        // run), so the seeded layout reproduces the same picture for the same repository.
        self.nodes = degree.keys
            .compactMap { id in unit(id).map { (id, "\($0.filePath):\($0.lineRange.lowerBound):\($0.name)") } }
            .sorted { $0.1 < $1.1 }
            .compactMap { id, _ in
                guard let found = unit(id) else { return nil }
                return Node(id: id, label: found.name, directory: CouplingAnalyzer.directory(of: found.filePath),
                            size: size(id), degree: degree[id] ?? 0)
            }
    }
}

/// Fruchterman–Reingold force layout with gravity, in abstract units (ideal edge length 1).
///
/// Deterministic for a given graph and seed, so the picture does not jump between runs.
/// Nodes from the same directory start near each other on a ring, which lets folder
/// clusters form consistently instead of depending on where random noise put them.
public struct ForceDirectedLayout: Sendable {
    public typealias Point = SIMD2<Double>

    private let ids: [UUID]
    private let edges: [(Int, Int, Double)]
    private let degrees: [Int]
    private var points: [Point]
    /// Nodes closer than this are pushed apart after each step, so circles never overlap
    /// once the view maps one unit to a few node diameters.
    public var minimumSeparation = 0.55
    /// Pull toward the origin. Kept weak: strong gravity crushes hubs into a hairball.
    public var gravity = 0.03
    private var temperature: Double
    private let coolingFloor = 0.01
    public private(set) var iterations = 0

    public init(graph: CouplingGraph, seed: UInt64 = 0x9E37_79B9) {
        ids = graph.nodes.map(\.id)
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        edges = graph.edges.compactMap { edge in
            guard let i = index[edge.a], let j = index[edge.b] else { return nil }
            return (i, j, edge.weight)
        }
        var degrees = [Int](repeating: 0, count: graph.nodes.count)
        for (i, j, _) in edges { degrees[i] += 1; degrees[j] += 1 }
        self.degrees = degrees

        let count = max(graph.nodes.count, 1)
        let side = sqrt(Double(count))            // area grows with n so density stays constant
        var rng = SplitMix64(seed: seed)
        var directoryIndex: [String: Int] = [:]
        for node in graph.nodes where directoryIndex[node.directory] == nil {
            directoryIndex[node.directory] = directoryIndex.count
        }
        let directories = Double(max(directoryIndex.count, 1))
        points = graph.nodes.map { node in
            let angle = 2 * Double.pi * Double(directoryIndex[node.directory] ?? 0) / directories
            let center = Point(cos(angle), sin(angle)) * side * 0.4
            let jitter = Point(rng.nextUnit() - 0.5, rng.nextUnit() - 0.5) * side * 0.3
            return center + jitter
        }
        temperature = max(side * 0.1, 0.05)
    }

    public var isSettled: Bool { temperature <= coolingFloor * 1.05 }

    /// One iteration: repulsion between every pair, attraction along edges (stronger for
    /// heavier pairs), gravity toward the origin, displacement capped by the temperature.
    public mutating func step() {
        let count = points.count
        guard count > 1 else { iterations += 1; return }
        var displacement = [Point](repeating: .zero, count: count)

        for i in 0..<(count - 1) {
            for j in (i + 1)..<count {
                var delta = points[i] - points[j]
                var distance = Self.length(delta)
                if distance < 1e-6 {
                    delta = Point(1e-3 * Double(i + 1), 1e-3 * Double(j + 1))
                    distance = Self.length(delta)
                }
                let push = delta / distance * (1.0 / distance)       // k²/d with k = 1
                displacement[i] += push
                displacement[j] -= push
            }
        }

        let heaviest = edges.map(\.2).max() ?? 1
        for (i, j, weight) in edges {
            let delta = points[i] - points[j]
            let distance = max(Self.length(delta), 1e-6)
            var strength = 0.5 + (weight / max(heaviest, 1e-9))    // 0.5 ... 1.5
            // A hub with many edges would otherwise be pulled from every side at once and
            // collapse its neighbours onto itself; damp by the smaller endpoint's degree.
            strength /= 1 + 0.2 * Double(Swift.min(degrees[i], degrees[j]) - 1)
            let pull = delta / distance * (distance * distance * strength)   // d²/k
            displacement[i] -= pull
            displacement[j] += pull
        }

        for i in 0..<count {
            displacement[i] -= points[i] * gravity
            let magnitude = Self.length(displacement[i])
            if magnitude > 0 {
                points[i] += displacement[i] / magnitude * min(magnitude, temperature)
            }
        }
        separateOverlaps()
        temperature = max(temperature * 0.95, coolingFloor)
        iterations += 1
    }

    /// Pushes any two nodes closer than `minimumSeparation` apart by half the deficit each.
    private mutating func separateOverlaps() {
        let count = points.count
        for i in 0..<(count - 1) {
            for j in (i + 1)..<count {
                var delta = points[i] - points[j]
                var distance = Self.length(delta)
                if distance >= minimumSeparation { continue }
                if distance < 1e-6 { delta = Point(1e-3 * Double(i + 1), 1e-3); distance = Self.length(delta) }
                let shift = delta / distance * ((minimumSeparation - distance) / 2)
                points[i] += shift
                points[j] -= shift
            }
        }
    }

    /// Runs until cooled or `maxIterations`, whichever first.
    public mutating func settle(maxIterations: Int = 300) {
        var remaining = maxIterations
        while remaining > 0 && !isSettled { step(); remaining -= 1 }
    }

    public func position(of id: UUID) -> Point? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        return points[index]
    }

    public var positions: [UUID: Point] {
        Dictionary(uniqueKeysWithValues: zip(ids, points).map { ($0, $1) })
    }

    public var bounds: (min: Point, max: Point) {
        guard let first = points.first else { return (.zero, .zero) }
        return points.reduce((first, first)) { acc, p in
            (Point(Swift.min(acc.0.x, p.x), Swift.min(acc.0.y, p.y)), Point(Swift.max(acc.1.x, p.x), Swift.max(acc.1.y, p.y)))
        }
    }

    static func length(_ v: Point) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
}

/// Small deterministic generator so layouts are reproducible; SystemRandomNumberGenerator
/// cannot be seeded.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
