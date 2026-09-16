import Foundation
import CryptoKit

/// On-disk cache of the two expensive results: parsed history and parsed units.
///
/// Reading history dominates: the tree-sitter repository takes about 90 seconds, almost
/// all of it in `git log -p`, because its history carries large generated files. Parsing
/// the working tree is comparatively cheap. So the cache exists mainly so that reopening a
/// repository, or opening one whose history has only moved forward a few commits, does not
/// pay that again.
///
/// Stored under Caches on purpose: it is reconstructible, and the system may evict it.
public enum AnalysisCache {
    /// Bumped whenever the meaning of what is stored changes — a new complexity rule, a new
    /// language, a changed model — so a stale cache can never resurrect wrong numbers.
    public static let formatVersion = 3

    public struct Payload: Codable, Sendable {
        public let formatVersion: Int
        public let headSHA: String
        public let createdAt: Date
        public let commits: [Commit]
        public let units: [CodeUnit]
        public let generatedFiles: [String]

        public init(headSHA: String, createdAt: Date = Date(), commits: [Commit],
                    units: [CodeUnit], generatedFiles: [String]) {
            self.formatVersion = AnalysisCache.formatVersion
            self.headSHA = headSHA
            self.createdAt = createdAt
            self.commits = commits
            self.units = units
            self.generatedFiles = generatedFiles
        }
    }

    public static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("fr.liriscom.gitview", isDirectory: true)
    }

    /// Keyed by the repository's resolved path, so two checkouts of the same project keep
    /// separate caches.
    public static func url(for root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return directory.appendingPathComponent("\(name).analysis")
    }

    public static func load(root: URL) -> Payload? {
        guard let compressed = try? Data(contentsOf: url(for: root)),
              let data = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.formatVersion == formatVersion
        else { return nil }
        return payload
    }

    @discardableResult
    public static func save(_ payload: Payload, root: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(payload)
            let compressed = try (data as NSData).compressed(using: .zlib) as Data
            try compressed.write(to: url(for: root), options: .atomic)
            return true
        } catch {
            return false   // a cache that cannot be written must never fail an analysis
        }
    }

    public static func clear(root: URL) {
        try? FileManager.default.removeItem(at: url(for: root))
    }

    public static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Bytes currently used, for the settings screen.
    public static func sizeOnDisk() -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return entries.reduce(Int64(0)) { total, entry in
            total + Int64((try? entry.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }
}
