import SwiftUI
import GitViewCore
import GitViewGit

struct DiffRequest: Hashable, Sendable {
    let source: DiffSource
    let path: String
    /// What this diff belongs to — a commit subject, "Uncommitted changes", a comparison.
    let title: String
}

/// A unified diff for one file.
///
/// Unified rather than side by side: at the width left over beside the sidebar and detail
/// panel, two columns would wrap almost every line of real code.
struct DiffViewer: View {
    @EnvironmentObject private var model: AnalysisModel
    let request: DiffRequest

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content
        }
        .background(Theme.page)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Button { model.closeDiff() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        // Closing a diff opened from a history returns to that history.
                        Text(model.fileHistoryPath == nil ? "Back" : "Back to history")
                    }
                    .font(Theme.Text.body).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                if let diff = model.loadedDiff, !diff.isBinary {
                    Text("+\(diff.additions)").font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.good)
                    Text("−\(diff.deletions)").font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.critical)
                }
                Picker("", selection: $model.diffContext) {
                    Text("3 lines").tag(3)
                    Text("10 lines").tag(10)
                    Text("25 lines").tag(25)
                }
                .labelsHidden().frame(width: 110)
                .help("Lines of unchanged context shown around each change")
                Button("File history") { model.showFileHistory(request.path) }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                if let url = fileURL {
                    Button("Open file") { NSWorkspace.shared.open(url) }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(request.path).font(Theme.Text.title).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                HStack(spacing: Theme.Space.s) {
                    if let diff = model.loadedDiff {
                        if diff.isNew { Chip(text: "new file", tint: Theme.good) }
                        if diff.isDeleted { Chip(text: "deleted", tint: Theme.critical) }
                        if diff.isRename, let old = diff.oldPath {
                            Chip(text: "renamed from \(old)")
                        }
                    }
                    Text(request.title).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.xl).padding(.bottom, Theme.Space.m)
    }

    private var fileURL: URL? {
        guard let root = model.analysis?.root else { return nil }
        let url = root.appendingPathComponent(request.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @ViewBuilder
    private var content: some View {
        if model.diffInFlight && model.loadedDiff == nil {
            VStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text("Reading the diff…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff = model.loadedDiff {
            if diff.isBinary {
                message("Binary file", "Its contents changed, but there are no text lines to show.")
            } else if diff.isEmpty {
                message("No changes here", "This file is listed but its contents are identical — usually a "
                                         + "mode change, or a rename with no edits.")
            } else {
                ScrollColumn {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.hunks) { hunk in
                            hunkHeader(hunk)
                            ForEach(hunk.lines) { line in row(line) }
                        }
                        if diff.truncated {
                            Text("Diff truncated — this file changed by more lines than are useful to read here.")
                                .font(Theme.Text.caption).foregroundStyle(Theme.warning)
                                .padding(Theme.Space.m)
                        }
                    }
                    .padding(.bottom, Theme.Space.xl)
                }
            }
        } else {
            message("Could not read this diff", "git returned nothing for this file.")
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: Theme.Space.s) {
            Text(title).font(Theme.Text.heading).foregroundStyle(Theme.ink)
            Text(detail).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hunkHeader(_ hunk: DiffHunk) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("@@ −\(hunk.oldStart) +\(hunk.newStart) @@")
                .font(Theme.Text.mono).foregroundStyle(Theme.accent)
            if !hunk.section.isEmpty {
                Text(hunk.section).font(Theme.Text.mono).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Space.xl).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentWash.opacity(0.5))
    }

    private func row(_ line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Both line numbers, so a removed line still says where it was.
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 46, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 46, alignment: .trailing)
            Text(marker(line)).frame(width: 16, alignment: .center)
                .foregroundStyle(markerColor(line))
            Text(line.text.isEmpty ? " " : line.text)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(line.kind == .context ? Theme.inkSoft : Theme.ink)
            if line.missingTrailingNewline {
                Text(" ↵ no newline at end of file")
                    .foregroundStyle(Theme.warning)
            }
            Spacer(minLength: 0)
        }
        .font(Theme.Text.mono)
        .foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(line))
    }

    private func marker(_ line: DiffLine) -> String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "−"
        case .context: return " "
        }
    }

    private func markerColor(_ line: DiffLine) -> Color {
        switch line.kind {
        case .addition: return Theme.good
        case .deletion: return Theme.critical
        case .context: return Theme.inkMuted
        }
    }

    private func background(_ line: DiffLine) -> Color {
        switch line.kind {
        case .addition: return Theme.good.opacity(0.12)
        case .deletion: return Theme.critical.opacity(0.12)
        case .context: return .clear
        }
    }
}
