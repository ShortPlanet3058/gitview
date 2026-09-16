import SwiftUI
import GitViewCore

struct ContentView: View {
    @EnvironmentObject private var model: AnalysisModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 480, ideal: 700)
        } detail: {
            if let unit = model.selectedUnit, model.selectedRow != nil {
                // `.id` forces a fresh view per unit so `.task(id:)` and scroll position reset.
                UnitDetailView(unit: unit).id(unit.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(model.analysis == nil ? "Details appear here" : "Select a unit")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.analysis?.root.lastPathComponent ?? "GitView")
        .onAppear(perform: openRepositoryFromLaunchArguments)
    }

    /// `GitView /path/to/repo` opens it immediately. Useful from the shell and as an Xcode
    /// scheme argument; anything that is not an existing directory is ignored, which also
    /// skips the `-NSDocumentRevisionsDebugMode YES` pair Xcode injects.
    private func openRepositoryFromLaunchArguments() {
        guard case .idle = model.state else { return }
        let arguments = Array(CommandLine.arguments.dropFirst())
        // `--select <name>` preselects a unit once ranked. Used to drive verification
        // without a pointer; harmless otherwise.
        if let flag = arguments.firstIndex(of: "--select"), flag + 1 < arguments.count {
            model.pendingSelection = arguments[flag + 1]
        }
        var isDirectory: ObjCBool = false
        for argument in arguments
        where FileManager.default.fileExists(atPath: argument, isDirectory: &isDirectory)
            && isDirectory.boolValue {
            model.open(url: URL(fileURLWithPath: argument))
            return
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            EmptyStateView()
        case .loading(let stage):
            VStack(spacing: 12) {
                ProgressView()
                Text(stage).foregroundStyle(.secondary)
                Text("Reading every commit and parsing every file. This takes a few seconds "
                     + "on a large repository.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Analysis failed").font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            RiskTableView()
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var model: AnalysisModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No repository open").font(.title3.weight(.medium))
            Text("GitView ranks individual functions by how complex they are and how often "
                 + "they change.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Choose Repository…") { chooseRepository(into: model) }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
