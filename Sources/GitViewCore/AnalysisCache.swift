import Foundation
import CryptoKit
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistent per-repository SQLite cache for commit history and parsed code units.
///
/// Storing commits keyed by SHA alongside `(bytes, mtime)`-keyed per-file unit rows lets
/// re-opens reuse unmodified files, re-parse only dirty files, prune deleted files, and
/// share already-parsed commits across branches.
///
/// Stored under Caches on purpose: it is reconstructible, and the system may evict it.
public enum AnalysisCache {
    /// Bumped whenever the meaning of stored results or schema changes.
    public static let formatVersion = 6

    public struct DivergencePair: Hashable, Sendable {
        public let baseSHA: String
        public let tipSHA: String

        public init(baseSHA: String, tipSHA: String) {
            self.baseSHA = baseSHA
            self.tipSHA = tipSHA
        }
    }

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

    public struct CachedFileUnits: Sendable, Equatable {
        public let path: String
        public let bytes: Int64
        public let modified: TimeInterval
        public let isGenerated: Bool
        public let units: [CodeUnit]

        public init(path: String, bytes: Int64, modified: TimeInterval,
                    isGenerated: Bool, units: [CodeUnit]) {
            self.path = path
            self.bytes = bytes
            self.modified = modified
            self.isGenerated = isGenerated
            self.units = units
        }
    }

    private static let writeLock = NSLock()

