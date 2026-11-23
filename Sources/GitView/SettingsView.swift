import SwiftUI
import GitViewCore

/// Native macOS Settings scene (`Cmd+,`), editing persisted application preferences
/// and disk caches without requiring a repository to be open first.
public struct SettingsView: View {
    @Bindable private var preferences: AppPreferences
    @State private var cacheBytes: Int64 = AnalysisCache.sizeOnDisk()

    public init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        CardHeader(title: "Experience mode")
                        SegmentPicker(
                            options: [(false, "Standard"), (true, "Advanced")],
                            selection: $preferences.advanced
                        )
                        Text(preferences.advanced
                             ? "Advanced unlocks hunk & line staging, stashes, blame time-travel, branch graphs, worktrees, tags, hotspots, and coupling analysis."
                             : "Standard focuses on everyday Git: saving changes, switching branches, and browsing history and files cleanly without technical jargon.")
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if preferences.advanced {
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            CardHeader(
                                title: "Risk model",
                                info: "A function's risk is its complexity combined with how much it has changed "
                                    + "recently. The half-life sets how fast a commit's weight fades: at 365 days a "
                                    + "year-old commit counts half as much as one made today."
                            )
                            HStack {
                                Text("Half-life").font(Theme.Text.body).foregroundStyle(Theme.ink)
                                Spacer()
                                Text("\(Int(preferences.halfLifeDays)) days")
                                    .font(Theme.Text.body.monospacedDigit())
                                    .foregroundStyle(Theme.inkSoft)
                            }
                            Slider(value: $preferences.halfLifeDays, in: 30...1095, step: 5)
                            Text(halfLifeCaption)
                                .font(Theme.Text.caption)
                                .foregroundStyle(Theme.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        CardHeader(
                            title: "Identity",
                            info: "Used to highlight your own commits and warn when someone else edits a file "
                                + "you have worked on. Leave blank to read from git config."
                        )
                        TextField("Name you commit under", text: $preferences.identityName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Email you commit under", text: $preferences.identityEmail)
                            .textFieldStyle(.roundedBorder)
                        Text(preferences.identityName.isEmpty && preferences.identityEmail.isEmpty
                             ? "Using git config. Leave empty to keep that."
                             : "Overriding git config.")
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.inkMuted)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        CardHeader(title: "Tools & Integration")
                        HStack {
                            Text("Editor").font(Theme.Text.body).foregroundStyle(Theme.ink)
                            Spacer()
                            Picker("Editor", selection: $preferences.preferredEditor) {
                                ForEach(ExternalEditor.allCases) { editor in
                                    Text(editor.title).tag(editor)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        }
                        HStack {
                            Text("Terminal").font(Theme.Text.body).foregroundStyle(Theme.ink)
                            Spacer()
                            Picker("Terminal", selection: $preferences.preferredTerminal) {
                                ForEach(ExternalTerminal.allCases) { terminal in
                                    Text(terminal.title).tag(terminal)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        }
                        if preferences.advanced {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Custom git executable path (optional)")
                                    .font(Theme.Text.caption)
                                    .foregroundStyle(Theme.inkSoft)
                                TextField("/opt/homebrew/bin/git", text: $preferences.gitExecutablePath)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }

                if preferences.advanced {
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            CardHeader(
                                title: "What counts",
                                info: "Exclusions and thresholds shared across open windows."
                            )
                            Toggle("Exclude test code from hotspots", isOn: $preferences.excludeTests)
                                .toggleStyle(.switch)
                            Toggle("Exclude vendored and generated code", isOn: $preferences.excludeGenerated)
                                .toggleStyle(.switch)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Also ignore paths containing")
                                    .font(Theme.Text.caption)
                                    .foregroundStyle(Theme.inkSoft)
                                TextField("CNIOLLHTTP, Generated", text: $preferences.ignoredPaths)
                                    .textFieldStyle(.roundedBorder)
                                Text("Comma separated. For vendored code that carries no generated marker.")
                                    .font(Theme.Text.caption)
                                    .foregroundStyle(Theme.inkMuted)
                            }
                            Stepper(
                                "Ignore functions with fewer than \(preferences.minimumCommits) commit\(preferences.minimumCommits == 1 ? "" : "s")",
                                value: $preferences.minimumCommits,
                                in: 1...25
                            )
                            Stepper(
                                "Pairs need at least \(preferences.minSharedCommits) shared commits",
                                value: $preferences.minSharedCommits,
                                in: 2...20
                            )
                        }
                        .font(Theme.Text.body)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        CardHeader(
                            title: "Cache",
                            info: "Incremental SQLite cache per repository storing parsed history and per-file syntax units."
                        )
                        HStack {
                            Text("Using \(cacheBytes.byteString) on disk")
                                .font(Theme.Text.body)
                                .foregroundStyle(Theme.inkSoft)
                            Spacer()
                            Button("Clear cache") {
                                AnalysisCache.clearAll()
                                cacheBytes = AnalysisCache.sizeOnDisk()
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
            .padding(Theme.Space.xl)
        }
        .frame(width: 560, height: 640)
        .background(Theme.page)
        .onAppear { cacheBytes = AnalysisCache.sizeOnDisk() }
    }

    private var halfLifeCaption: String {
        switch preferences.halfLifeDays {
        case ..<120:
            return "Short: most accurate attribution, but function-level churn is sparse enough that change frequency barely registers."
        case ..<550:
            return "Balanced: keeps most of the attribution accuracy while change frequency still separates functions. Measured sweet spot."
        default:
            return "Long: change frequency dominates, but older commits are attributed to lines that have since drifted, so accuracy drops."
        }
    }
}
