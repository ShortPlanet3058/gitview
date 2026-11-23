import SwiftUI
import GitViewCore
import GitViewGit

/// Inspects executed git write commands for the open repository, including timings and full stdout/stderr.
struct GitCommandLogSheet: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case failed = "Failed"
        var id: String { rawValue }
    }

    @Environment(WorkspaceSession.self) private var session
    @Environment(WorkingCopyStore.self) private var workingCopy
    @Environment(\.dismiss) private var dismiss

    @State private var filter: Filter = .all
    @State private var expandedIDs: Set<UUID> = []

    private var displayedRecords: [GitCommandRecord] {
        switch filter {
        case .all:
            return workingCopy.commandLog
        case .failed:
            return workingCopy.commandLog.filter { !$0.succeeded }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Git Command Log")
                        .font(Theme.Text.title)
                        .foregroundStyle(Theme.ink)
                    if let root = session.analysis?.root {
                        Text(root.lastPathComponent)
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
                Spacer()
                SegmentPicker(
                    options: Filter.allCases.map { ($0, $0.rawValue) },
                    selection: $filter
                )
                Button("Clear") {
                    workingCopy.clearCommandLog()
                    expandedIDs.removeAll()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(workingCopy.commandLog.isEmpty)
                Button("Done") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(Theme.Space.l)
            .background(Theme.raised)

            HairlineDivider()

            if displayedRecords.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: filter == .failed ? "checkmark.circle" : "terminal")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.inkMuted)
                    Text(filter == .failed ? "No failed git commands" : "No git commands recorded yet")
                        .font(Theme.Text.heading)
                        .foregroundStyle(Theme.ink)
                    Text("Stage, commit, branch, stash, fetch, and push commands run in this session appear here.")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.inkMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollColumn {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(displayedRecords) { record in
                            recordCard(record)
                        }
                    }
                    .padding(Theme.Space.l)
                }
            }
        }
        .frame(width: 760, height: 520)
        .background(Theme.page)
        .onAppear {
            workingCopy.reloadCommandLog()
            if let firstFailure = workingCopy.commandLog.first(where: { !$0.succeeded }) {
                expandedIDs.insert(firstFailure.id)
            }
        }
    }

    private func recordCard(_ record: GitCommandRecord) -> some View {
        let isExpanded = expandedIDs.contains(record.id)
        let hasOutput = !record.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !record.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Circle()
                        .fill(record.succeeded ? Theme.good : Theme.critical)
                        .frame(width: 8, height: 8)
                    Text(record.commandLine)
                        .font(Theme.Text.mono)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(isExpanded ? 4 : 1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    if !record.succeeded {
                        Chip(text: "exit \(record.exitCode)", tint: Theme.critical)
                    }
                    Text(formattedDuration(record.duration))
                        .font(Theme.Text.caption.monospacedDigit())
                        .foregroundStyle(Theme.inkMuted)
                    Text(RiskExplanation.relative(record.timestamp, now: Date()))
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard hasOutput else { return }
                    if isExpanded {
                        expandedIDs.remove(record.id)
                    } else {
                        expandedIDs.insert(record.id)
                    }
                }

                HStack(spacing: Theme.Space.xs) {
                    Button("Copy Command") {
                        copyToPasteboard(record.commandLine)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.mini)

                    if hasOutput {
                        Button(isExpanded ? "Hide Output" : "Show Output") {
                            if isExpanded {
                                expandedIDs.remove(record.id)
                            } else {
                                expandedIDs.insert(record.id)
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .controlSize(.mini)

                        Button("Copy Output") {
                            copyToPasteboard(combinedOutput(for: record))
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .controlSize(.mini)
                    }
                    Spacer()
                }

                if isExpanded && hasOutput {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        let trimmedErr = record.stderr.trimmingCharacters(in: .newlines)
                        let trimmedOut = record.stdout.trimmingCharacters(in: .newlines)
                        if !trimmedErr.isEmpty {
                            Text(trimmedErr)
                                .font(Theme.Text.mono)
                                .foregroundStyle(record.succeeded ? Theme.inkSoft : Theme.critical)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Theme.Space.s)
                                .background(Theme.page, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        if !trimmedOut.isEmpty {
                            Text(trimmedOut)
                                .font(Theme.Text.mono)
                                .foregroundStyle(Theme.inkSoft)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Theme.Space.s)
                                .background(Theme.page, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    private func combinedOutput(for record: GitCommandRecord) -> String {
        [record.stderr.trimmingCharacters(in: .newlines), record.stdout.trimmingCharacters(in: .newlines)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "\(max(1, Int((duration * 1000).rounded()))) ms"
        }
        return String(format: "%.2fs", duration)
    }
}
