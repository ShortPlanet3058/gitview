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
                FreshnessBanner()
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
        // Escape leaves whatever is layered over the screen — a diff, a file's history, a
        // search, an open detail panel — innermost first. It used to clear the search and
        // nothing else, so the key did nothing almost everywhere in the app.
        .onExitCommand { model.goBack() }
        .sheet(isPresented: $model.showSettings) { SettingsSheet().environmentObject(model) }
        // The working copy changes outside the app, so re-read it whenever we come forward.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshWorkingState()
        }
    }

    @ViewBuilder
    private var main: some View {
        switch model.state {
        case .idle: WelcomeScreen()
        case .loading(let progress): LoadingScreen(progress: progress)
        case .failed(let message): FailedScreen(message: message)
        case .loaded:
            if let request = model.diffRequest { DiffViewer(request: request) }
            else if let path = model.fileHistoryPath { FileHistoryView(path: path) }
            else if model.isSearching { SearchScreen() } else {
            switch model.screen {
            case .overview: OverviewScreen()
            case .changes: ChangesScreen()
            case .commits: CommitsScreen()
            case .branches: BranchesScreen()
            case .releases: ReleasesScreen()
            case .contributors: ContributorsScreen()
            case .files: FilesScreen()
            case .activity: ActivityScreen()
            case .hotspots: HotspotsScreen()
            case .coupling: CouplingScreen()
            case .statistics: StatisticsScreen()
            }
            }
        }
    }

    private var detail: AnyView? {
        guard case .loaded = model.state else { return nil }
        // A selected commit wins on any screen: it is the most recent thing the user asked for.
        if let commit = model.selectedCommit {
            return AnyView(CommitDetailPanel(commit: commit).id(commit.sha))
        }
        if model.screen == .contributors, let author = model.selectedAuthor {
            return AnyView(AuthorDetailPanel(author: author).id(author))
        }
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

/// A slim strip under the top bar, shown only when the repository moved under us or a
/// refresh just brought something in. It never covers content and never steals focus: at
/// most it asks for one click, and when GitView could refresh on its own it says what it
/// did rather than changing the numbers silently.
struct FreshnessBanner: View {
    @EnvironmentObject private var model: AnalysisModel

    var body: some View {
        if let error = model.refreshError {
            strip(icon: "exclamationmark.triangle.fill", tint: Theme.warning,
                  message: "Couldn't refresh: \(error)") {
                Button("Try Again") { model.refresh() }.buttonStyle(SecondaryButtonStyle())
                Button { model.refreshError = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkMuted)
            }
        } else if let change = model.outsideChange {
            strip(icon: change.isFastForward ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill",
                  tint: change.isFastForward ? Theme.accent : Theme.warning,
                  message: change.isFastForward
                    ? "\(change.summary) since this was read."
                    : "\(change.summary) — what's on screen describes commits that may no longer exist.") {
                Button("Refresh") { model.refresh() }.buttonStyle(PrimaryButtonStyle())
                Button { model.dismissOutsideChange() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkMuted)
            }
        } else if let note = model.refreshNote {
            strip(icon: "checkmark.circle.fill", tint: Theme.good, message: "Updated — \(note).") {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func strip<Trailing: View>(icon: String, tint: Color, message: String,
                                       @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
                Text(message).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                Spacer()
                trailing()
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, 8)
            .background(tint.opacity(0.08))
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

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
            if model.analysis != nil { GlobalSearchField() }
            Spacer()
            ModeSwitch()
            if let analysis = model.analysis {
                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(model.isRefreshing ? 360 : 0))
                        .animation(model.isRefreshing
                                   ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                   : .default, value: model.isRefreshing)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isRefreshing)
                .help("Re-read this repository (⌘R)")
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

    private var repositoryScreens: [AnalysisModel.Screen] { AnalysisModel.repositoryScreens }
    private var analysisScreens: [AnalysisModel.Screen] { model.analysisScreens }

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
            // A pop-up chevron has to open a pop-up. It used to open a file dialog, which
            // is the one thing this control looks like it does not do.
            Menu {
                let others = RecentRepositories.all().filter { $0.standardizedFileURL != analysis.root.standardizedFileURL }
                if !others.isEmpty {
                    Section("Recent") {
                        ForEach(others, id: \.path) { url in
                            Button {
                                model.open(url: url)
                            } label: {
                                Text(url.lastPathComponent)
                                Text(url.deletingLastPathComponent().path)
                            }
                        }
                    }
                }
                Button("Open Repository…") { chooseRepository(into: model) }
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([analysis.root]) }
                Button("Open in Terminal") { openInTerminal(analysis.root) }
                Button("Copy Path") { copyToPasteboard(analysis.root.path) }
            } label: {
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
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Switch repository")
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
                // Somewhere to go that is not a file dialog. Only shown when there is
                // history to show, so a first run stays as simple as it was.
                let recent = RecentRepositories.all()
                if !recent.isEmpty {
                    HairlineDivider().padding(.vertical, Theme.Space.xs)
                    Text("RECENT").font(Theme.Text.caption.weight(.semibold)).foregroundStyle(Theme.inkMuted)
                    VStack(spacing: 2) {
                        ForEach(recent.prefix(5), id: \.path) { url in
                            Button { model.open(url: url) } label: {
                                HStack(spacing: Theme.Space.s) {
                                    Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                                    Text(url.lastPathComponent).font(Theme.Text.body).foregroundStyle(Theme.ink)
                                    Spacer()
                                    Text(url.deletingLastPathComponent().lastPathComponent + "/")
                                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
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

/// Says what is happening, how far along it is, and how long it has taken.
///
/// The previous version showed one fixed line and promised "a few seconds", which on a
/// large repository was simply untrue — and a wait with no visible progress is one a person
/// cannot tell apart from a hang. Every number here is real: the file count comes from the
/// scanner as results land, the elapsed time is a clock, and nothing advances on its own
/// to give an impression of movement.
struct LoadingScreen: View {
    @EnvironmentObject private var model: AnalysisModel
    let progress: LoadingProgress
    @State private var elapsed: TimeInterval = 0
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            ProgressView().controlSize(.large)
            VStack(spacing: Theme.Space.xs) {
                Text(progress.stage + "…").font(Theme.Text.heading).foregroundStyle(Theme.ink)
                if let detail = progress.detail {
                    Text(detail).font(Theme.Text.body.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                }
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 260)
            }
            if elapsed >= 3 {
                // Only once the wait is long enough to wonder about. Appearing instantly
                // would make every quick load look slow.
                Text("\(Int(elapsed))s so far")
                    .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
            }
            if elapsed >= 5 {
                Button("Stop Waiting") { model.cancelLoading() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(tick) { _ in
            elapsed = model.loadStarted.map { Date().timeIntervalSince($0) } ?? 0
        }
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
            HStack(spacing: Theme.Space.s) {
                Button("Try Again") { model.retryLastOpen() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Choose another repository…") { chooseRepository(into: model) }
                    .buttonStyle(SecondaryButtonStyle())
            }
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
                    CardHeader(title: "You",
                               info: "Used to mark your own commits, and to point out when someone else changes "
                                   + "a file you have worked on. Taken from git config; set it here if the name "
                                   + "you commit under differs.")
                    TextField("Name you commit under", text: $model.identityName)
                        .textFieldStyle(.roundedBorder)
                    Text(model.identityName.isEmpty
                         ? "Using git config. Leave empty to keep that."
                         : "Overriding git config.")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    CardHeader(title: "Cache",
                               info: "Reading history is the slow part — about a minute on a repository whose "
                                   + "history carries large generated files. It is cached per repository and "
                                   + "extended with only the new commits next time.")
                    HStack {
                        Text("Using \(AnalysisCache.sizeOnDisk().byteString) on disk")
                            .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                        Spacer()
                        Button("Clear cache") { AnalysisCache.clearAll() }.buttonStyle(SecondaryButtonStyle())
                    }
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
