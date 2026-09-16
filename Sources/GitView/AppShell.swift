import SwiftUI
import GitViewCore

/// Sidebar · main · optional detail, drawn by hand so the look is the app's own.
struct AppShell: View {
    @EnvironmentObject private var model: AnalysisModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 224)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            main
                .frame(minWidth: 560, maxWidth: .infinity)
            if let detail {
                Rectangle().fill(Theme.hairline).frame(width: 1)
                detail
                    .frame(width: 420)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Theme.page)
        .ignoresSafeArea()
        .onAppear(perform: applyLaunchArguments)
        .animation(.easeInOut(duration: 0.18), value: model.selectedUnitID != nil || model.selectedPairID != nil)
    }

    @ViewBuilder
    private var main: some View {
        switch model.state {
        case .idle: WelcomeScreen()
        case .loading(let stage): LoadingScreen(stage: stage)
        case .failed(let message): FailedScreen(message: message)
        case .loaded:
            switch model.screen {
            case .overview: OverviewScreen()
            case .hotspots: HotspotsScreen()
            case .coupling: CouplingScreen()
            }
        }
    }

    private var detail: AnyView? {
        guard case .loaded = model.state else { return nil }
        switch model.screen {
        case .coupling:
            if let pair = model.selectedPair { return AnyView(PairDetailPanel(row: pair).id(pair.id)) }
        default:
            if let unit = model.selectedUnit, let row = model.selectedRow {
                return AnyView(UnitDetailPanel(unit: unit, row: row).id(unit.id))
            }
        }
        return nil
    }

    /// `GitView <repo> [--select <unit>] [--screen overview|hotspots|coupling] [--advanced]`.
    /// Anything that is not an existing directory is ignored, which skips the
    /// `-NSDocumentRevisionsDebugMode YES` pair Xcode injects.
    private func applyLaunchArguments() {
        guard case .idle = model.state else { return }
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let flag = arguments.firstIndex(of: "--select"), flag + 1 < arguments.count {
            model.pendingSelection = arguments[flag + 1]
        }
        if let flag = arguments.firstIndex(of: "--select-pair"), flag + 1 < arguments.count {
            model.pendingPairSelection = arguments[flag + 1]
        }
        if let flag = arguments.firstIndex(of: "--screen"), flag + 1 < arguments.count {
            switch arguments[flag + 1] {
            case "hotspots": model.screen = .hotspots
            case "coupling": model.screen = .coupling
            default: model.screen = .overview
            }
        }
        if arguments.contains("--advanced") { model.advanced = true }
        if arguments.contains("--simple") { model.advanced = false }
        var isDirectory: ObjCBool = false
        for argument in arguments
        where FileManager.default.fileExists(atPath: argument, isDirectory: &isDirectory) && isDirectory.boolValue {
            model.open(url: URL(fileURLWithPath: argument))
            return
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var model: AnalysisModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights under the hidden title bar.
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("GitView").font(Theme.Text.heading).foregroundStyle(Theme.ink)
            }
            .padding(.top, 40)
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.l)

            repository
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.l)

            VStack(spacing: 2) {
                NavButton(title: "Overview", systemImage: "square.grid.2x2", selected: model.screen == .overview) {
                    model.screen = .overview
                }
                NavButton(title: "Hotspots", systemImage: "flame", selected: model.screen == .hotspots) {
                    model.screen = .hotspots
                }
                NavButton(title: "Change together", systemImage: "link", selected: model.screen == .coupling) {
                    model.screen = .coupling
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .disabled(model.analysis == nil)
            .opacity(model.analysis == nil ? 0.45 : 1)

            Spacer()

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HairlineDivider()
                Toggle(isOn: $model.advanced) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Advanced").font(Theme.Text.body).foregroundStyle(Theme.ink)
                        Text(model.advanced ? "All metrics and controls" : "Plain-language view")
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.sidebar)
    }

    @ViewBuilder
    private var repository: some View {
        if let analysis = model.analysis {
            Button { chooseRepository(into: model) } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.inkMuted)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(analysis.root.lastPathComponent).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text("\(analysis.commits.count.formatted()) commits")
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Theme.inkMuted)
                }
                .padding(Theme.Space.m)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
            }
            .buttonStyle(.plain)
            .help("Choose another repository")
        } else {
            Button("Choose repository…") { chooseRepository(into: model) }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isLoading)
        }
    }
}

// MARK: - Screen scaffolding

struct ScreenHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.Text.display).foregroundStyle(Theme.ink)
            if let subtitle {
                Text(subtitle).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
            }
        }
        .padding(.top, 36)
    }
}

/// Scrollable page with consistent gutters.
struct Page<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) { content }
                .padding(.horizontal, Theme.Space.xxl)
                .padding(.bottom, Theme.Space.xxl)
                .frame(maxWidth: 980, alignment: .leading)
        }
    }
}

// MARK: - Welcome / loading / failed

struct WelcomeScreen: View {
    @EnvironmentObject private var model: AnalysisModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer()
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
            VStack(spacing: Theme.Space.s) {
                Text("See where a codebase is fragile").font(Theme.Text.display).foregroundStyle(Theme.ink)
                Text("GitView reads a project's git history and points at the individual functions that are "
                     + "both complicated and changed often — the places where bugs tend to appear.")
                    .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            VStack(spacing: Theme.Space.m) {
                Button("Choose a repository…") { chooseRepository(into: model) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Text("or drop a project folder here").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: 480)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(targeted ? Theme.accent : Theme.hairline,
                                  style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [6, 4]))
            )
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.open(url: url) }
                }
                return true
            }
            Spacer()
            Text("Nothing leaves your machine. GitView only runs git and reads files locally.")
                .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                .padding(.bottom, Theme.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoadingScreen: View {
    let stage: String
    var body: some View {
        VStack(spacing: Theme.Space.l) {
            ProgressView().controlSize(.large)
            Text(stage).font(Theme.Text.heading).foregroundStyle(Theme.ink)
            Text("Reading every commit, then parsing every file. A few seconds on a large project.")
                .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FailedScreen: View {
    @EnvironmentObject private var model: AnalysisModel
    let message: String
    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 32)).foregroundStyle(Theme.warning)
            Text("That didn't work").font(Theme.Text.title).foregroundStyle(Theme.ink)
            Text(message).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: 460)
            Button("Choose another repository…") { chooseRepository(into: model) }
                .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
