<div align="center">

# GitView

**Understand any repository. Faster.**

A native macOS app that reads a project's git history and tells you what changed,
who to ask about it, and which code is most likely to bite you.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?style=flat-square)
![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?style=flat-square)
![Universal](https://img.shields.io/badge/binary-universal-blue?style=flat-square)
![No network](https://img.shields.io/badge/telemetry-none-brightgreen?style=flat-square)
![MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)

![GitView's dashboard](docs/dashboard.png)

</div>

## What it is

Open a repository and GitView answers the questions you actually have about it.

**What happened while I was away?** It remembers when you last looked and shows you what
landed since — whose commits, which files, and which of them touched code you have worked
on yourself (matching both your configured git name and email).

**What have I got going on right now?** Uncommitted edits, untracked file previews, staged
changes, per-hunk staging/unstaging/discarding, unpushed commits, stashes, and interrupted
merges or rebases. Fetch remotes, fast-forward pull, switch or create branches, commit,
stash, and push directly from the app.

**Who do I ask about this file?** Ownership per file and per folder, with the knowledge
risk when only one person has ever touched something.

**What changed between these two versions?** Any two tags, branches or commits, with
release notes you can copy into a changelog and syntax-highlighted unified or side-by-side
diffs featuring inline word-level change emphasis and find-in-diff.

**Where is this project likely to break?** Functions ranked by how complicated they are
*and* how often they change — the combination, not either alone. Plus the functions that
keep being edited in the same commit as each other, which is where a change in one and a
forgotten change in the other turns into a bug.

It works on any git repository on your disk. Nothing is uploaded, there is no account, and
there is no telemetry; the only remote network calls happen when you explicitly ask to
fetch, pull, or push.

## Install

No release binary yet — build it from source. You need a Swift 6 toolchain (Xcode 16 or
newer; built and tested here on Swift 6.2).

```bash
git clone git@github.com:ShortPlanet3058/gitview.git
cd gitview
Scripts/make-app.sh --universal
cp -r build/GitView.app /Applications/
```

`--universal` builds for Apple Silicon and Intel; drop it to build only for this machine
and halve the build time. The first build compiles fifteen tree-sitter grammars and takes
a few minutes.

## Around the app

| | |
|---|---|
| **Overview** | Plain-language everyday summary (**Standard**) or full project telemetry, health checks, hotspots, and weekly sparklines (**Advanced**). |
| **Changes** | Split workspace pairing the file list & commit dock with a live side-by-side/unified diff viewer right in view — simple include/exclude checkboxes & one-click Sync in Standard, or full staged/unstaged/untracked sections, stashes, and hunk/line staging in Advanced. |
| **History / Commits** | Clean chronological history (**Standard**) or interactive swimlane branch topology, inline branch/tag badges, commit-to-commit comparison, and parent navigation (**Advanced**). |
| **Branches** | Switch or create local branches cleanly (**Standard**), or inspect remote-tracking branches, ahead/behind divergence, linked worktrees, and merged branch cleanup (**Advanced**). |
| **Releases** *(Advanced)* | Create, push, and delete tags, track unreleased commits, and compare any two refs or commits with inline word diffs. |
| **People / Contributors** | See everyone who contributes (**Standard**), plus ownership concentration insights and CSV export (**Advanced**). |
| **Files** | Interactive file tree, syntax-highlighted code viewer, and in Advanced mode line-by-line historical blame & function risk badges. |
| **Activity** *(Advanced)* | Commits over time and the files that change most. |
| **Hotspots** *(Advanced)* | Functions ranked by complexity and recent change frequency, with syntax-highlighted source excerpts. |
| **Change together** *(Advanced)* | Interactive coupling graph with directory cluster hulls, draggable/pinnable nodes, and shared-commit edge inspection. |
| **Statistics** *(Advanced)* | Transparent breakdown of health checks, risk weighting, and hunk attribution coverage. |

Use **Command Palette (`⌘K`)** to jump across screens, files, branches, or actions; press **`⌘F`** for contextual local find inside the active screen or diff and **`⌘⇧F`** for repository-wide search. **Standard mode** is built for everyday Git workflows without technical jargon, while **Advanced mode** (`⌘⇧D` or the sidebar toggle) unlocks Git staging power tools, historical blame, swimlane topology, and code telemetry. Open Settings (`⌘,`) to choose your experience mode, external editor (VS Code, Cursor, Zed, Sublime Text, Xcode), terminal app, and author identity.

## How it works

**Git is read by running git.** Every fact comes from `git` itself through `Process` —
`log`, `status`, `blame`, `rev-list`, `grep`, and a persistent `git cat-file --batch`
streamer for historical source snapshots — rather than a reimplementation of the object
format. If git says it, GitView says it.

**Code is parsed and highlighted with tree-sitter.** Fifteen languages get function-level
complexity analysis and CST syntax highlighting across diffs and source excerpts: C, C#,
C++, CSS, Go, Java, JavaScript, Kotlin, PHP, Python, Ruby, Rust, Swift, TypeScript and TSX.
Every other language is still counted, sized and attributed — it just is not ranked by
function.

**Risk is complexity × recent change.** A function's branch points multiplied by a
time-decayed count of the commits that touched it, with a 365-day half-life. Both sides are
log-damped so one enormous switch statement cannot dominate the ranking. The half-life is a
measured default, not a guess: at the 90 days originally planned, most functions had at most
two commits in the window and the ranking correlated with nothing.

**Analyses are persisted in a local SQLite WAL cache.** A repository is read once into
normalized SQLite tables with per-file `(bytes, mtime)` source unit entries; afterwards
only new commits are appended, and untouched files skip tree-sitter re-parsing entirely.
If history is rewritten, the cache resets automatically rather than silently trusting stale SHAs.

**It notices when the repository moves.** A watch on `.git` picks up a commit made in a
terminal, a pull, or a checkout, and brings the view up to date — unless you are reading a
diff or a file's history, in which case it offers rather than interrupts.

## Writing

GitView can fetch, pull (`--ff-only`), switch and create branches, delete merged branches,
stage, unstage, commit, stash, discard (by file or single hunk), and push. The rule it follows
is whether an operation can be taken back:

- **Reversible** things — stage, unstage, switch/create branch, fetch, ff-only pull, stash, commit — are plain buttons.
- **Destructive** things — discarding edits or a single hunk, deleting an untracked file, deleting a merged branch, dropping a stash —
  require a confirmation that says what will be lost, and offer to stash instead where that
  makes sense.
- **Push** shows you exactly what will go where before it does anything.

`push --force`, `reset --hard`, `branch -D`, and amending are deliberately absent. Each can destroy work
that exists nowhere else, and none is needed often enough to be worth having within reach
of a tired hand. A half-finished merge or rebase is reported, not driven — finish those in a
terminal.

## Development

```bash
swift build            # build
swift test             # run the test suite
Scripts/make-app.sh    # assemble GitView.app
Scripts/make-icon.swift # regenerate the app icon
```

The package splits cleanly into targets: `GitViewCore` (models, risk analysis, and SQLite WAL cache, no UI),
`GitViewGit` (git CLI wrapper, `cat-file --batch` reader, incremental log/diff parsing), `GitViewParse`
(tree-sitter unit extraction & syntax highlighting), `GitViewUI` (`@Observable` domain stores and SwiftUI views),
plus thin `GitView` app and `gitview-cli` executables. Tests cover parsers, tree-sitter extractors, highlighting,
SQLite caching, UI stores, and real temporary git repositories.

Screens can be rendered offscreen for review without taking over your display:

```bash
build/GitView.app/Contents/MacOS/GitView --repo <path> --screen overview \
  --mode standard --screenshot out.png --screenshot-delay 15 --quit
```

## Known limits

- **macOS only**, and macOS 14 (Sonoma) or newer.
- **Line ranges come from today's checkout** while a commit's hunks refer to the file as it
  was then, so old commits can be attributed to the wrong function. The Statistics tab
  measures this rather than hiding it: roughly 88–100% correct for commits under two years
  old, falling to about 42% beyond five years.
- **The health score is a heuristic** meant to start a conversation, not a verdict. Every
  check shows the number behind it.
- **Merge commits are not counted** by default, deliberately: counting them double-counts
  every change that arrived through one.

## Licence

MIT — see [LICENSE](LICENSE).
