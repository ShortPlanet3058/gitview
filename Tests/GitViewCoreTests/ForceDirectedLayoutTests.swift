import XCTest
@testable import GitViewCore

private func unit(_ name: String, dir: String) -> CodeUnit {
    CodeUnit(filePath: "\(dir)/\(name).swift", name: name, kind: .function, lineRange: 1...5,
             complexity: 1, nestingDepth: 0, lineCount: 5)
}

private func pair(_ a: CodeUnit, _ b: CodeUnit, weight: Double, shared: Int = 3) -> CouplingPair {
    CouplingPair(a: a.id, b: b.id, sharedCommits: shared, weight: weight, strength: 0.5,
                 lastShared: Date(timeIntervalSince1970: 0), crossFile: true,
                 crossDirectory: a.filePath.split(separator: "/").first != b.filePath.split(separator: "/").first)
}

final class CouplingGraphTests: XCTestCase {
    func testBuildsNodesFromKeptEdgesAndCountsDegree() {
        let a = unit("a", dir: "X"), b = unit("b", dir: "X"), c = unit("c", dir: "Y"), d = unit("d", dir: "Y")
        let units = Dictionary(uniqueKeysWithValues: [a, b, c, d].map { ($0.id, $0) })
        let pairs = [pair(a, b, weight: 3), pair(a, c, weight: 2), pair(c, d, weight: 1)]
        let graph = CouplingGraph(pairs: pairs, maxEdges: 2, unit: { units[$0] }, size: { _ in 1 })

        XCTAssertEqual(graph.edges.count, 2)
        XCTAssertEqual(graph.droppedEdges, 1)
        XCTAssertEqual(Set(graph.nodes.map(\.id)), [a.id, b.id, c.id], "d only appears in the dropped edge")
        XCTAssertEqual(graph.nodes.first { $0.id == a.id }?.degree, 2)
        XCTAssertEqual(graph.nodes.first { $0.id == a.id }?.directory, "X")
    }

    func testUnknownUnitsAreSkipped() {
        let a = unit("a", dir: "X"), b = unit("b", dir: "X")
        let graph = CouplingGraph(pairs: [pair(a, b, weight: 1)], maxEdges: 10, unit: { $0 == a.id ? a : nil }, size: { _ in 1 })
        XCTAssertTrue(graph.edges.isEmpty)
        XCTAssertTrue(graph.nodes.isEmpty)
    }
}

final class ForceDirectedLayoutTests: XCTestCase {
    /// Two tight pairs in one folder, one pair in another, one lonely edge between folders.
    private func sampleGraph() -> (CouplingGraph, [String: UUID]) {
        let names = ["a", "b", "c", "d", "e", "f"]
        let units = names.enumerated().map { unit($1, dir: $0 < 4 ? "X" : "Y") }
        let byID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        let byName = Dictionary(uniqueKeysWithValues: units.map { ($0.name, $0.id) })
        let pairs = [
            pair(units[0], units[1], weight: 5),
            pair(units[2], units[3], weight: 5),
            pair(units[4], units[5], weight: 5),
            pair(units[1], units[4], weight: 1),
        ]
        return (CouplingGraph(pairs: pairs, maxEdges: 100, unit: { byID[$0] }, size: { _ in 1 }), byName)
    }

    func testDeterministicForSameSeed() {
        let (graph, _) = sampleGraph()
        var first = ForceDirectedLayout(graph: graph, seed: 42); first.settle()
        var second = ForceDirectedLayout(graph: graph, seed: 42); second.settle()
        XCTAssertEqual(first.positions, second.positions)
    }

    func testPositionsStayFiniteAndSettles() {
        let (graph, _) = sampleGraph()
        var layout = ForceDirectedLayout(graph: graph)
        layout.settle(maxIterations: 500)
        XCTAssertTrue(layout.isSettled)
        XCTAssertLessThan(layout.iterations, 500)
        for point in layout.positions.values {
            XCTAssertTrue(point.x.isFinite && point.y.isFinite)
        }
    }

