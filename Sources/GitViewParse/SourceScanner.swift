import Foundation
import GitViewCore

/// Walks a checkout and extracts every code unit, parsing files in parallel.
public struct SourceScanner: Sendable {
    public struct Report: Sendable {
        public var units: [CodeUnit]
        public var filesParsed: Int
        public var filesFailed: [String]
    }

    /// Directories that never contain source worth analysing, and would otherwise
    /// swamp the results with vendored code.
    static let skippedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "Pods", "Carthage",
        "node_modules", ".index-build", "checkouts",
    ]

    public init() {}

    public func swiftFiles(in root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if Self.skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if url.pathExtension == "swift" { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Parses every Swift file under `root`, returning paths relative to it so they
    /// line up with the paths git reports.
    public func scan(root: URL) async throws -> Report {
        let files = swiftFiles(in: root)
        // Compile the query once rather than once per file.
        let extractor = try SwiftUnitExtractor()
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        return try await withThrowingTaskGroup(of: (units: [CodeUnit], failure: String?).self) { group in
            for file in files {
                group.addTask {
                    let relative = file.standardizedFileURL.path.hasPrefix(prefix)
                        ? String(file.standardizedFileURL.path.dropFirst(prefix.count))
                        : file.path
                    do {
                        // A file that is not valid UTF-8, or that the grammar chokes on,
                        // must not take the whole scan down with it.
                        let source = try String(contentsOf: file, encoding: .utf8)
                        return (try extractor.extract(source: source, filePath: relative), nil)
                    } catch {
                        return ([], relative)
                    }
                }
            }

            var report = Report(units: [], filesParsed: 0, filesFailed: [])
            for try await result in group {
                if let failure = result.failure {
                    report.filesFailed.append(failure)
                } else {
                    report.filesParsed += 1
                    report.units.append(contentsOf: result.units)
                }
            }
            report.units.sort {
                $0.filePath == $1.filePath
                    ? $0.lineRange.lowerBound < $1.lineRange.lowerBound
                    : $0.filePath < $1.filePath
            }
            return report
        }
    }
}
