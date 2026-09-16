import Foundation
import GitViewCore

/// Walks a checkout and extracts every code unit, parsing files in parallel.
public struct SourceScanner: Sendable {
    public struct Report: Sendable {
        public var units: [CodeUnit]
        public var filesParsed: Int
        public var filesFailed: [String]
        /// Paths recognised as vendored or machine-generated. Their units are still
        /// extracted — the caller decides whether to rank them.
        public var generatedFiles: Set<String> = []

        public init(units: [CodeUnit], filesParsed: Int, filesFailed: [String],
                    generatedFiles: Set<String> = []) {
            self.units = units; self.filesParsed = filesParsed
            self.filesFailed = filesFailed; self.generatedFiles = generatedFiles
        }
    }

    /// Directories that never contain source worth analysing, and would otherwise
    /// swamp the results with vendored code.
    static let skippedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "Pods", "Carthage",
        "node_modules", ".index-build", "checkouts",
    ]

    public init() {}

    /// Files the registry has a grammar for, so the scan skips what it cannot parse.
    public func parsableFiles(in root: URL) -> [URL] {
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
            if LanguageRegistry.shared.language(forExtension: url.pathExtension) != nil { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Parses every Swift file under `root`, returning paths relative to it so they
    /// line up with the paths git reports.
    /// - Parameter detectGenerated: read the head of each file to spot generated markers.
    /// - Parameter onProgress: called as each file's result arrives, with (parsed, total).
    ///   Called from the collecting task, so it must be cheap and must not assume an actor.
    public func scan(root: URL, detectGenerated: Bool = true,
                     onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Report {
        let files = parsableFiles(in: root)
        onProgress?(0, files.count)
        // Compile each language's grammar and query once, not once per file.
        let present = Set(files.map { $0.pathExtension.lowercased() })
        var built: [String: UnitExtractor] = [:]
        for support in LanguageRegistry.shared.languages where !support.extensions.isDisjoint(with: present) {
            for ext in support.extensions where present.contains(ext) {
                built[ext] = try UnitExtractor(support: support)
            }
        }
        let extractors = built
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        return try await withThrowingTaskGroup(
            of: (units: [CodeUnit], failure: String?, generated: String?).self
        ) { group in
            for file in files {
                group.addTask {
                    let relative = file.standardizedFileURL.path.hasPrefix(prefix)
                        ? String(file.standardizedFileURL.path.dropFirst(prefix.count))
                        : file.path
                    do {
                        // A file that is not valid UTF-8, or that the grammar chokes on,
                        // must not take the whole scan down with it.
                        guard let extractor = extractors[file.pathExtension.lowercased()] else {
                            return ([], nil, nil)
                        }
                        let source = try String(contentsOf: file, encoding: .utf8)
                        let units = try extractor.extract(source: source, filePath: relative)
                        let generated = PathClassifier.isVendored(path: relative)
                            || (detectGenerated && PathClassifier.looksGenerated(header: source))
                            // A file holding a function no human would write by hand.
                            || units.contains { $0.complexity >= PathClassifier.implausibleComplexity }
                        return (units, nil, generated ? relative : nil)
                    } catch {
                        return ([], relative, nil)
                    }
                }
            }

            var report = Report(units: [], filesParsed: 0, filesFailed: [])
            var settled = 0
            for try await result in group {
                settled += 1
                onProgress?(settled, files.count)
                if let failure = result.failure {
                    report.filesFailed.append(failure)
                } else {
                    report.filesParsed += 1
                    report.units.append(contentsOf: result.units)
                    if let generated = result.generated { report.generatedFiles.insert(generated) }
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
