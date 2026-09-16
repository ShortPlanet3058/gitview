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

case "sexp":
    // Development aid: dump the parse tree so query patterns can be checked against
    // what the grammar actually produces rather than what it is assumed to produce.
    guard arguments.count >= 2 else { fail("sexp requires a file path") }
    let source = try String(contentsOfFile: arguments[1], encoding: .utf8)
    print(SwiftLanguage.sExpression(of: source) ?? "<parse failed>")

default:
    fail("unknown command '\(command)'")
}
