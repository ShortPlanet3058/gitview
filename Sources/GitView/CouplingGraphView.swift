import SwiftUI
import GitViewCore

/// Force-directed coupling graph on a Canvas.
///
/// Self-contained: takes data and selection bindings, owns only its viewport state, so it
/// can be dropped into another layout unchanged. Edges across folders are drawn in the
/// accent colour, same-folder edges recede; node colour is the unit's risk level, always
/// with a legend; node size is commit count; only the best-connected nodes are labelled.
struct CouplingGraphView: View {
    let graph: CouplingGraph
    let positions: [UUID: CGPoint]
    let layingOut: Bool
    let level: (UUID) -> RiskLevel?
    let location: (UUID) -> String?
    @Binding var selectedUnitID: UUID?
    @Binding var selectedPairID: String?

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panAtDragStart: CGSize = .zero
    @State private var zoomAtGestureStart: CGFloat = 1
    @State private var hoveredNode: UUID?
    @State private var hoveredEdge: String?
    @State private var pointer: CGPoint?
    @State private var pinnedPositions: [UUID: CGPoint] = [:]
    @State private var draggedNodeID: UUID?
    @State private var dragStartChecked = false

    private static let labelCount = 10

    var body: some View {
        GeometryReader { geometry in
            let frame = Transform(positions: positions, in: geometry.size, zoom: zoom, pan: pan)
            let effectivePositions = positions.merging(pinnedPositions) { _, pinned in pinned }
            let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
            let maxWeight = graph.edges.map(\.weight).max() ?? 1
            let maxSize = graph.nodes.map(\.size).max() ?? 1
            let selectedPair: (UUID, UUID)? = graph.edges.first { $0.pairID == selectedPairID }.map { ($0.a, $0.b) }
            let directoryClusters = Dictionary(grouping: graph.nodes.filter { !$0.directory.isEmpty }, by: \.directory)
                .filter { $0.value.count >= 3 }

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    // Soft directory cluster hulls behind edges and nodes.
                    for (directory, members) in directoryClusters.sorted(by: { $0.key < $1.key }) {
                        let screenPoints = members.compactMap { effectivePositions[$0.id].map(frame.apply) }
                        let hull = ConvexHull.compute(screenPoints)
                        guard hull.count >= 3 else { continue }
                        var hullPath = Path()
                        hullPath.addLines(hull)
                        hullPath.closeSubpath()
                        let clusterColor = Self.directoryColor(for: directory)
                        context.stroke(hullPath, with: .color(clusterColor.opacity(0.08)),
                                       style: StrokeStyle(lineWidth: 20, lineCap: .round, lineJoin: .round))
                        context.fill(hullPath, with: .color(clusterColor.opacity(0.07)))
                        context.stroke(hullPath, with: .color(clusterColor.opacity(0.22)),
                                       style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round, dash: [4, 4]))
                    }

                    var selectedEdgePath: Path?
                    for edge in graph.edges {
                        guard let a = effectivePositions[edge.a], let b = effectivePositions[edge.b] else { continue }
                        let pa = frame.apply(a), pb = frame.apply(b)
                        var path = Path(); path.move(to: pa); path.addLine(to: pb)
                        if edge.pairID == selectedPairID { selectedEdgePath = path; continue }
                        let emphasised = edge.pairID == hoveredEdge
                            || [edge.a, edge.b].contains { $0 == hoveredNode || $0 == selectedUnitID }
                        let width = 0.75 + 2.5 * CGFloat(edge.weight / maxWeight) + (emphasised ? 1 : 0)
                        let color: Color = emphasised ? Theme.ink.opacity(0.85)
                            : edge.crossDirectory ? Theme.accent.opacity(0.55) : Theme.inkMuted.opacity(0.28)
                        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                    }
                    // The selected pair goes on top of everything else, with a surface halo so it
                    // reads even through a dense cluster.
                    if let path = selectedEdgePath {
                        context.stroke(path, with: .color(Theme.surface), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        context.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    }

                    for node in graph.nodes {
                        guard let p = effectivePositions[node.id] else { continue }
                        let center = frame.apply(p)
                        let radius = Self.radius(for: node, maxSize: maxSize)
                        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                        let fill = level(node.id).map(Theme.color(for:)) ?? Theme.inkMuted
                        // 2pt surface ring so overlapping nodes stay separable.
                        context.fill(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), with: .color(Theme.surface))
                        context.fill(Path(ellipseIn: rect), with: .color(fill))
                        let isPairEnd = selectedPair.map { $0.0 == node.id || $0.1 == node.id } ?? false
                        if node.id == hoveredNode || node.id == selectedUnitID || isPairEnd {
                            context.stroke(Path(ellipseIn: rect.insetBy(dx: -3.5, dy: -3.5)),
                                           with: .color(isPairEnd ? Theme.accent : Theme.ink), lineWidth: 1.5)
                        } else if pinnedPositions[node.id] != nil {
                            context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                                           with: .color(Theme.accent.opacity(0.65)),
                                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        }
                    }

                    // Labels: best-connected first; a label that would overlap one already
                    // placed is skipped (hover still shows it). Hovered/selected always win.
                    var placed: [CGRect] = []
                    func place(_ node: CouplingGraph.Node, force: Bool) {
                        guard let p = effectivePositions[node.id] else { return }
                        let center = frame.apply(p)
                        let radius = Self.radius(for: node, maxSize: maxSize)
                        let text = Self.shortLabel(node.label)
                        let width = CGFloat(text.count) * 5.6 + 6
                        let rect = CGRect(x: center.x - width / 2, y: center.y + radius + 3, width: width, height: 13)
                        if !force && placed.contains(where: { $0.intersects(rect) }) { return }
                        placed.append(rect)
                        context.draw(Text(text).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.inkSoft),
                                     at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                    }
                    let forced = [hoveredNode, selectedUnitID, selectedPair?.0, selectedPair?.1].compactMap { $0 }
                    for id in forced { if let node = nodesByID[id] { place(node, force: true) } }
                    for node in graph.nodes.filter({ $0.degree >= 2 && !forced.contains($0.id) })
                        .sorted(by: { ($0.degree, $0.size) > ($1.degree, $1.size) }).prefix(Self.labelCount * 2) {
                        place(node, force: false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        pointer = point
                        hoveredNode = frame.nearestNode(to: point, in: graph, positions: effectivePositions, maxSize: maxSize)
                        hoveredEdge = hoveredNode == nil ? frame.nearestEdge(to: point, in: graph, positions: effectivePositions) : nil
                    case .ended:
                        pointer = nil; hoveredNode = nil; hoveredEdge = nil
                    }
                }
                .gesture(SpatialTapGesture().onEnded { value in
                    if let node = frame.nearestNode(to: value.location, in: graph, positions: effectivePositions, maxSize: maxSize) {
                        selectedPairID = nil
                        selectedUnitID = node
                    } else if let edge = frame.nearestEdge(to: value.location, in: graph, positions: effectivePositions) {
                        selectedUnitID = nil
                        selectedPairID = edge
                    }
                })
                .simultaneousGesture(DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if !dragStartChecked {
                            dragStartChecked = true
                            draggedNodeID = frame.nearestNode(
                                to: value.startLocation, in: graph,
                                positions: effectivePositions, maxSize: maxSize
                            )
                            if draggedNodeID == nil {
                                panAtDragStart = pan
                            }
                        }
                        if let nodeID = draggedNodeID {
                            pinnedPositions[nodeID] = frame.unapply(value.location)
                        } else {
                            pan = CGSize(width: panAtDragStart.width + value.translation.width,
                                         height: panAtDragStart.height + value.translation.height)
                        }
                    }
                    .onEnded { _ in
                        dragStartChecked = false
                        draggedNodeID = nil
                        panAtDragStart = pan
                    })
                .simultaneousGesture(MagnificationGesture()
                    .onChanged { value in zoom = min(max(zoomAtGestureStart * value, 0.4), 6) }
                    .onEnded { _ in zoomAtGestureStart = zoom })
                .onChange(of: graph.nodes.map(\.id)) { _, _ in
                    pinnedPositions.removeAll()
                }

