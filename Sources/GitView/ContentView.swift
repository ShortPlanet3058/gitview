import SwiftUI
import GitViewCore

struct ContentView: View {
    @EnvironmentObject private var model: AnalysisModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detail
        }
        .navigationTitle(model.analysis?.root.lastPathComponent ?? "GitView")
        .onAppear(perform: openRepositoryFromLaunchArguments)
    }

    /// `GitView /path/to/repo` opens it immediately. Useful from the shell and as an Xcode
    /// scheme argument; anything that is not an existing directory is ignored, which also
    /// skips the `-NSDocumentRevisionsDebugMode YES` pair Xcode injects.
    private func openRepositoryFromLaunchArguments() {
        guard case .idle = model.state else { return }
        var isDirectory: ObjCBool = false
        for argument in CommandLine.arguments.dropFirst()
        where FileManager.default.fileExists(atPath: argument, isDirectory: &isDirectory)
            && isDirectory.boolValue {
            model.open(url: URL(fileURLWithPath: argument))
            return
        }
    }

    @ViewBuilder
    private var detail: some View {
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