    func testConnectedNodesEndCloserThanUnconnectedOnes() {
        let (graph, id) = sampleGraph()
        var layout = ForceDirectedLayout(graph: graph)
        layout.settle()
        func distance(_ p: String, _ q: String) -> Double {
            let a = layout.position(of: id[p]!)!, b = layout.position(of: id[q]!)!
            return ForceDirectedLayout.length(a - b)
        }
        let tight = [distance("a", "b"), distance("c", "d"), distance("e", "f")]
        let loose = [distance("a", "c"), distance("a", "f"), distance("c", "e"), distance("b", "d")]
        let averageTight = tight.reduce(0, +) / Double(tight.count)
        let averageLoose = loose.reduce(0, +) / Double(loose.count)
        XCTAssertLessThan(averageTight, averageLoose,
                          "edges must pull their endpoints together: tight \(averageTight) vs loose \(averageLoose)")
    }

    func testCoincidentStartsAreSeparated() {
        // Two nodes with identical seeds/directories start on top of each other; repulsion
        // must break the tie instead of dividing by zero.
        let a = unit("a", dir: "X"), b = unit("b", dir: "X")
        let byID = Dictionary(uniqueKeysWithValues: [a, b].map { ($0.id, $0) })
        let graph = CouplingGraph(pairs: [pair(a, b, weight: 1)], maxEdges: 1, unit: { byID[$0] }, size: { _ in 1 })
        var layout = ForceDirectedLayout(graph: graph)
        layout.settle()
        let d = ForceDirectedLayout.length(layout.position(of: a.id)! - layout.position(of: b.id)!)
        XCTAssertGreaterThan(d, 0.05)
        XCTAssertTrue(d.isFinite)
    }

    func testEmptyGraph() {
        let graph = CouplingGraph(pairs: [], maxEdges: 10, unit: { _ in nil }, size: { _ in 1 })
        var layout = ForceDirectedLayout(graph: graph)
        layout.settle()
        XCTAssertTrue(layout.positions.isEmpty)
    }

    func testLargeGraphSettlesQuickly() {
        // ~200 nodes / 200 edges is the cap the view uses; layout must be interactive-fast.
        var units: [CodeUnit] = []
        for i in 0..<200 { units.append(unit("u\(i)", dir: "D\(i % 7)")) }
        let byID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        var pairs: [CouplingPair] = []
        for i in 0..<200 { pairs.append(pair(units[i], units[(i * 7 + 3) % 200], weight: Double(200 - i))) }
        let graph = CouplingGraph(pairs: pairs, maxEdges: 200, unit: { byID[$0] }, size: { _ in 1 })
        var layout = ForceDirectedLayout(graph: graph)
        let started = Date()
        layout.settle()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        XCTAssertTrue(layout.isSettled)
    }
}

final class ForceDirectedLayoutSeparationTests: XCTestCase {
    func testNoTwoNodesEndCloserThanMinimumSeparation() {
        var units: [CodeUnit] = []
        for i in 0..<60 { units.append(unit("u\(i)", dir: "D\(i % 3)")) }
        let byID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        // A star: one hub connected to everything, the worst case for overlap.
        let pairs = (1..<60).map { pair(units[0], units[$0], weight: 1) }
        let graph = CouplingGraph(pairs: pairs, maxEdges: 100, unit: { byID[$0] }, size: { _ in 1 })
        var layout = ForceDirectedLayout(graph: graph)
        layout.settle()
        let points = Array(layout.positions.values)
        var closest = Double.infinity
        for i in 0..<(points.count - 1) {
            for j in (i + 1)..<points.count {
                closest = min(closest, ForceDirectedLayout.length(points[i] - points[j]))
            }
        }
        XCTAssertGreaterThanOrEqual(closest, layout.minimumSeparation * 0.9,
                                    "closest pair \(closest) violates separation \(layout.minimumSeparation)")
    }
}

final class CouplingGraphStabilityTests: XCTestCase {
    func testNodeOrderDoesNotDependOnUUIDs() {
        // Same repository content, fresh UUIDs (as on every launch): the graph must order
        // nodes identically so the seeded layout reproduces.
        func build() -> [String] {
            let a = unit("a", dir: "X"), b = unit("b", dir: "X"), c = unit("c", dir: "Y")
            let byID = Dictionary(uniqueKeysWithValues: [a, b, c].map { ($0.id, $0) })
            let pairs = [pair(a, b, weight: 2), pair(b, c, weight: 1)]
            return CouplingGraph(pairs: pairs, maxEdges: 10, unit: { byID[$0] }, size: { _ in 1 }).nodes.map(\.label)
        }
        XCTAssertEqual(build(), build())
        XCTAssertEqual(build(), ["a", "b", "c"])
    }
}
