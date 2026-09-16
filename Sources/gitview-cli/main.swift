import Foundation
import GitViewCore
import GitViewGit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("gitview: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("""
    usage: gitview-cli scan <repo-path>

      scan   parse a repository's history and report summary statistics
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

default:
    fail("unknown command '\(command)'")
}
