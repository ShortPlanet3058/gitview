import SwiftUI
import GitViewCore

/// Sidebar · top bar + page · optional detail, drawn by hand so the look is the app's own.
struct AppShell: View {
    @EnvironmentObject private var model: AnalysisModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 216)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            VStack(spacing: 0) {
                TopBar()
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 0) {
                    main.frame(minWidth: 560, maxWidth: .infinity)
                    if let detail {
                        Rectangle().fill(Theme.hairline).frame(width: 1)
                        detail.frame(width: 420)
                    }
                }
            }
        }
        .background(Theme.page)
        .ignoresSafeArea()
        .sheet(isPresented: $model.showSettings) { SettingsSheet().environmentObject(model) }
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
            case .commits: CommitsScreen()
            case .branches: BranchesScreen()
            case .contributors: ContributorsScreen()
            case .files: FilesScreen()
            case .activity: ActivityScreen()
            case .hotspots: HotspotsScreen()
            case .coupling: CouplingScreen()
            case .statistics: StatisticsScreen()
            }
        }
    }

    private var detail: AnyView? {
        guard case .loaded = model.state else { return nil }
        switch model.screen {
        case .coupling:
            if let pair = model.selectedPair { return AnyView(PairDetailPanel(row: pair).id(pair.id)) }
            if let unit = model.selectedUnit, let row = model.selectedRow {
                return AnyView(UnitDetailPanel(unit: unit, row: row).id(unit.id))
            }
        case .overview, .hotspots, .files:
            if let unit = model.selectedUnit, let row = model.selectedRow {
                return AnyView(UnitDetailPanel(unit: unit, row: row).id(unit.id))
            }
        default:
            break
        }
        return nil
    }

}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject private var model: AnalysisModel

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if let analysis = model.analysis {
                VStack(alignment: .leading, spacing: 1) {
                    Text(analysis.root.lastPathComponent).font(Theme.Text.heading).foregroundStyle(Theme.ink)
                    Text(abbreviated(analysis.root.path)).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold))
                    Text(analysis.info.currentBranch).font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.inkSoft)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.wash, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            } else {
                Text("GitView").font(Theme.Text.heading).foregroundStyle(Theme.ink)
            }
            Spacer()
            ModeSwitch()
            Spacer()
            if let analysis = model.analysis {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([analysis.root])
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(height: 64)
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Standard / Advanced. Standard is the essentials; Advanced adds pages and every metric.
struct ModeSwitch: View {
    @EnvironmentObject private var model: AnalysisModel
    var body: some View {
        HStack(spacing: 2) {
            option("Standard", selected: !model.advanced) { model.advanced = false }
            option("Advanced", selected: model.advanced) { model.advanced = true }
        }
        .padding(3)
        .background(Theme.wash, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous).strokeBorder(Theme.hairline))
        .help("Standard shows the essentials. Advanced adds Statistics and every metric and control.")
    }

    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Theme.onAccent : Theme.inkSoft)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(selected ? Theme.accent : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var model: AnalysisModel

    private var repositoryScreens: [AnalysisModel.Screen] { [.overview, .commits, .branches, .contributors, .files, .activity] }
    private var analysisScreens: [AnalysisModel.Screen] {
        model.advanced ? [.hotspots, .coupling, .statistics] : [.hotspots, .coupling]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 26, height: 26)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("GitView").font(Theme.Text.title).foregroundStyle(Theme.ink)
            }
            .padding(.top, 40)
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.l)

            repository
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.l)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(repositoryScreens, id: \.self, content: navButton)
                Text("ANALYSIS")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.l).padding(.bottom, 4)
                ForEach(analysisScreens, id: \.self, content: navButton)
            }
            .padding(.horizontal, Theme.Space.s)
            .disabled(model.analysis == nil)
            .opacity(model.analysis == nil ? 0.45 : 1)

            Spacer()

            VStack(alignment: .leading, spacing: 2) {
                HairlineDivider().padding(.bottom, Theme.Space.s)
                NavButton(title: "Settings", systemImage: "gearshape", selected: false) { model.showSettings = true }
                    .disabled(model.analysis == nil)
                Text(model.advanced ? "Advanced · in-depth analysis" : "Standard · essential information")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal, Theme.Space.m).padding(.top, 4)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.bottom, Theme.Space.l)
        }
        .background(Theme.sidebar)
    }

    private func navButton(_ screen: AnalysisModel.Screen) -> some View {
        NavButton(title: screen.title, systemImage: screen.symbol, selected: model.screen == screen) {
            model.screen = screen
        }
    }

    @ViewBuilder
    private var repository: some View {
        if let analysis = model.analysis {
            Button { chooseRepository(into: model) } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.inkMuted)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(analysis.root.lastPathComponent).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(analysis.root.deletingLastPathComponent().lastPathComponent + "/")
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.Text.display).foregroundStyle(Theme.ink)
            if let subtitle {
                Text(subtitle).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Scrollable page with consistent gutters (a fixed stack under static rendering).
struct Page<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollColumn {
            VStack(alignment: .leading, spacing: Theme.Space.l) { content }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xl)
                .padding(.bottom, Theme.Space.xxl)
                .frame(maxWidth: 1180, alignment: .leading)
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
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 64, height: 64)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(spacing: Theme.Space.s) {
                Text("Understand any repository. Faster.").font(Theme.Text.display).foregroundStyle(Theme.ink)
                Text("GitView reads a project's git history and shows you who works on it, how it changes, "
                     + "and which functions are both complicated and changed often — where bugs tend to appear.")
                    .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
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

// MARK: - Settings (model parameters live here, not on every page)

struct SettingsSheet: View {
    @EnvironmentObject private var model: AnalysisModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text("Settings").font(Theme.Text.title).foregroundStyle(Theme.ink)
                Spacer()
                Button("Done") { model.showSettings = false }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    CardHeader(title: "Risk model",
                               info: "A function's risk is its complexity combined with how much it has changed "
                                   + "recently. The half-life sets how fast a commit's weight fades: at 365 days a "
                                   + "year-old commit counts half as much as one made today.")
                    HStack {
                        Text("Half-life").font(Theme.Text.body).foregroundStyle(Theme.ink)
                        Spacer()
                        Text("\(Int(model.halfLifeDays)) days").font(Theme.Text.body.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                    }
                    Slider(value: $model.halfLifeDays, in: 30...1095, step: 5)
                    Text(halfLifeCaption).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    CardHeader(title: "What counts")
                    Toggle("Exclude test code from hotspots", isOn: $model.excludeTests).toggleStyle(.switch)
                    Toggle("Exclude vendored and generated code", isOn: $model.excludeGenerated).toggleStyle(.switch)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Also ignore paths containing").font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                        TextField("CNIOLLHTTP, Generated", text: $model.ignoredPaths)
                            .textFieldStyle(.roundedBorder)
                        Text("Comma separated. For vendored code that carries no generated marker.")
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                    Stepper("Ignore functions with fewer than \(model.minimumCommits) commit\(model.minimumCommits == 1 ? "" : "s")",
                            value: $model.minimumCommits, in: 1...25)
                    Stepper("Pairs need at least \(model.minSharedCommits) shared commits",
                            value: $model.minSharedCommits, in: 2...20)
                }
                .font(Theme.Text.body)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520)
        .background(Theme.page)
    }

    private var halfLifeCaption: String {
        switch model.halfLifeDays {
        case ..<120: return "Short: most accurate attribution, but function-level churn is sparse enough that change frequency barely registers."
        case ..<550: return "Balanced: keeps most of the attribution accuracy while change frequency still separates functions. Measured sweet spot."
        default: return "Long: change frequency dominates, but older commits are attributed to lines that have since drifted, so accuracy drops."
        }
    }
}