    public static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("fr.liriscom.gitview", isDirectory: true)
    }

    /// Keyed by the repository's resolved path so separate checkouts keep isolated caches.
    public static func url(for root: URL) -> URL {
        directory.appendingPathComponent("\(repoHash(for: root)).sqlite")
    }

    private static func legacyURL(for root: URL) -> URL {
        directory.appendingPathComponent("\(repoHash(for: root)).analysis")
    }

    private static func repoHash(for root: URL) -> String {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    // MARK: - Loading

    public static func load(root: URL) -> Payload? {
        load(root: root, matchingHead: nil)
    }

    /// Loads cached analysis for `matchingHead` if specified and present in the branch pool,
    /// otherwise for the last recorded active head.
    public static func load(root: URL, matchingHead: String?) -> Payload? {
        writeLock.lock()
        defer { writeLock.unlock() }

        let dbURL = url(for: root)
        guard FileManager.default.fileExists(atPath: dbURL.path),
              let db = openReadOnly(at: dbURL) else { return nil }
        defer { sqlite3_close_v2(db) }

        guard readMetaInt(db, key: "format_version") == formatVersion,
              let targetHead = matchingHead ?? readMetaString(db, key: "head_sha"),
              let branchData = readBranchHead(db, headSHA: targetHead) else {
            return nil
        }

        let orderedSHAs = splitSHAList(branchData.shasBlob)
        let commitMap = readAllCommits(db)
        var orderedCommits: [Commit] = []
        orderedCommits.reserveCapacity(orderedSHAs.count)
        for sha in orderedSHAs {
            guard let commit = commitMap[sha] else { return nil }
            orderedCommits.append(commit)
        }

        let fileEntries = readAllFileUnits(db)
        var units: [CodeUnit] = []
        var generated: [String] = []
        for entry in fileEntries {
            units.append(contentsOf: entry.units)
            if entry.isGenerated { generated.append(entry.path) }
        }

        return Payload(
            headSHA: targetHead,
            createdAt: Date(timeIntervalSince1970: branchData.createdAt),
            commits: orderedCommits,
            units: units,
            generatedFiles: generated.sorted()
        )
    }

    /// Returns cached per-file units keyed by repository-relative file path.
    public static func loadFileUnits(root: URL) -> [String: CachedFileUnits] {
        writeLock.lock()
        defer { writeLock.unlock() }

        let dbURL = url(for: root)
        guard FileManager.default.fileExists(atPath: dbURL.path),
              let db = openReadOnly(at: dbURL) else { return [:] }
        defer { sqlite3_close_v2(db) }

        guard readMetaInt(db, key: "format_version") == formatVersion else { return [:] }
        var map: [String: CachedFileUnits] = [:]
        for entry in readAllFileUnits(db) {
            map[entry.path] = entry
        }
        return map
    }

    /// Loads commits for an exact ordered list of SHAs from the repo's commit pool.
    /// Returns `nil` unless every requested SHA is already cached.
    public static func loadCommits(orderedSHAs: [String], root: URL) -> [Commit]? {
        writeLock.lock()
        defer { writeLock.unlock() }

        let dbURL = url(for: root)
        guard FileManager.default.fileExists(atPath: dbURL.path),
              let db = openReadOnly(at: dbURL) else { return nil }
        defer { sqlite3_close_v2(db) }

        guard readMetaInt(db, key: "format_version") == formatVersion else { return nil }
        let commitMap = readAllCommits(db)
        var result: [Commit] = []
        result.reserveCapacity(orderedSHAs.count)
        for sha in orderedSHAs {
            guard let commit = commitMap[sha] else { return nil }
            result.append(commit)
        }
        return result
    }

    // MARK: - Saving

    @discardableResult
    public static func save(_ payload: Payload, root: URL) -> Bool {
        let grouped = Dictionary(grouping: payload.units, by: \.filePath)
        let generatedSet = Set(payload.generatedFiles)
        let allPaths = Set(grouped.keys).union(generatedSet)
        let stamp = payload.createdAt.timeIntervalSince1970
        let entries = allPaths.sorted().map { path in
            CachedFileUnits(
                path: path,
                bytes: 0,
                modified: stamp,
                isGenerated: generatedSet.contains(path),
                units: grouped[path] ?? []
            )
        }
        return save(
            headSHA: payload.headSHA,
            createdAt: payload.createdAt,
            commits: payload.commits,
            fileEntries: entries,
            root: root
        )
    }

    /// Saves commit history (retaining older commits from other branches in the commit pool)
    /// and replaces `file_units` with the current checkout's entries so deleted files are pruned.
    @discardableResult
    public static func save(
        headSHA: String,
        createdAt: Date = Date(),
        commits: [Commit],
        fileEntries: [CachedFileUnits],
        root: URL
    ) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        try? FileManager.default.removeItem(at: legacyURL(for: root))

        let dbURL = url(for: root)
        guard let db = openWritableRecovering(at: dbURL) else { return false }
        defer {
            _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
            sqlite3_close_v2(db)
        }

        let existingVersion = readMetaInt(db, key: "format_version")
        guard exec(db, "BEGIN IMMEDIATE TRANSACTION;") else { return false }

        if existingVersion != formatVersion {
            let resetSQL = """
            DROP TABLE IF EXISTS meta;
            DROP TABLE IF EXISTS authors;
            DROP TABLE IF EXISTS commits;
            DROP TABLE IF EXISTS branch_heads;
            DROP TABLE IF EXISTS branch_divergence;
            DROP TABLE IF EXISTS file_units;
            """
            guard exec(db, resetSQL), exec(db, schemaSQL) else {
                _ = exec(db, "ROLLBACK;")
                return false
            }
        }

        let createdTimestamp = createdAt.timeIntervalSince1970
        guard writeMeta(db, key: "format_version", value: String(formatVersion)),
              writeMeta(db, key: "head_sha", value: headSHA),
              writeMeta(db, key: "created_at", value: String(createdTimestamp)),
              upsertCommits(db, commits: commits),
              writeBranchHead(db, headSHA: headSHA, createdAt: createdTimestamp, commits: commits),
              replaceFileUnits(db, entries: fileEntries),
              exec(db, "COMMIT;") else {
            _ = exec(db, "ROLLBACK;")
            return false
        }
        return true
    }

    public static func loadBranchDivergence(root: URL) -> [DivergencePair: (behind: Int, ahead: Int)] {
        writeLock.lock()
        defer { writeLock.unlock() }

        let dbURL = url(for: root)
        guard FileManager.default.fileExists(atPath: dbURL.path),
              let db = openReadOnly(at: dbURL) else { return [:] }
        defer { sqlite3_close_v2(db) }

        guard readMetaInt(db, key: "format_version") == formatVersion else { return [:] }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT base_sha, tip_sha, behind, ahead FROM branch_divergence;",
            -1, &stmt, nil
        ) == SQLITE_OK, let stmt else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var result: [DivergencePair: (behind: Int, ahead: Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let baseC = sqlite3_column_text(stmt, 0),
                  let tipC = sqlite3_column_text(stmt, 1) else { continue }
            let pair = DivergencePair(baseSHA: String(cString: baseC), tipSHA: String(cString: tipC))
            result[pair] = (behind: Int(sqlite3_column_int(stmt, 2)),
                            ahead: Int(sqlite3_column_int(stmt, 3)))
        }
        return result
    }

    @discardableResult
    public static func saveBranchDivergence(
        _ entries: [DivergencePair: (behind: Int, ahead: Int)],
        root: URL
    ) -> Bool {
        guard !entries.isEmpty else { return true }
        writeLock.lock()
        defer { writeLock.unlock() }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let dbURL = url(for: root)
        guard let db = openWritableRecovering(at: dbURL) else { return false }
        defer {
            _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
            sqlite3_close_v2(db)
        }

        let existingVersion = readMetaInt(db, key: "format_version")
        guard exec(db, "BEGIN IMMEDIATE TRANSACTION;") else { return false }

        if existingVersion != formatVersion {
            let resetSQL = """
            DROP TABLE IF EXISTS meta;
            DROP TABLE IF EXISTS authors;
            DROP TABLE IF EXISTS commits;
            DROP TABLE IF EXISTS branch_heads;
            DROP TABLE IF EXISTS branch_divergence;
            DROP TABLE IF EXISTS file_units;
            """
            guard exec(db, resetSQL), exec(db, schemaSQL),
                  writeMeta(db, key: "format_version", value: String(formatVersion)) else {
                _ = exec(db, "ROLLBACK;")
                return false
            }
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO branch_divergence (base_sha, tip_sha, behind, ahead) VALUES (?, ?, ?, ?);",
            -1, &stmt, nil
        ) == SQLITE_OK, let stmt else {
            _ = exec(db, "ROLLBACK;")
            return false
        }
        defer { sqlite3_finalize(stmt) }

        for (pair, counts) in entries.prefix(1000) {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, index: 1, pair.baseSHA)
            bindText(stmt, index: 2, pair.tipSHA)
            sqlite3_bind_int(stmt, 3, Int32(counts.behind))
            sqlite3_bind_int(stmt, 4, Int32(counts.ahead))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                _ = exec(db, "ROLLBACK;")
                return false
            }
        }
        // Bound stored pairs so branch turnover across remote updates never grows unboundedly.
        _ = exec(
            db,
            "DELETE FROM branch_divergence WHERE base_sha || '|' || tip_sha NOT IN (SELECT base_sha || '|' || tip_sha FROM branch_divergence LIMIT 1000);"
        )
        return exec(db, "COMMIT;")
    }

    // MARK: - Cleanup & Sizing

    public static func clear(root: URL) {
        writeLock.lock()
        defer { writeLock.unlock() }
        removeSQLiteFiles(at: url(for: root))
        try? FileManager.default.removeItem(at: legacyURL(for: root))
    }

    public static func clearAll() {
        writeLock.lock()
        defer { writeLock.unlock() }
        try? FileManager.default.removeItem(at: directory)
    }

    public static func sizeOnDisk(for root: URL) -> Int64 {
        let base = url(for: root).path
        let paths = [base, base + "-wal", base + "-shm"]
        return paths.reduce(Int64(0)) { total, path in
            let item = URL(fileURLWithPath: path)
            let bytes = (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(bytes)
        }
    }

    /// Bytes currently used across all cached repositories, for the settings screen.
    public static func sizeOnDisk() -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return entries.reduce(Int64(0)) { total, entry in
            total + Int64((try? entry.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    // MARK: - SQLite Helpers

    private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS authors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        email TEXT NOT NULL,
        UNIQUE(name, email)
    );
    CREATE TABLE IF NOT EXISTS commits (
        sha TEXT PRIMARY KEY,
        parents TEXT NOT NULL DEFAULT '',
        author_id INTEGER NOT NULL,
        timestamp REAL NOT NULL,
        subject TEXT NOT NULL,
        changes_blob BLOB NOT NULL
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS branch_heads (
        head_sha TEXT PRIMARY KEY,
        created_at REAL NOT NULL,
        shas_blob BLOB NOT NULL
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS branch_divergence (
        base_sha TEXT NOT NULL,
        tip_sha TEXT NOT NULL,
        behind INTEGER NOT NULL,
        ahead INTEGER NOT NULL,
        PRIMARY KEY (base_sha, tip_sha)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS file_units (
        path TEXT PRIMARY KEY,
        bytes INTEGER NOT NULL,
        mtime REAL NOT NULL,
        is_generated INTEGER NOT NULL,
        units_blob BLOB NOT NULL
    ) WITHOUT ROWID;
    """

    private static func openReadOnly(at url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close_v2(db) }
            return nil
        }
        return db
    }

    private static func openWritableRecovering(at url: URL) -> OpaquePointer? {
        if let db = tryOpenWritable(at: url) {
            return db
        }
        removeSQLiteFiles(at: url)
        return tryOpenWritable(at: url)
    }

    private static func tryOpenWritable(at url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            return nil
        }
        guard exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;"),
              exec(db, schemaSQL) else {
            sqlite3_close_v2(db)
            return nil
        }
        return db
    }

    private static func removeSQLiteFiles(at url: URL) {
        let base = url.path
        for path in [base, base + "-wal", base + "-shm"] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func readMetaString(_ db: OpaquePointer, key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }

    private static func readMetaInt(_ db: OpaquePointer, key: String) -> Int? {
        readMetaString(db, key: key).flatMap(Int.init)
    }

    private static func writeMeta(_ db: OpaquePointer, key: String, value: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?);", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, key)
        bindText(stmt, index: 2, value)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private static func readBranchHead(_ db: OpaquePointer, headSHA: String) -> (createdAt: TimeInterval, shasBlob: Data)? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT created_at, shas_blob FROM branch_heads WHERE head_sha = ?;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, headSHA)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let createdAt = sqlite3_column_double(stmt, 0)
        guard let blob = columnBlob(stmt, index: 1),
              let raw = decompress(blob) else { return nil }
        return (createdAt, raw)
    }

    private static func writeBranchHead(_ db: OpaquePointer, headSHA: String,
                                        createdAt: TimeInterval, commits: [Commit]) -> Bool {
        let joined = commits.map(\.sha).joined(separator: "\n")
        guard let compressed = compress(Data(joined.utf8)) else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO branch_heads (head_sha, created_at, shas_blob) VALUES (?, ?, ?);",
            -1, &stmt, nil
        ) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, headSHA)
        sqlite3_bind_double(stmt, 2, createdAt)
        bindBlob(stmt, index: 3, compressed)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private static func readAuthorsByKey(_ db: OpaquePointer) -> [AuthorKey: Int64] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, name, email FROM authors;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var map: [AuthorKey: Int64] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let nameC = sqlite3_column_text(stmt, 1),
                  let emailC = sqlite3_column_text(stmt, 2) else { continue }
            map[AuthorKey(name: String(cString: nameC), email: String(cString: emailC))] = sqlite3_column_int64(stmt, 0)
        }
        return map
    }

    private static func readAuthorsByID(_ db: OpaquePointer) -> [Int64: AuthorKey] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, name, email FROM authors;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var map: [Int64: AuthorKey] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let nameC = sqlite3_column_text(stmt, 1),
                  let emailC = sqlite3_column_text(stmt, 2) else { continue }
            map[sqlite3_column_int64(stmt, 0)] = AuthorKey(name: String(cString: nameC), email: String(cString: emailC))
        }
        return map
    }

    private struct AuthorKey: Hashable {
        let name: String
        let email: String
    }

    private static func upsertCommits(_ db: OpaquePointer, commits: [Commit]) -> Bool {
        var authorIDs = readAuthorsByKey(db)
        var insertAuthorStmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO authors (name, email) VALUES (?, ?);",
            -1, &insertAuthorStmt, nil
        ) == SQLITE_OK, let insertAuthorStmt else { return false }
        defer { sqlite3_finalize(insertAuthorStmt) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR IGNORE INTO commits (sha, parents, author_id, timestamp, subject, changes_blob) VALUES (?, ?, ?, ?, ?, ?);",
            -1, &stmt, nil
        ) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }

        for commit in commits {
            let key = AuthorKey(name: commit.author, email: commit.email)
            let authorID: Int64
            if let existing = authorIDs[key] {
                authorID = existing
            } else {
                sqlite3_reset(insertAuthorStmt)
                sqlite3_clear_bindings(insertAuthorStmt)
                bindText(insertAuthorStmt, index: 1, commit.author)
                bindText(insertAuthorStmt, index: 2, commit.email)
                guard sqlite3_step(insertAuthorStmt) == SQLITE_DONE else { return false }
                let newID = sqlite3_last_insert_rowid(db)
                authorIDs[key] = newID
                authorID = newID
            }

            let encodedChanges = encodeFileChanges(commit.fileChanges)
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, index: 1, commit.sha)
            bindText(stmt, index: 2, commit.parents.joined(separator: " "))
            sqlite3_bind_int64(stmt, 3, authorID)
            sqlite3_bind_double(stmt, 4, commit.date.timeIntervalSince1970)
            bindText(stmt, index: 5, commit.subject)
            bindBlob(stmt, index: 6, encodedChanges)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    private static func readAllCommits(_ db: OpaquePointer) -> [String: Commit] {
        let authors = readAuthorsByID(db)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT sha, parents, author_id, timestamp, subject, changes_blob FROM commits;",
            -1, &stmt, nil
        ) == SQLITE_OK, let stmt else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var commits: [String: Commit] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let shaC = sqlite3_column_text(stmt, 0),
                  let parentsC = sqlite3_column_text(stmt, 1),
                  let subjectC = sqlite3_column_text(stmt, 4),
                  let blob = columnBlob(stmt, index: 5),
                  let changes = decodeFileChanges(blob) else { continue }
            let sha = String(cString: shaC)
            let parents = String(cString: parentsC)
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            let authorID = sqlite3_column_int64(stmt, 2)
            let identity = authors[authorID] ?? AuthorKey(name: "", email: "")
            commits[sha] = Commit(
                sha: sha,
                parents: parents,
                author: identity.name,
                email: identity.email,
                date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                subject: String(cString: subjectC),
                fileChanges: changes
            )
        }
        return commits
    }

    private static func replaceFileUnits(_ db: OpaquePointer, entries: [CachedFileUnits]) -> Bool {
        guard exec(db, "DELETE FROM file_units;") else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO file_units (path, bytes, mtime, is_generated, units_blob) VALUES (?, ?, ?, ?, ?);",
            -1, &stmt, nil
        ) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }

        let encoder = JSONEncoder()
        for entry in entries {
            guard let raw = try? encoder.encode(entry.units),
                  let compressed = compress(raw) else { return false }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, index: 1, entry.path)
            sqlite3_bind_int64(stmt, 2, entry.bytes)
            sqlite3_bind_double(stmt, 3, entry.modified)
            sqlite3_bind_int(stmt, 4, entry.isGenerated ? 1 : 0)
            bindBlob(stmt, index: 5, compressed)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    private static func readAllFileUnits(_ db: OpaquePointer) -> [CachedFileUnits] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT path, bytes, mtime, is_generated, units_blob FROM file_units;",
            -1, &stmt, nil
        ) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        let decoder = JSONDecoder()
        var result: [CachedFileUnits] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let pathC = sqlite3_column_text(stmt, 0),
                  let blob = columnBlob(stmt, index: 4),
                  let raw = decompress(blob),
                  let units = try? decoder.decode([CodeUnit].self, from: raw) else { continue }
            result.append(CachedFileUnits(
                path: String(cString: pathC),
                bytes: sqlite3_column_int64(stmt, 1),
                modified: sqlite3_column_double(stmt, 2),
                isGenerated: sqlite3_column_int(stmt, 3) != 0,
                units: units
            ))
        }
        return result
    }

    // MARK: - SQLite Binding & Binary Encoding Helpers

    private static func bindText(_ stmt: OpaquePointer, index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private static func bindBlob(_ stmt: OpaquePointer, index: Int32, _ data: Data) {
        if data.isEmpty {
            sqlite3_bind_blob(stmt, index, UnsafeRawPointer(bitPattern: 1), 0, nil)
        } else {
            data.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
        }
    }

    private static func columnBlob(_ stmt: OpaquePointer, index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0 else { return Data() }
        guard let ptr = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: ptr, count: count)
    }

    private static func compress(_ data: Data) -> Data? {
        try? (data as NSData).compressed(using: .zlib) as Data
    }

    private static func decompress(_ data: Data) -> Data? {
        try? (data as NSData).decompressed(using: .zlib) as Data
    }

    private static func splitSHAList(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func encodeFileChanges(_ changes: [FileChange]) -> Data {
        var out = Data(capacity: max(8, changes.count * 24))
        out.append(1) // binary format version
        appendVarUInt(UInt64(changes.count), to: &out)
        for change in changes {
            appendString(change.path, to: &out)
            if let old = change.oldPath {
                out.append(1)
                appendString(old, to: &out)
            } else {
                out.append(0)
            }
            out.append(change.isNewFile ? 1 : 0)
            appendVarUInt(UInt64(change.hunks.count), to: &out)
            for hunk in change.hunks {
                appendVarUInt(UInt64(max(0, hunk.oldStart)), to: &out)
                appendVarUInt(UInt64(max(0, hunk.oldLineCount)), to: &out)
                appendVarUInt(UInt64(max(0, hunk.newStart)), to: &out)
                appendVarUInt(UInt64(max(0, hunk.newLineCount)), to: &out)
            }
        }
        return out
    }

    private static func decodeFileChanges(_ data: Data) -> [FileChange]? {
        var offset = 0
        guard !data.isEmpty, data[data.startIndex] == 1 else { return nil }
        offset = 1
        guard let count = readVarUInt(data, offset: &offset) else { return nil }
        var changes: [FileChange] = []
        changes.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let path = readString(data, offset: &offset),
                  offset < data.count else { return nil }
            let hasOld = data[data.startIndex + offset] != 0
            offset += 1
            let oldPath: String?
            if hasOld {
                guard let s = readString(data, offset: &offset) else { return nil }
                oldPath = s
            } else {
                oldPath = nil
            }
            guard offset < data.count else { return nil }
            let isNew = data[data.startIndex + offset] != 0
            offset += 1
            guard let hunkCount = readVarUInt(data, offset: &offset) else { return nil }
            var hunks: [Hunk] = []
            hunks.reserveCapacity(Int(hunkCount))
            for _ in 0..<hunkCount {
                guard let oldStart = readVarUInt(data, offset: &offset),
                      let oldCount = readVarUInt(data, offset: &offset),
                      let newStart = readVarUInt(data, offset: &offset),
                      let newCount = readVarUInt(data, offset: &offset) else { return nil }
                hunks.append(Hunk(
                    oldStart: Int(oldStart),
                    oldLineCount: Int(oldCount),
                    newStart: Int(newStart),
                    newLineCount: Int(newCount)
                ))
            }
            changes.append(FileChange(path: path, oldPath: oldPath, hunks: hunks, isNewFile: isNew))
        }
        return changes
    }

    private static func appendVarUInt(_ value: UInt64, to data: inout Data) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private static func readVarUInt(_ data: Data, offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[data.startIndex + offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    private static func appendString(_ string: String, to data: inout Data) {
        let utf8 = Data(string.utf8)
        appendVarUInt(UInt64(utf8.count), to: &data)
        data.append(utf8)
    }

    private static func readString(_ data: Data, offset: inout Int) -> String? {
        guard let length = readVarUInt(data, offset: &offset) else { return nil }
        let len = Int(length)
        guard offset + len <= data.count else { return nil }
        let start = data.startIndex + offset
        let str = String(decoding: data[start..<(start + len)], as: UTF8.self)
        offset += len
        return str
    }
}
