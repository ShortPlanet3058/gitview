import SwiftUI
import GitViewCore
import GitViewGit

/// Sidebar · top bar + page · optional detail, drawn by hand so the look is the app's own.
struct AppShell: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(WorkingCopyStore.self) private var workingCopy

    var body: some View {
        @Bindable var workingCopy = workingCopy
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 216)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            VStack(spacing: 0) {
                TopBar()
                Rectangle().fill(Theme.hairline).frame(height: 1)
                LoadingStrip()
                FreshnessBanner()
                HStack(spacing: 0) {
                    main
                        .frame(minWidth: 560, maxWidth: .infinity)
                        .transition(.opacity)
                    if hasDetail {
                        Rectangle().fill(Theme.hairline).frame(width: 1)
                        detailContent
                            .frame(width: 420)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.16), value: session.navigation.screen)
                .animation(.easeOut(duration: 0.2), value: session.navigation.selectedUnitID)
                .animation(.easeOut(duration: 0.2), value: session.navigation.selectedCommitSHA)
                .animation(.easeOut(duration: 0.2), value: session.navigation.selectedAuthor)
                .animation(.easeOut(duration: 0.2), value: session.navigation.selectedPairID)
            }
        }
        .background(Theme.page)
        .animation(.easeInOut(duration: 0.2), value: session.loadProgress)
        .animation(.easeInOut(duration: 0.25), value: session.outsideChange)
        .animation(.easeInOut(duration: 0.25), value: session.refreshNote)
        .animation(.easeInOut(duration: 0.2), value: session.readiness)
        .ignoresSafeArea()
        .onExitCommand { session.goBack() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.workingCopy.refreshWorkingState()
        }
        .alert(item: $workingCopy.confirmation) { confirmation in
            if let alternativeLabel = confirmation.alternativeLabel, let alternative = confirmation.alternative {
                return Alert(title: Text(confirmation.title), message: Text(confirmation.message),
                             primaryButton: .default(Text(alternativeLabel), action: alternative),
                             secondaryButton: .destructive(Text(confirmation.confirmLabel),
                                                           action: confirmation.perform))
            }
            return Alert(title: Text(confirmation.title), message: Text(confirmation.message),
                         primaryButton: .destructive(Text(confirmation.confirmLabel),
                                                     action: confirmation.perform),
                         secondaryButton: .cancel())
        }
    }

    @ViewBuilder
    private func awaiting<Content: View>(_ ready: Bool, _ what: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        if ready {
            content()
        } else {
            VStack { Spacer(); StillReading(what: what); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var main: some View {
        switch session.state {
        case .idle: WelcomeScreen()
        case .loading(let progress): LoadingScreen(progress: progress)
        case .failed(let message): FailedScreen(message: message)
        case .loaded:
            if let request = session.inspector.diffRequest { DiffViewer(request: request) }
            else if let path = session.inspector.fileHistoryPath { FileHistoryView(path: path) }
            else if session.search.isSearching { SearchScreen() } else {
            switch session.navigation.screen {
            case .overview: OverviewScreen()
            case .changes: ChangesScreen()
            case .branches: BranchesScreen()
            case .files: FilesScreen()
            case .commits: awaiting(session.readiness.hasHistory, "the commit history") { CommitsScreen() }
            case .releases: awaiting(session.readiness.hasHistory, "the commit history") { ReleasesScreen() }
            case .contributors: awaiting(session.readiness.hasHistory, "the commit history") { ContributorsScreen() }
            case .activity: awaiting(session.readiness.hasHistory, "the commit history") { ActivityScreen() }
            case .hotspots: awaiting(session.readiness.hasUnits, "the source files") { HotspotsScreen() }
            case .coupling: awaiting(session.readiness.hasUnits, "the source files") { CouplingScreen() }
            case .statistics: awaiting(session.readiness.hasUnits, "the source files") { StatisticsScreen() }
            }
            }
        }
    }

    private var hasDetail: Bool {
        guard case .loaded = session.state else { return false }
        if session.selectedCommit != nil { return true }
        if session.navigation.screen == .contributors && session.navigation.selectedAuthor != nil { return true }
        switch session.navigation.screen {
        case .coupling:
            return session.selectedPair != nil || (session.selectedUnit != nil && session.selectedRow != nil)
        case .overview, .hotspots, .files:
            return session.selectedUnit != nil && session.selectedRow != nil
        default:
            return false
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if case .loaded = session.state {
            if let commit = session.selectedCommit {
                CommitDetailPanel(commit: commit).id(commit.sha)
            } else if session.navigation.screen == .contributors, let author = session.navigation.selectedAuthor {
                AuthorDetailPanel(author: author).id(author)
            } else {
                switch session.navigation.screen {
                case .coupling:
                    if let pair = session.selectedPair {
                        PairDetailPanel(row: pair).id(pair.id)
                    } else if let unit = session.selectedUnit, let row = session.selectedRow {
                        UnitDetailPanel(unit: unit, row: row).id(unit.id)
                    }
                case .overview, .hotspots, .files:
                    if let unit = session.selectedUnit, let row = session.selectedRow {
                        UnitDetailPanel(unit: unit, row: row).id(unit.id)
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

}

// MARK: - Top bar

/// Carries on reporting the read after the app has become usable.
///
/// Once branches and the working copy are on screen the loading screen is gone, but the
/// history and the parser are often still running. Without this the app would look
/// finished while half of it was still arriving — and the pages that are not ready yet
/// would look broken rather than pending.
struct LoadingStrip: View {
    @Environment(WorkspaceSession.self) private var session
    @State private var elapsed: TimeInterval = 0
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        if let progress = session.loadProgress, session.hasRepository {
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                    Text(progress.stage + "…").font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                    if let detail = progress.detail {
                        Text(detail).font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
                    }
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 120)
                    }
                    Spacer()
                    if elapsed >= 3 {
                        Text("\(Int(elapsed))s").font(Theme.Text.caption.monospacedDigit())
                            .foregroundStyle(Theme.inkMuted)
                    }
                    Button("Stop") { session.cancelLoading() }
                        .buttonStyle(.plain)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, 6)
                .background(Theme.wash)
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            .onReceive(tick) { _ in
                elapsed = session.loadStarted.map { Date().timeIntervalSince($0) } ?? 0
            }
        }
    }
}

/// A slim strip under the top bar, shown only when the repository moved under us or a
/// refresh just brought something in.
struct FreshnessBanner: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(WorkingCopyStore.self) private var workingCopy

    var body: some View {
        if let writeError = workingCopy.writeError,
           session.navigation.screen != .changes || session.inspector.diffRequest != nil {
            strip(icon: "exclamationmark.triangle.fill", tint: Theme.critical,
                  message: "git refused that: \(writeError)") {
                Button { workingCopy.writeError = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkMuted)
            }
        } else if let error = session.refreshError {
            strip(icon: "exclamationmark.triangle.fill", tint: Theme.warning,
                  message: "Couldn't refresh: \(error)") {
                Button("Try Again") { session.refresh() }.buttonStyle(SecondaryButtonStyle())
                Button { session.refreshError = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkMuted)
            }
        } else if let change = session.outsideChange {
            strip(icon: change.isFastForward ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill",
                  tint: change.isFastForward ? Theme.accent : Theme.warning,
                  message: change.isFastForward
                    ? "\(change.summary) since this was read."
                    : "\(change.summary) — what's on screen describes commits that may no longer exist.") {
                Button("Refresh") { session.refresh() }.buttonStyle(PrimaryButtonStyle())
                Button { session.dismissOutsideChange() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkMuted)
            }
        } else if let note = session.refreshNote {
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

/// The repository GitView is showing, and the control for changing it.
///
/// It used to be the repository's name in plain text here and the same name again in a chip
/// in the sidebar: the most prominent words on screen, looking like a page title, saying
/// nothing about what they were. People reasonably read "nio" as a heading rather than as
/// "the project you are looking at". Now it says so, in one place, and looks like the
/// pull-down it has always been.
struct RepositoryPicker: View {
    @Environment(WorkspaceSession.self) private var session
    let analysis: RepositoryAnalysis
    @State private var hovering = false
    @State private var showingMenu = false

    var body: some View {
        Button { showingMenu.toggle() } label: { picker }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help("\(analysis.root.path)\nClick to switch repository, or ⌘O to open another")
            .accessibilityLabel("Repository \(analysis.root.lastPathComponent)")
            .accessibilityHint("Switch to another repository")
            .popover(isPresented: $showingMenu, arrowEdge: .bottom) {
                RepositoryMenu(analysis: analysis, dismiss: { showingMenu = false })
                    .environment(session)
            }
    }

    private var picker: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("REPOSITORY")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .tracking(0.6)
                Text(analysis.root.lastPathComponent)
                    .font(Theme.Text.heading).foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.inkMuted)
                .rotationEffect(.degrees(showingMenu ? 180 : 0))
                .animation(.easeOut(duration: 0.15), value: showingMenu)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(hovering || showingMenu ? Theme.raised : Theme.surface,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .strokeBorder(hovering || showingMenu ? Theme.accent.opacity(0.5) : Theme.hairline))
        .contentShape(Rectangle())
    }
}

/// The contents of the repository pop-up, drawn with the app's own components.
struct RepositoryMenu: View {
    @Environment(WorkspaceSession.self) private var session
    let analysis: RepositoryAnalysis
    let dismiss: () -> Void

    private var others: [URL] {
        RecentRepositories.all().filter {
            $0.standardizedFileURL != analysis.root.standardizedFileURL
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("OPEN")
            row(name: analysis.root.lastPathComponent,
                detail: analysis.root.deletingLastPathComponent().path,
                checked: true) {}

            if !others.isEmpty {
                heading("RECENT")
                // Capped: this is a switcher, not a file browser. Everything ever opened is
                // in File ▸ Open Recent.
                ForEach(others.prefix(6), id: \.path) { url in
                    row(name: url.lastPathComponent,
                        detail: url.deletingLastPathComponent().path,
                        checked: false) {
                        dismiss()
                        session.open(url: url)
                    }
                }
            }

            Divider().overlay(Theme.hairline).padding(.vertical, Theme.Space.xs)

            action("Open Repository…", "folder.badge.plus") {
                dismiss()
                chooseRepository(into: session)
            }
            action("Reveal in Finder", "folder") { dismiss(); revealInFinder(analysis.root) }
            action("Open in Terminal", "terminal") { dismiss(); openInTerminal(analysis.root) }
            action("Copy Path", "doc.on.clipboard") { dismiss(); copyToPasteboard(analysis.root.path) }
        }
        .padding(Theme.Space.s)
        .frame(width: 320)
        .background(Theme.surface)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.inkMuted)
            .tracking(0.6)
            .padding(.horizontal, Theme.Space.s)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func row(name: String, detail: String, checked: Bool,
                     action: @escaping () -> Void) -> some View {
        MenuRow(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: checked ? "checkmark.circle.fill" : "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(checked ? Theme.accent : Theme.inkMuted)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(detail).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func action(_ title: String, _ icon: String, _ perform: @escaping () -> Void) -> some View {
        MenuRow(action: perform) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon).font(.system(size: 11))
                    .foregroundStyle(Theme.inkSoft).frame(width: 14)
                Text(title).font(Theme.Text.body).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
            }
        }
    }
}

/// One row of the pop-up: full-width hit area, accent highlight under the pointer.
struct MenuRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? Theme.accentWash : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

struct TopBar: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(WorkingCopyStore.self) private var workingCopy

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if let analysis = session.analysis {
                RepositoryPicker(analysis: analysis)
                BranchPicker(analysis: analysis)
                let hasRemote = analysis.info.remoteURL != nil
                    || workingCopy.pushPlan != nil
                    || analysis.branches.contains(where: \.isRemote)
                if hasRemote {
                    Button { workingCopy.fetch() } label: {
                        Label("Fetch", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(workingCopy.writeInFlight)
                    .help("Fetch all remotes and prune deleted branches")
                    if analysis.workingState.behind > 0 {
                        Button { workingCopy.pull() } label: {
                            Label("Pull \(analysis.workingState.behind)", systemImage: "arrow.down")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(workingCopy.writeInFlight)
                        .help("Fast-forward pull from upstream (git pull --ff-only)")
                    }
                }
            } else {
                Text("GitView").font(Theme.Text.heading).foregroundStyle(Theme.ink)
            }
            Spacer()
            if session.analysis != nil { GlobalSearchField() }
            Spacer()
            ModeSwitch()
            if let analysis = session.analysis {
                Button { session.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(session.isRefreshing ? 360 : 0))
                        .animation(session.isRefreshing
                                   ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                   : .default, value: session.isRefreshing)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(session.isRefreshing)
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
}

struct BranchPicker: View {
    @Environment(WorkingCopyStore.self) private var workingCopy
    let analysis: RepositoryAnalysis
    @State private var showingPopover = false
    @State private var hovering = false
    @State private var filter = ""
    @State private var newBranchName = ""

    private var state: WorkingState { analysis.workingState }

    var body: some View {
        Button { showingPopover.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold))
                Text(analysis.info.currentBranch).font(.system(size: 11, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                if state.behind > 0 || state.ahead > 0 {
                    HStack(spacing: 4) {
                        if state.behind > 0 {
                            Text("↓\(state.behind)").foregroundStyle(Theme.warning)
                        }
                        if state.ahead > 0 {
                            Text("↑\(state.ahead)").foregroundStyle(Theme.good)
                        }
                    }
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .foregroundStyle(Theme.inkSoft)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(hovering || showingPopover ? Theme.raised : Theme.wash,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(hovering || showingPopover ? Theme.accent.opacity(0.45) : Theme.hairline))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Switch or create a branch")
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var filteredBranches: [BranchInfo] {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return analysis.branches }
        return analysis.branches.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var popoverContent: some View {
        let localBranches = filteredBranches.filter { !$0.isRemote }
        let remoteBranches = filteredBranches.filter(\.isRemote)

        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.xs) {
                TextField("New branch name…", text: $newBranchName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createNewBranch)
                Button("Create", action: createNewBranch)
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.small)
                    .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workingCopy.writeInFlight)
            }

            TextField("Filter branches", text: $filter)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !localBranches.isEmpty {
                        sectionHeader("LOCAL")
                        ForEach(localBranches) { branch in
                            branchRow(branch)
                        }
                    }
                    if !remoteBranches.isEmpty {
                        sectionHeader("REMOTE")
                        ForEach(remoteBranches) { branch in
                            branchRow(branch)
                        }
                    }
                    if localBranches.isEmpty && remoteBranches.isEmpty {
                        Text("No matching branches.")
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                            .padding(.vertical, Theme.Space.s)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(Theme.Space.m)
        .frame(width: 300)
        .background(Theme.surface)
    }

    private func createNewBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        newBranchName = ""
        showingPopover = false
        workingCopy.createBranch(name: name)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.inkMuted)
            .tracking(0.6)
            .padding(.horizontal, Theme.Space.s)
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, 2)
    }

    private func branchRow(_ branch: BranchInfo) -> some View {
        MenuRow {
            guard !branch.isCurrent else { showingPopover = false; return }
            showingPopover = false
            workingCopy.switchBranch(branch.name, isRemote: branch.isRemote)
        } content: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: branch.isCurrent ? "checkmark" : "arrow.triangle.branch")
                    .font(.system(size: 10, weight: branch.isCurrent ? .bold : .regular))
                    .foregroundStyle(branch.isCurrent ? Theme.accent : Theme.inkMuted)
                    .frame(width: 12)
                Text(branch.name)
                    .font(branch.isCurrent ? Theme.Text.bodyBold : Theme.Text.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if branch.isDefault { Chip(text: "default", tint: Theme.accent) }
                if branch.isRemote { Chip(text: "remote") }
            }
        }
    }
}

/// Standard / Advanced. Standard is the essentials; Advanced adds pages and every metric.
struct ModeSwitch: View {
    @Environment(AppPreferences.self) private var preferences
    var body: some View {
        HStack(spacing: 2) {
            option("Standard", selected: !preferences.advanced) { preferences.advanced = false }
            option("Advanced", selected: preferences.advanced) { preferences.advanced = true }
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
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.openSettings) private var openSettings

    private var repositoryScreens: [NavigationStore.Screen] { NavigationStore.repositoryScreens }
    private var analysisScreens: [NavigationStore.Screen] { session.analysisScreens }

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
            .disabled(session.analysis == nil)
            .opacity(session.analysis == nil ? 0.45 : 1)

            Spacer()

            VStack(alignment: .leading, spacing: 2) {
                HairlineDivider().padding(.bottom, Theme.Space.s)
                NavButton(title: "Settings", systemImage: "gearshape", selected: false) { openSettings() }
                Text(preferences.advanced ? "Advanced · in-depth analysis" : "Standard · essential information")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal, Theme.Space.m).padding(.top, 4)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.bottom, Theme.Space.l)
        }
        .background(Theme.sidebar)
    }

    private func navButton(_ screen: NavigationStore.Screen) -> some View {
        NavButton(title: screen.title, systemImage: screen.symbol, selected: session.navigation.screen == screen) {
            session.show(screen)
        }
    }

    @ViewBuilder
    private var repository: some View {
        if session.analysis == nil {
            Button("Choose repository…") { chooseRepository(into: session) }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(session.isLoading)
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
    @Environment(WorkspaceSession.self) private var session
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
                Button("Choose a repository…") { chooseRepository(into: session) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Text("or drop a project folder here").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                let recent = RecentRepositories.all()
                if !recent.isEmpty {
                    HairlineDivider().padding(.vertical, Theme.Space.xs)
                    Text("RECENT").font(Theme.Text.caption.weight(.semibold)).foregroundStyle(Theme.inkMuted)
                    VStack(spacing: 2) {
                        ForEach(recent.prefix(5), id: \.path) { url in
                            Button { session.open(url: url) } label: {
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
                    Task { @MainActor in session.open(url: url) }
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
struct LoadingScreen: View {
    @Environment(WorkspaceSession.self) private var session
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
                Text("\(Int(elapsed))s so far")
                    .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
            }
            if elapsed >= 5 {
                Button("Stop Waiting") { session.cancelLoading() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(tick) { _ in
            elapsed = session.loadStarted.map { Date().timeIntervalSince($0) } ?? 0
        }
    }
}

struct FailedScreen: View {
    @Environment(WorkspaceSession.self) private var session
    let message: String
    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 32)).foregroundStyle(Theme.warning)
            Text("That didn't work").font(Theme.Text.title).foregroundStyle(Theme.ink)
            Text(message).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: 460)
            HStack(spacing: Theme.Space.s) {
                Button("Try Again") { session.retryLastOpen() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Choose another repository…") { chooseRepository(into: session) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
