import SwiftUI
import GitViewCore
import GitViewGit

/// Tracked-file tree with an info card; files in a supported language show their hotspots.
struct FilesScreen: View {
    @EnvironmentObject private var model: AnalysisModel
    @State private var expanded: Set<String> = [""]
    @State private var selectedPath: String? = nil
    @State private var query = ""

    /// Every folder on the way to a path, so a preselected file is visible.
    private static func ancestors(of path: String) -> Set<String> {
        var result = Set<String>()
        var parts = path.split(separator: "/").dropLast()
        while !parts.isEmpty {
            result.insert(parts.joined(separator: "/"))
            parts = parts.dropLast()
        }
        return result
    }

    var body: some View {
        if let analysis = model.analysis {
            let tree = FileTree(files: analysis.info.inventory.files, rows: model.rows)
            // Resolved during evaluation rather than by a side effect: an offscreen render
            // completes before any async work could land.
            let pending = model.pendingFileSelection.flatMap { wanted in
                tree.node(at: wanted)?.path ?? tree.firstNode(matching: wanted)?.path
            }
            let chosen = selectedPath ?? pending
            let openFolders = expanded.union(pending.map(Self.ancestors) ?? [])
            let visible = tree.visibleNodes(expanded: openFolders, filter: query)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    ScreenHeader(title: "Files", subtitle: "Explore the repository structure. Tracked files only.")
                    HStack {
                        SearchField(text: $query, prompt: "Filter files").frame(maxWidth: 300)
                        Spacer()
                        Text("\(analysis.info.inventory.fileCount.formatted()) files · \(analysis.info.inventory.totalBytes.byteString)")
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
                .padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.xl).padding(.bottom, Theme.Space.l)

                HStack(alignment: .top, spacing: Theme.Space.l) {
                    Card(padding: Theme.Space.s) {
                        ScrollColumn {
                            LazyVStack(spacing: 0) {
                                ForEach(visible) { node in
                                    FileTreeRow(node: node, expanded: openFolders.contains(node.path), selected: chosen == node.path) {
                                        if node.isDirectory {
                                            if expanded.contains(node.path) { expanded.remove(node.path) } else { expanded.insert(node.path) }
                                        }
                                        selectedPath = node.path
                                    }
                                    .contextMenu {
                                        if node.isDirectory {
                                            Button("Reveal in Finder") {
                                                revealInFinder(analysis.root.appendingPathComponent(node.path))
                                            }
                                            Button("Copy Path") { copyToPasteboard(node.path) }
                                        } else {
                                            PathActions(path: node.path)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    FileInfoCard(node: chosen.flatMap { tree.node(at: $0) } ?? tree.root, root: analysis.root)
                        .frame(width: 320)
                }
                .padding(.horizontal, Theme.Space.xl).padding(.bottom, Theme.Space.xl)
            }
        }
    }
}

/// Directory tree built from tracked paths with size, count and hotspot aggregates.
struct FileTree {
    final class Node: Identifiable {
        let path: String
        let name: String
        let isDirectory: Bool
        var bytes: Int64 = 0
        var fileCount: Int = 0
        var modified: Date?
        var children: [Node] = []
        var hotspotCounts: [RiskLevel: Int] = [:]
        var depth: Int = 0
        var id: String { path }
        init(path: String, name: String, isDirectory: Bool) { self.path = path; self.name = name; self.isDirectory = isDirectory }
        var hotspots: Int { (hotspotCounts[.critical] ?? 0) + (hotspotCounts[.high] ?? 0) }
    }

    let root: Node
    private var index: [String: Node] = [:]

    init(files: [FileInventory.TrackedFile], rows: [RiskRow]) {
        root = Node(path: "", name: "/", isDirectory: true)
        index[""] = root
        var attention: [String: [RiskLevel: Int]] = [:]
        for row in rows where row.level == .critical || row.level == .high {
            attention[row.filePath, default: [:]][row.level, default: 0] += 1
        }
        for file in files {
            var parent = root
            let components = file.path.split(separator: "/").map(String.init)
            var current = ""
            for (i, component) in components.enumerated() {
                current = current.isEmpty ? component : current + "/" + component
                let isLeaf = i == components.count - 1
                let node: Node
                if let existing = index[current] {
                    node = existing
                } else {
                    node = Node(path: current, name: component, isDirectory: !isLeaf)
                    node.depth = i + 1
                    index[current] = node
                    parent.children.append(node)
                }
                node.bytes += file.bytes
                node.fileCount += 1        // a directory counts every file beneath it
                if let m = file.modified, node.modified.map({ m > $0 }) ?? true { node.modified = m }
                if let counts = attention[file.path] {
                    for (level, count) in counts { node.hotspotCounts[level, default: 0] += count }
                }
                parent = node
            }
            root.bytes += file.bytes
            root.fileCount += 1
            if let m = file.modified, root.modified.map({ m > $0 }) ?? true { root.modified = m }
            if let counts = attention[file.path] {
                for (level, count) in counts { root.hotspotCounts[level, default: 0] += count }
            }
        }
        // Leaves counted themselves once above; directories count their files.
        for node in index.values where !node.isDirectory { node.fileCount = 1 }
        Self.sort(root)
    }

    private static func sort(_ node: Node) {
        node.children.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        node.children.forEach(sort)
    }

    func node(at path: String) -> Node? { index[path] }

    /// First node whose path contains `fragment`, for `--select-file`.
    func firstNode(matching fragment: String) -> Node? {
        index.values.filter { !$0.isDirectory && $0.path.contains(fragment) }
            .min { $0.path.count < $1.path.count }
    }

    /// Depth-first list of rows to draw, honouring expansion; a filter shows every match
    /// with its ancestors expanded.
    func visibleNodes(expanded: Set<String>, filter: String) -> [Node] {
        var result: [Node] = []
        let q = filter.trimmingCharacters(in: .whitespaces)
        func matches(_ node: Node) -> Bool {
            q.isEmpty || node.path.localizedCaseInsensitiveContains(q) || node.children.contains(where: matches)
        }
        func walk(_ node: Node) {
            for child in node.children where matches(child) {
                result.append(child)
                if child.isDirectory && (expanded.contains(child.path) || !q.isEmpty) { walk(child) }
            }
        }
        walk(root)
        return result
    }
}

struct FileTreeRow: View {
    let node: FileTree.Node
    let expanded: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Spacer().frame(width: CGFloat(max(node.depth - 1, 0)) * 16)
                Image(systemName: node.isDirectory ? (expanded ? "chevron.down" : "chevron.right") : "")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.inkMuted).frame(width: 12)
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
                    .font(.system(size: 12)).foregroundStyle(node.isDirectory ? Theme.accent : Theme.inkMuted)
                Text(node.name).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                if node.hotspots > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill").font(.system(size: 9))
                        Text("\(node.hotspots)").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.serious)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.serious.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .help("\(node.hotspots) critical or high-risk function\(node.hotspots == 1 ? "" : "s") inside")
                }
                Spacer()
                Text(node.isDirectory ? "\(node.fileCount) file\(node.fileCount == 1 ? "" : "s")" : node.bytes.byteString)
                    .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 5)
            .background(selected ? Theme.accentWash : (hovering ? Theme.wash : .clear),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct FileInfoCard: View {
    @EnvironmentObject private var model: AnalysisModel
    let node: FileTree.Node
    let root: URL

    private var url: URL { node.path.isEmpty ? root : root.appendingPathComponent(node.path) }
    /// A file lists all its ranked functions; a directory lists only what needs attention,
    /// otherwise the root would list every function in the repository.
    private var hotspotRows: [RiskRow] {
        if node.isDirectory {
            let prefix = node.path.isEmpty ? "" : node.path + "/"
            return model.rows.filter { $0.filePath.hasPrefix(prefix) && ($0.level == .critical || $0.level == .high) }
        }
        return model.rows.filter { $0.filePath == node.path }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: node.isDirectory ? "folder.fill" : "doc.text.fill")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.path.isEmpty ? root.lastPathComponent : node.name).font(Theme.Text.heading).foregroundStyle(Theme.ink).lineLimit(2)
                        Text(node.isDirectory ? "Directory" : (url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased() + " file"))
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
                VStack(spacing: 0) {
                    if node.isDirectory { infoRow("doc.on.doc", "\(node.fileCount.formatted()) file\(node.fileCount == 1 ? "" : "s")") }
                    infoRow("internaldrive", node.bytes.byteString)
                    if let modified = node.modified {
                        infoRow("clock", "Modified \(RiskExplanation.relative(modified, now: Date()))")
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    if !node.isDirectory {
                        Button { model.showFileHistory(node.path) } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(PrimaryButtonStyle()).controlSize(.small)
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Finder", systemImage: "folder") }
                        .buttonStyle(SecondaryButtonStyle())
                    if !node.isDirectory {
                        Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                if let ownership = model.ownership {
                    HairlineDivider()
                    OwnershipSection(
                        filePath: node.isDirectory ? nil : node.path,
                        ownership: node.isDirectory ? nil : ownership.ownership(of: node.path),
                        directory: node.isDirectory ? ownership.ownership(ofDirectory: node.path) : nil)
                }

                let rows = hotspotRows
                if !rows.isEmpty {
                    HairlineDivider()
                    HStack {
                        Text(node.isDirectory ? "Needs attention inside" : "Functions").font(Theme.Text.heading).foregroundStyle(Theme.ink)
                        Spacer()
                        Text("\(rows.count)").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                    VStack(spacing: 4) {
                        ForEach(rows.prefix(6)) { row in
                            Button { model.selectedUnitID = row.id } label: {
                                HStack(spacing: Theme.Space.s) {
                                    RiskBadge(level: row.level, compact: true)
                                    Text(row.name.split(separator: ".").suffix(2).joined(separator: "."))
                                        .font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("cx \(row.complexity)").font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if rows.count > 6 {
                            Text("and \(rows.count - 6) more…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        }
                    }
                }
            }
        }
    }

    private func infoRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.inkMuted).frame(width: 16)
            Text(text).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
