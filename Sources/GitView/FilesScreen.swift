import SwiftUI
import GitViewCore
import GitViewGit

/// Tracked-file tree with an info card; files in a supported language show their hotspots.
struct FilesScreen: View {
    @Environment(WorkspaceSession.self) private var session
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
        if let analysis = session.analysis {
            let tree = session.risk.fileTree ?? FileTree(files: analysis.info.inventory.files, rows: session.risk.allRankedRows)
            // Resolved during evaluation rather than by a side effect: an offscreen render
            // completes before any async work could land.
            let pending = session.navigation.pendingFileSelection.flatMap { wanted in
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
                    // The dashboard's language strip and size number both point here, so
                    // this column carries the breakdown behind them alongside whatever file
                    // is selected.
                    // The column leads with whatever was asked for. Arriving from the
                    // dashboard's language strip there is no file selected, so the language
                    // breakdown is on top; select a file in the tree and its details take
                    // that place instead of sitting under two cards about the whole project.
                    ScrollColumn {
                        VStack(alignment: .leading, spacing: Theme.Space.l) {
                            if chosen == nil {
                                LanguagesCard(inventory: analysis.info.inventory)
                                RepositorySizeCard(info: analysis.info)
                                FileInfoCard(node: tree.root, root: analysis.root)
                            } else {
                                FileInfoCard(node: chosen.flatMap { tree.node(at: $0) } ?? tree.root,
                                             root: analysis.root)
                                LanguagesCard(inventory: analysis.info.inventory)
                                RepositorySizeCard(info: analysis.info)
                            }
                        }
                    }
                    .frame(width: 320)
                }
                .padding(.horizontal, Theme.Space.xl).padding(.bottom, Theme.Space.xl)
            }
        }
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
    @Environment(WorkspaceSession.self) private var session
    let node: FileTree.Node
    let root: URL

    private var url: URL { node.path.isEmpty ? root : root.appendingPathComponent(node.path) }
    /// A file lists all its ranked functions; a directory lists only what needs attention,
    /// otherwise the root would list every function in the repository.
    private var hotspotRows: [RiskRow] {
        if node.isDirectory {
            let prefix = node.path.isEmpty ? "" : node.path + "/"
            return session.risk.rows.filter { $0.filePath.hasPrefix(prefix) && ($0.level == .critical || $0.level == .high) }
        }
        return session.risk.rows.filter { $0.filePath == node.path }
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
                        Button { session.inspector.showFileHistory(node.path) } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(PrimaryButtonStyle()).controlSize(.small)
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Finder", systemImage: "folder") }
                        .buttonStyle(SecondaryButtonStyle())
                    if !node.isDirectory {
                        Button { openInEditor(url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                if let ownership = session.ownership {
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
                            Button { session.navigation.selectedUnitID = row.id } label: {
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
