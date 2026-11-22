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
    /// swamp the results with vendored or build code when scanning without a tracked list.
    static let skippedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "Pods", "Carthage",
        "node_modules", ".index-build", "checkouts",
        "venv", ".venv", "env", "target", "vendor", "dist", "build", "out",
        "zig-cache", "__pycache__", "coverage",
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

    /// Parses every supported source file under `root`, returning paths relative to it so
    /// they line up with the paths git reports.
    /// - Parameter trackedPaths: when provided (from `git ls-files`), parses only tracked
    ///   files rather than walking the filesystem.
    /// - Parameter detectGenerated: read the head of each file to spot generated markers.
    /// - Parameter onProgress: called throttled as results land, with (parsed, total).
    public func scan(root: URL, trackedPaths: [String]? = nil, detectGenerated: Bool = true,
                     onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Report {
        let entries: [(url: URL, relative: String, ext: String)]
        if let trackedPaths {
            let fileManager = FileManager.default
            var resolved: [(url: URL, relative: String, ext: String)] = []
            resolved.reserveCapacity(trackedPaths.count)
            for path in trackedPaths {
                let ext = (path as NSString).pathExtension.lowercased()
                guard LanguageRegistry.shared.language(forExtension: ext) != nil else { continue }
                let url = root.appendingPathComponent(path)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                resolved.append((url, path, ext))
            }
            entries = resolved.sorted { $0.relative < $1.relative }
        } else {
            let files = parsableFiles(in: root)
            let rootPath = root.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            entries = files.map { file in
                let relative = file.standardizedFileURL.path.hasPrefix(prefix)
                    ? String(file.standardizedFileURL.path.dropFirst(prefix.count))
                    : file.path
                return (file, relative, file.pathExtension.lowercased())
            }
        }

        onProgress?(0, entries.count)
        // Compile each language's grammar and query once, not once per file.
        let present = Set(entries.map(\.ext))
        var built: [String: UnitExtractor] = [:]
        for support in LanguageRegistry.shared.languages where !support.extensions.isDisjoint(with: present) {
            for ext in support.extensions where present.contains(ext) {
                built[ext] = try UnitExtractor(support: support)
            }
        }
        let extractors = built
        let maxConcurrency = min(max(ProcessInfo.processInfo.activeProcessorCount, 4), 12)
        let progressStep = max(1, entries.count / 100)

        return try await withThrowingTaskGroup(
            of: (units: [CodeUnit], failure: String?, generated: String?).self
        ) { group in
            var next = 0
            func enqueue() {
                guard next < entries.count else { return }
                let entry = entries[next]
                next += 1
                group.addTask {
                    do {
                        // A file that is not valid UTF-8, or that the grammar chokes on,
                        // must not take the whole scan down with it.
                        guard let extractor = extractors[entry.ext] else {
                            return ([], nil, nil)
                        }
                        let source = try String(contentsOf: entry.url, encoding: .utf8)
                        let units = try extractor.extract(source: source, filePath: entry.relative)
                        let generated = PathClassifier.isVendored(path: entry.relative)
                            || (detectGenerated && PathClassifier.looksGenerated(header: source))
                            // A file holding a function no human would write by hand.
                            || units.contains { $0.complexity >= PathClassifier.implausibleComplexity }
                        return (units, nil, generated ? entry.relative : nil)
                    } catch {
                        return ([], entry.relative, nil)
                    }
                }
            }

            for _ in 0..<min(maxConcurrency, entries.count) { enqueue() }

            var report = Report(units: [], filesParsed: 0, filesFailed: [])
            var settled = 0
            for try await result in group {
                settled += 1
                if settled == entries.count || settled % progressStep == 0 {
                    onProgress?(settled, entries.count)
                }
                if let failure = result.failure {
                    report.filesFailed.append(failure)
                } else {
                    report.filesParsed += 1
                    report.units.append(contentsOf: result.units)
                    if let generated = result.generated { report.generatedFiles.insert(generated) }
                }
                enqueue()
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