                legend
                    .padding(Theme.Space.m)

                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: Theme.Space.s) {
                        if !pinnedPositions.isEmpty {
                            Button("Reset pins (\(pinnedPositions.count))") {
                                withAnimation(.easeOut(duration: 0.2)) { pinnedPositions.removeAll() }
                            }
                            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                        }
                        if zoom != 1 || pan != .zero {
                            Button("Fit") { withAnimation(.easeOut(duration: 0.2)) { zoom = 1; pan = .zero; zoomAtGestureStart = 1 } }
                                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                        }
                    }
                    if layingOut {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Arranging…") }
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .trailing)

                if let hovered = hoveredNode, let node = nodesByID[hovered], let pointer {
                    tooltip(for: node)
                        .offset(x: min(pointer.x + 14, max(8, geometry.size.width - 260)), y: pointer.y + 14)
                } else if hoveredNode == nil,
                          let edgeID = hoveredEdge,
                          let edge = graph.edges.first(where: { $0.pairID == edgeID }),
                          let nodeA = nodesByID[edge.a],
                          let nodeB = nodesByID[edge.b],
                          let pointer {
                    edgeTooltip(nodeA: nodeA, nodeB: nodeB, edge: edge)
                        .offset(x: min(pointer.x + 14, max(8, geometry.size.width - 270)), y: pointer.y + 14)
                }
            }
        }
    }

    // MARK: - Pieces

    private var legend: some View {
        HStack(spacing: Theme.Space.l) {
            ForEach(RiskLevel.allCases.reversed(), id: \.self) { level in
                HStack(spacing: 4) {
                    Circle().fill(Theme.color(for: level)).frame(width: 8, height: 8)
                    Image(systemName: level.symbolName).font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.color(for: level))
                    Text(level.label).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                }
            }
            HStack(spacing: 4) {
                Rectangle().fill(Theme.accent.opacity(0.7)).frame(width: 14, height: 2)
                Text("across folders").font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
            }
            HStack(spacing: 4) {
                Rectangle().fill(Theme.inkMuted.opacity(0.4)).frame(width: 14, height: 2)
                Text("same folder").font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
            }
            Text("size = commits").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            if graph.droppedEdges > 0 {
                Text("· strongest \(graph.edges.count) of \(graph.edges.count + graph.droppedEdges) connections")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.raised.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func tooltip(for node: CouplingGraph.Node) -> some View {
        tooltipCard {
            HStack(spacing: 6) {
                if let level = level(node.id) { RiskBadge(level: level, compact: true) }
                Text(node.label).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink).lineLimit(1)
            }
            if let location = location(node.id) {
                Text(location).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).lineLimit(1).truncationMode(.head)
            }
            Text("\(Int(node.size)) commits · \(node.degree) connection\(node.degree == 1 ? "" : "s") shown")
                .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
        }
    }

    private func edgeTooltip(nodeA: CouplingGraph.Node, nodeB: CouplingGraph.Node, edge: CouplingGraph.Edge) -> some View {
        tooltipCard {
            Text("\(Self.shortLabel(nodeA.label)) ↔ \(Self.shortLabel(nodeB.label))")
                .font(Theme.Text.bodyBold)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            Text("\(edge.sharedCommits) shared commit\(edge.sharedCommits == 1 ? "" : "s") · \(edge.crossDirectory ? "across folders" : "same folder")")
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.inkSoft)
        }
    }

    private func tooltipCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
        }
        .padding(10)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .allowsHitTesting(false)
    }

    nonisolated static func directoryColor(for directory: String) -> Color {
        var hash: UInt64 = 1469598103934665603
        for byte in directory.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return Theme.tint(Theme.avatarTints[Int(hash % UInt64(Theme.avatarTints.count))])
    }

    nonisolated static func radius(for node: CouplingGraph.Node, maxSize: Double) -> CGFloat {
        4 + 7 * CGFloat((node.size / max(maxSize, 1)).squareRoot())
    }

    /// Last two components, so `NIOAsyncChannel.Storage.next` reads as `Storage.next`.
    nonisolated static func shortLabel(_ label: String) -> String {
        let parts = label.split(separator: ".")
        let short = parts.suffix(2).joined(separator: ".")
        return short.count > 28 ? String(short.prefix(27)) + "…" : short
    }

    /// Maps layout space to the view, preserving aspect, with user zoom and pan on top.
    struct Transform {
        let scale: CGFloat
        let offset: CGPoint

        init(positions: [UUID: CGPoint], in size: CGSize, zoom: CGFloat, pan: CGSize) {
            let inset: CGFloat = 48
            let xs = positions.values.map(\.x), ys = positions.values.map(\.y)
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 1, minY = ys.min() ?? 0, maxY = ys.max() ?? 1
            let width = max(maxX - minX, 0.001), height = max(maxY - minY, 0.001)
            let fit = min((size.width - 2 * inset) / width, (size.height - 2 * inset) / height)
            scale = fit * zoom
            let centre = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
            offset = CGPoint(x: size.width / 2 - centre.x * scale + pan.width,
                             y: size.height / 2 - centre.y * scale + pan.height)
        }

        func apply(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }

        func unapply(_ p: CGPoint) -> CGPoint {
            let safeScale = max(scale, 0.0001)
            return CGPoint(x: (p.x - offset.x) / safeScale, y: (p.y - offset.y) / safeScale)
        }

        func nearestNode(to point: CGPoint, in graph: CouplingGraph, positions: [UUID: CGPoint], maxSize: Double) -> UUID? {
            var best: (UUID, CGFloat)?
            for node in graph.nodes {
                guard let p = positions[node.id] else { continue }
                let c = apply(p)
                let d = hypot(c.x - point.x, c.y - point.y)
                let hit = CouplingGraphView.radius(for: node, maxSize: maxSize) + 4
                if d <= hit && (best == nil || d < best!.1) { best = (node.id, d) }
            }
            return best?.0
        }

        func nearestEdge(to point: CGPoint, in graph: CouplingGraph, positions: [UUID: CGPoint]) -> String? {
            var best: (String, CGFloat)?
            for edge in graph.edges {
                guard let a = positions[edge.a], let b = positions[edge.b] else { continue }
                let d = Self.distance(from: point, toSegment: apply(a), apply(b))
                if d <= 6 && (best == nil || d < best!.1) { best = (edge.pairID, d) }
            }
            return best?.0
        }

        static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let lengthSquared = ab.x * ab.x + ab.y * ab.y
            guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lengthSquared))
            let q = CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t)
            return hypot(p.x - q.x, p.y - q.y)
        }
    }
}

/// Andrew's monotone chain 2D convex hull for drawing directory cluster boundaries.
enum ConvexHull {
    static func compute(_ points: [CGPoint]) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        let sorted = points.sorted { lhs, rhs in
            lhs.x != rhs.x ? lhs.x < rhs.x : lhs.y < rhs.y
        }
        var unique: [CGPoint] = []
        unique.reserveCapacity(sorted.count)
        for p in sorted {
            if let last = unique.last, abs(last.x - p.x) < 1e-6 && abs(last.y - p.y) < 1e-6 {
                continue
            }
            unique.append(p)
        }
        guard unique.count > 2 else { return unique }

        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [CGPoint] = []
        for p in unique {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }

        var upper: [CGPoint] = []
        for p in unique.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }

        return Array(lower.dropLast() + upper.dropLast())
    }
}
