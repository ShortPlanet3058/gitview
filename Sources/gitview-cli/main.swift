import Foundation
import GitViewCore
import GitViewGit
import GitViewParse

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("gitview: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("""
    usage: gitview-cli scan <repo-path>

      scan    parse a repository's history and report summary statistics
      units   extract every code unit from a checkout and print its metrics
      churn   join units against history and report which change most often
      risk    rank units by risk (complexity x recency-weighted churn)
      history <repo> <name>   complexity of one unit at every revision that touched it
      coupling <repo>         pairs of units that change together, cross-directory first
      facts <repo>            branches, contributors, size, README summary and health

    coupling options:
      --limit <n>  --min-shared <n> (default 3)  --scope <all|file|directory> (default directory)
      --max-units <n> (default 50)  --half-life <days>  --include-tests
      coupling <repo>         pairs of units that change together, cross-directory first
      facts <repo>            branches, contributors, size, README summary and health

    coupling options:
      --limit <n>  --min-shared <n> (default 3)  --scope <all|file|directory> (default directory)
      --max-units <n> (default 50)  --half-life <days>  --include-tests

    risk options:
      --limit <n>          rows to print (default 20)
      --half-life <days>   decay half-life (default 90)
      --exclude <substr>   drop units whose path contains this (repeatable)
      --include-tests      keep test code (excluded by default)
      --compare            also show the ranking by raw commit count

    units options:
      --file <substring>   only files whose path contains this
      --sort <line|complexity>
      --limit <n>
    """)
    exit(2)
}

switch command {
case "scan":
    guard arguments.count >= 2 else { fail("scan requires a repository path") }
    let path = (arguments[1] as NSString).expandingTildeInPath
    let repo = GitRepository(url: URL(fileURLWithPath: path))

    let root: URL
    do {
        root = try repo.validate()
    } catch {
        fail("\(error)")
    }

    let started = DispatchTime.now()
    let commits: [Commit]
    do {
        commits = try GitRepository(url: root).loadHistory()
    } catch {
        fail("\(error)")
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9

    guard !commits.isEmpty else { fail("no commits found in \(root.path)") }

    var authors = Set<String>()
    var totalHunks = 0
    var totalFileChanges = 0
    var renames = 0
    var earliest = Date.distantFuture
    var latest = Date.distantPast
    var commitsWithChanges = 0

    for commit in commits {
        authors.insert(commit.author)
        if commit.date < earliest { earliest = commit.date }
        if commit.date > latest { latest = commit.date }
        if !commit.fileChanges.isEmpty { commitsWithChanges += 1 }
        totalFileChanges += commit.fileChanges.count
        for change in commit.fileChanges {
            totalHunks += change.hunks.count
            if change.oldPath != nil { renames += 1 }
        }
    }

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    dateFormatter.timeZone = TimeZone(identifier: "UTC")

    func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    print("repository        \(root.path)")
    print("commits           \(number(commits.count))  (\(number(commits.count - commitsWithChanges)) with no diff, i.e. merges/empty)")
    print("authors           \(number(authors.count))")
    print("date range        \(dateFormatter.string(from: earliest)) .. \(dateFormatter.string(from: latest))")
    print("file changes      \(number(totalFileChanges))  (\(number(renames)) renames)")
    print("hunks             \(number(totalHunks))")
    print(String(format: "elapsed           %.2fs  (%@ commits/s)", elapsed, number(Int(Double(commits.count) / max(elapsed, 0.0001)))))

case "units":
    guard arguments.count >= 2 else { fail("units requires a directory path") }
    let path = (arguments[1] as NSString).expandingTildeInPath
    let root = URL(fileURLWithPath: path)

    var fileFilter: String?
    var sortKey = "line"
    var limit = Int.max
    var index = 2
    while index < arguments.count {
        switch arguments[index] {
        case "--file":  index += 1; fileFilter = index < arguments.count ? arguments[index] : nil
        case "--sort":  index += 1; sortKey = index < arguments.count ? arguments[index] : "line"
        case "--limit": index += 1; limit = index < arguments.count ? (Int(arguments[index]) ?? .max) : .max
        default: fail("unknown option '\(arguments[index])'")
        }
        index += 1
    }

    let scanner = SourceScanner()
    let started = DispatchTime.now()
    let report: SourceScanner.Report
    do {
        report = try await scanner.scan(root: root)
    } catch {
        fail("\(error)")
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9

    var units = report.units
    if let fileFilter { units = units.filter { $0.filePath.contains(fileFilter) } }
    if sortKey == "complexity" { units.sort { $0.complexity > $1.complexity } }

    func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
    }

    print(pad("lines", 12) + pad("cx", 5) + pad("nest", 6) + pad("kind", 9) + "name")
    print(String(repeating: "-", count: 100))
    for unit in units.prefix(limit) {
        let range = "\(unit.lineRange.lowerBound)-\(unit.lineRange.upperBound)"
        print(pad(range, 12)
              + pad("\(unit.complexity)", 5)
              + pad("\(unit.nestingDepth)", 6)
              + pad(unit.kind.rawValue, 9)
              + "\(unit.filePath):\(unit.name)")
    }
    print(String(repeating: "-", count: 100))
    print("\(report.units.count) units in \(report.filesParsed) files "
          + "(\(min(units.count, limit)) shown), \(report.filesFailed.count) files failed, "
          + String(format: "%.2fs", elapsed))
    if !report.filesFailed.isEmpty {
        print("failed: " + report.filesFailed.prefix(5).joined(separator: ", "))
    }

case "churn":
    guard arguments.count >= 2 else { fail("churn requires a repository path") }
    let path = (arguments[1] as NSString).expandingTildeInPath
    var limit = 20
    var tsv = false
    var index = 2
    while index < arguments.count {
        if arguments[index] == "--limit", index + 1 < arguments.count {
            limit = Int(arguments[index + 1]) ?? 20
            index += 1
        } else if arguments[index] == "--tsv" {
            tsv = true
        }
        index += 1
    }

    let repo = GitRepository(url: URL(fileURLWithPath: path))
    let root: URL
    do { root = try repo.validate() } catch { fail("\(error)") }

    let t0 = DispatchTime.now()
    let commits: [Commit]
    do { commits = try GitRepository(url: root).loadHistory() } catch { fail("\(error)") }
    let tHistory = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9

    let t1 = DispatchTime.now()
    let report: SourceScanner.Report
    do { report = try await SourceScanner().scan(root: root) } catch { fail("\(error)") }
    let tParse = Double(DispatchTime.now().uptimeNanoseconds - t1.uptimeNanoseconds) / 1e9

    let t2 = DispatchTime.now()
    let churn = ChurnJoiner.join(units: report.units, commits: commits)
    let tJoin = Double(DispatchTime.now().uptimeNanoseconds - t2.uptimeNanoseconds) / 1e9

    func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
    }
    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "yyyy-MM-dd"

    let ranked = report.units
        .filter { $0.kind != .class }
        .sorted { churn.commitCount(for: $0) > churn.commitCount(for: $1) }

    if tsv {
        // Machine-readable, for cross-checking attribution against `git log -L`.
        print("commits\tauthors\tcx\tstart\tend\tpath\tname\tdates")
        for unit in ranked.prefix(limit) {
            let dates = churn.commits(for: unit)
                .map { "\($0.sha):\(Int($0.date.timeIntervalSince1970))" }
                .joined(separator: ",")
            print("\(churn.commitCount(for: unit))\t\(churn.authors(for: unit).count)\t\(unit.complexity)"
                  + "\t\(unit.lineRange.lowerBound)\t\(unit.lineRange.upperBound)"
                  + "\t\(unit.filePath)\t\(unit.name)\t\(dates)")
        }
        exit(0)
    }

    print(pad("commits", 9) + pad("authors", 9) + pad("cx", 5) + pad("last", 12) + "unit")
    print(String(repeating: "-", count: 110))
    for unit in ranked.prefix(limit) {
        let last = churn.lastTouched(for: unit).map { dayFormatter.string(from: $0) } ?? "-"
        print(pad("\(churn.commitCount(for: unit))", 9)
              + pad("\(churn.authors(for: unit).count)", 9)
              + pad("\(unit.complexity)", 5)
              + pad(last, 12)
              + "\(unit.filePath):\(unit.name)")
    }
    print(String(repeating: "-", count: 110))

    let touched = report.units.filter { churn.commitCount(for: $0) > 0 }.count
    let totalHunks = churn.matchedHunks + churn.unmatchedHunks
    let matchRate = totalHunks > 0 ? Double(churn.matchedHunks) / Double(totalHunks) * 100 : 0
    print("units             \(report.units.count) (\(touched) with history, "
          + String(format: "%.0f%%", Double(touched) / Double(max(report.units.count, 1)) * 100) + ")")
    print("hunks in .swift   \(totalHunks) (" + String(format: "%.1f%%", matchRate) + " landed inside a unit)")
    print("hunks elsewhere   \(churn.unresolvedPaths) (non-Swift files, or deleted since)")
    print(String(format: "timing            history %.2fs  parse %.2fs  join %.2fs", tHistory, tParse, tJoin))

case "risk":
    guard arguments.count >= 2 else { fail("risk requires a repository path") }
    let path = (arguments[1] as NSString).expandingTildeInPath
    var limit = 20
    var halfLifeDays = 90.0
    var excludes: [String] = []
    var includeTests = false
    var compare = false
    var index = 2
    while index < arguments.count {
        switch arguments[index] {
        case "--limit":     index += 1; limit = Int(arguments[index]) ?? 20
        case "--half-life": index += 1; halfLifeDays = Double(arguments[index]) ?? 90
        case "--exclude":   index += 1; excludes.append(arguments[index])
        case "--include-tests": includeTests = true
        case "--compare":   compare = true
        default: fail("unknown option '\(arguments[index])'")
        }
        index += 1
    }

    let repo = GitRepository(url: URL(fileURLWithPath: path))
    let root: URL
    do { root = try repo.validate() } catch { fail("\(error)") }

    let commits: [Commit]
    do { commits = try GitRepository(url: root).loadHistory() } catch { fail("\(error)") }
    let report: SourceScanner.Report
    do { report = try await SourceScanner().scan(root: root) } catch { fail("\(error)") }

    var units = report.units
    if !includeTests { units = units.filter { !PathClassifier.isTest(path: $0.filePath) } }
    for pattern in excludes { units = units.filter { !$0.filePath.contains(pattern) } }
    let churn = ChurnJoiner.join(units: units, commits: commits)

    let now = Date()
    let model = RiskModel(halfLife: halfLifeDays * 86_400)
    let ranked = model.rank(units: units, churn: churn, now: now)

    func pad(_ v: String, _ w: Int) -> String {
        v.count >= w ? v : v + String(repeating: " ", count: w - v.count)
    }
    func lead(_ v: String, _ w: Int) -> String {
        v.count >= w ? v : String(repeating: " ", count: w - v.count) + v
    }
    let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"

    let newest = commits.map(\.date).max() ?? now
    print("repository   \(root.lastPathComponent)   half-life \(Int(halfLifeDays))d"
          + "   newest commit \(day.string(from: newest))")
    if now.timeIntervalSince(newest) > 180 * 86_400 {
        print("WARNING: newest commit is over 6 months old; every score is decayed against"
              + " wall-clock now, so the whole table is compressed.")
    }
    print()
    print(lead("#", 4) + lead("score", 8) + lead("cx", 5) + lead("recency", 9)
          + lead("commits", 9) + lead("authors", 9) + "  " + pad("last", 12) + "unit")
    print(String(repeating: "-", count: 128))
    for (position, item) in ranked.prefix(limit).enumerated() {
        print(lead("\(position + 1)", 4)
              + lead(String(format: "%.2f", item.score), 8)
              + lead("\(item.unit.complexity)", 5)
              + lead(String(format: "%.2f", item.recency), 9)
              + lead("\(item.commitCount)", 9)
              + lead("\(item.authorCount)", 9) + "  "
              + pad(item.lastTouched.map { day.string(from: $0) } ?? "-", 12)
              + "\(item.unit.filePath):\(item.unit.name)")
    }
    print(String(repeating: "-", count: 128))
    print("\(ranked.count) units with history, of \(units.count) parsed")

    if compare {
        print()
        print("For comparison — ranked by RAW commit count (the metric the -L validation")
        print("showed is only ~47% accurate all-time):")
        print(String(repeating: "-", count: 128))
        let byRaw = ranked.sorted { $0.commitCount > $1.commitCount }
        for (position, item) in byRaw.prefix(limit).enumerated() {
            print(lead("\(position + 1)", 4) + lead("\(item.commitCount)", 9)
                  + lead("cx \(item.unit.complexity)", 8) + "  "
                  + pad(item.lastTouched.map { day.string(from: $0) } ?? "-", 12)
                  + "\(item.unit.filePath):\(item.unit.name)")
        }
    }

case "history":
    guard arguments.count >= 3 else { fail("history requires a repository path and a unit name") }
    let path = (arguments[1] as NSString).expandingTildeInPath
    let wanted = arguments[2]

    let repo = GitRepository(url: URL(fileURLWithPath: path))
    let root: URL
    do { root = try repo.validate() } catch { fail("\(error)") }
    let commits: [Commit]
    do { commits = try GitRepository(url: root).loadHistory() } catch { fail("\(error)") }
    let report: SourceScanner.Report
    do { report = try await SourceScanner().scan(root: root) } catch { fail("\(error)") }

    let units = report.units.filter { $0.kind != .class && !PathClassifier.isTest(path: $0.filePath) }
    guard let unit = units.first(where: { $0.name == wanted })
            ?? units.first(where: { $0.name.hasSuffix("." + wanted) })
            ?? units.first(where: { $0.name.contains(wanted) }) else {
        fail("no unit matching '\(wanted)'")
    }
    let churn = ChurnJoiner.join(units: units, commits: commits)

    let service = UnitHistoryService { sha, filePath in
        try GitProcess.capture(arguments: ["show", "\(sha):\(filePath)"], in: root)
    }
    let started = DispatchTime.now()
    let points = await service.complexityHistory(for: unit, churn: churn)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9

    func pad(_ v: String, _ w: Int) -> String {
        v.count >= w ? v : v + String(repeating: " ", count: w - v.count)
    }
    let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
    print("\(unit.name)   \(unit.filePath):\(unit.lineRange.lowerBound)-\(unit.lineRange.upperBound)")
    print()
    print(pad("date", 12) + pad("sha", 9) + pad("cx", 5) + pad("lines", 7) + "subject")
    print(String(repeating: "-", count: 100))
    for point in points {
        let cx = point.complexity.map(String.init) ?? "—"
        let lines = point.lineCount.map(String.init) ?? "—"
        print(pad(day.string(from: point.date), 12) + pad(String(point.sha.prefix(7)), 9)
              + pad(cx, 5) + pad(lines, 7) + point.subject)
    }
    print(String(repeating: "-", count: 100))
    let missing = points.filter { $0.complexity == nil }.count
    print("\(points.count - 1) revisions (\(missing) where the unit was not found — likely drift), "
          + String(format: "%.2fs", elapsed))

case "coupling":
    guard arguments.count >= 2 else { fail("coupling requires a repository path") }
    let path = (arguments[1] as NSString).expandingTildeInPath
    var limit = 25, minShared = 3, maxUnits = 50, halfLifeDays = 365.0
    var scope = "directory", includeTests = false
    var index = 2
    while index < arguments.count {
        switch arguments[index] {
        case "--limit":      index += 1; limit = Int(arguments[index]) ?? 25
        case "--min-shared": index += 1; minShared = Int(arguments[index]) ?? 3
        case "--max-units":  index += 1; maxUnits = Int(arguments[index]) ?? 50
        case "--half-life":  index += 1; halfLifeDays = Double(arguments[index]) ?? 365
        case "--scope":      index += 1; scope = arguments[index]
        case "--include-tests": includeTests = true
        default: fail("unknown option '\(arguments[index])'")
        }
        index += 1
    }

    let repo = GitRepository(url: URL(fileURLWithPath: path))
    let root: URL
    do { root = try repo.validate() } catch { fail("\(error)") }
    let commits: [Commit]
    do { commits = try GitRepository(url: root).loadHistory() } catch { fail("\(error)") }
    let report: SourceScanner.Report
    do { report = try await SourceScanner().scan(root: root) } catch { fail("\(error)") }

    var units = report.units
    if !includeTests { units = units.filter { !PathClassifier.isTest(path: $0.filePath) } }
    let churn = ChurnJoiner.join(units: units, commits: commits)
    let byID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })

    let started = DispatchTime.now()
    let analyzer = CouplingAnalyzer(maxUnitsPerCommit: maxUnits, minSharedCommits: minShared,
                                    halfLife: halfLifeDays * 86_400)
    let coupling = analyzer.analyze(units: units, churn: churn, now: Date())
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9

    let shown = coupling.pairs.filter {
        switch scope {
        case "all": return true
        case "file": return $0.crossFile
        default: return $0.crossDirectory
        }
    }

    func lead(_ v: String, _ w: Int) -> String {
        v.count >= w ? v : String(repeating: " ", count: w - v.count) + v
    }
    let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
    print("scope \(scope)   min shared \(minShared)   max units/commit \(maxUnits)   half-life \(Int(halfLifeDays))d")
    print()
    print(lead("#", 4) + lead("shared", 8) + lead("strength", 10) + lead("weight", 8) + "  " + "last        pair")
    print(String(repeating: "-", count: 120))
    for (position, pair) in shown.prefix(limit).enumerated() {
        guard let a = byID[pair.a], let b = byID[pair.b] else { continue }
        print(lead("\(position + 1)", 4) + lead("\(pair.sharedCommits)", 8)
              + lead(String(format: "%.0f%%", pair.strength * 100), 10)
              + lead(String(format: "%.2f", pair.weight), 8) + "  "
              + day.string(from: pair.lastShared) + "  "
              + "\(a.filePath):\(a.name)")
        print(String(repeating: " ", count: 44) + "\(b.filePath):\(b.name)")
    }
    print(String(repeating: "-", count: 120))
    print("\(coupling.pairs.count) pairs with >= \(minShared) shared commits (\(shown.count) in scope); "
          + "\(coupling.pairingCommits) commits produced pairs, \(coupling.skippedCommits) skipped as sweeps; "
          + String(format: "%.3fs", elapsed))

case "coupling":
    guard arguments.count >= 2 else { fail("coupling requires a repository path") }
    let path = (arguments[1] as NSString).expandingTildeInPath
    var limit = 25, minShared = 3, maxUnits = 50, halfLifeDays = 365.0
    var scope = "directory", includeTests = false
    var index = 2
    while index < arguments.count {
        switch arguments[index] {
        case "--limit":      index += 1; limit = Int(arguments[index]) ?? 25
        case "--min-shared": index += 1; minShared = Int(arguments[index]) ?? 3
        case "--max-units":  index += 1; maxUnits = Int(arguments[index]) ?? 50
        case "--half-life":  index += 1; halfLifeDays = Double(arguments[index]) ?? 365
        case "--scope":      index += 1; scope = arguments[index]
        case "--include-tests": includeTests = true
        default: fail("unknown option '\(arguments[index])'")
        }
        index += 1
    }

    let repo = GitRepository(url: URL(fileURLWithPath: path))
    let root: URL
    do { root = try repo.validate() } catch { fail("\(error)") }
    let commits: [Commit]
    do { commits = try GitRepository(url: root).loadHistory() } catch { fail("\(error)") }
    let report: SourceScanner.Report
    do { report = try await SourceScanner().scan(root: root) } catch { fail("\(error)") }

    var units = report.units
    if !includeTests { units = units.filter { !PathClassifier.isTest(path: $0.filePath) } }
    let churn = ChurnJoiner.join(units: units, commits: commits)
    let byID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })

    let started = DispatchTime.now()
    let analyzer = CouplingAnalyzer(maxUnitsPerCommit: maxUnits, minSharedCommits: minShared,
                                    halfLife: halfLifeDays * 86_400)
    let coupling = analyzer.analyze(units: units, churn: churn, now: Date())
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9

    let shown = coupling.pairs.filter {
        switch scope {
        case "all": return true
        case "file": return $0.crossFile
        default: return $0.crossDirectory
        }
    }

    func lead(_ v: String, _ w: Int) -> String {
        v.count >= w ? v : String(repeating: " ", count: w - v.count) + v
    }
    let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
    print("scope \(scope)   min shared \(minShared)   max units/commit \(maxUnits)   half-life \(Int(halfLifeDays))d")
    print()
    print(lead("#", 4) + lead("shared", 8) + lead("strength", 10) + lead("weight", 8) + "  last        pair")
    print(String(repeating: "-", count: 120))
    for (position, pair) in shown.prefix(limit).enumerated() {
        guard let a = byID[pair.a], let b = byID[pair.b] else { continue }
        print(lead("\(position + 1)", 4) + lead("\(pair.sharedCommits)", 8)
              + lead(String(format: "%.0f%%", pair.strength * 100), 10)
              + lead(String(format: "%.2f", pair.weight), 8) + "  "
              + day.string(from: pair.lastShared) + "  \(a.filePath):\(a.name)")
        print(String(repeating: " ", count: 44) + "\(b.filePath):\(b.name)")
    }
    print(String(repeating: "-", count: 120))
    print("\(coupling.pairs.count) pairs with >= \(minShared) shared commits (\(shown.count) in scope); "
          + "\(coupling.pairingCommits) commits produced pairs, \(coupling.skippedCommits) skipped as sweeps; "
          + String(format: "%.3fs", elapsed))

case "facts":
    guard arguments.count >= 2 else { fail("facts requires a repository path") }
    let path = (arguments[1] as NSString).expandingTildeInPath
    let repo = GitRepository(url: URL(fileURLWithPath: path))
    let t0 = DispatchTime.now()
    let info: RepositoryInfo
    do { info = try repo.info() } catch { fail("\(error)") }
    let branches: [BranchInfo]
    do { branches = try repo.branches(defaultBranch: info.defaultBranch, currentBranch: info.currentBranch) } catch { fail("\(error)") }
    let tFacts = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
    let commits: [Commit]
    do { commits = try GitRepository(url: info.root).loadHistory() } catch { fail("\(error)") }

    func mb(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
    let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
    print("root            \(info.root.path)")
    print("branch          \(info.currentBranch) (default \(info.defaultBranch))")
    print("remote          \(info.remoteURL ?? "—")  ->  \(info.remoteWebURL?.absoluteString ?? "—")")
    print("git objects     \(info.packedBytes.map(mb) ?? "—")")
    print("tracked files   \(info.inventory.fileCount) · \(mb(info.inventory.totalBytes))")
    for category in FileInventory.categories {
        print("  \(category.padding(toLength: 13, withPad: " ", startingAt: 0)) \(mb(info.inventory.bytesByCategory[category] ?? 0))")
    }
    print("large files     \(info.inventory.largeFiles.count)" + (info.inventory.largeFiles.first.map { "  (largest \($0.path) \(mb($0.bytes)))" } ?? ""))
    print("readme          \(info.readmeSummary ?? "—")")
    print()
    print("branches (\(branches.count)):")
    for b in branches.prefix(8) {
        let flags = [b.isDefault ? "default" : nil, b.isCurrent ? "current" : nil, b.isRemote ? "remote" : nil, b.isMerged ? "merged" : nil].compactMap { $0 }.joined(separator: ",")
        let ab = (b.ahead != nil && b.behind != nil) ? "+\(b.ahead!)/-\(b.behind!)" : ""
        print("  \(day.string(from: b.date))  \(b.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(ab.padding(toLength: 10, withPad: " ", startingAt: 0)) \(flags)")
    }
    print()
    let contributors = ContributorStats.compute(commits: commits)
    print("contributors (\(contributors.count)):")
    for c in contributors.prefix(5) {
        print("  \(c.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(c.commits) commits  \(Int((c.share * 100).rounded()))%  \(day.string(from: c.firstCommit)) – \(day.string(from: c.lastCommit))")
    }
    let now = Date()
    let series = ActivitySeries.buckets(commits: commits, granularity: .month, from: now.addingTimeInterval(-365 * 86_400), to: now)
    print("commits/month (last 12): " + series.map { String($0.commits) }.joined(separator: " "))
    let top = ChangeFrequency.topFiles(commits: commits, since: now.addingTimeInterval(-90 * 86_400), limit: 5)
    print("top changed files (90d): " + top.map { "\($0.path.split(separator: "/").last ?? "") ×\($0.changes)" }.joined(separator: ", "))
    print()
    let stale = branches.filter { !$0.isDefault && !$0.isMerged && now.timeIntervalSince($0.date) > 90 * 86_400 }.count
    let health = RepositoryHealth.assess(.init(
        lastCommit: commits.first?.date, activeAuthors: ContributorStats.activeAuthors(commits: commits, since: now.addingTimeInterval(-90 * 86_400)),
        staleBranches: stale, totalBranches: branches.count, largeFiles: info.inventory.largeFiles.count,
        complexChangedShare: nil, complexChangedCount: 0, now: now))
    print("health          \(health.score) \(health.label) — \(health.summary)")
    for item in health.items { print("  [\(item.points)/\(item.maxPoints)] \(item.title): \(item.detail)") }
    print(String(format: "facts %.2fs", tFacts))

case "sexp":
    // Development aid: dump the parse tree so query patterns can be checked against
    // what the grammar actually produces rather than what it is assumed to produce.
    guard arguments.count >= 2 else { fail("sexp requires a file path") }
    let source = try String(contentsOfFile: arguments[1], encoding: .utf8)
    print(SwiftLanguage.sExpression(of: source) ?? "<parse failed>")

default:
    fail("unknown command '\(command)'")
}
