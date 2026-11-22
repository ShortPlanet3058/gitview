import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Persistent `git cat-file --batch` reader so inspecting N historical revisions of a file
/// reuses a single git process instead of spawning N separate `git show` invocations.
///
/// Thread-safe: concurrent callers (such as `UnitHistoryService`'s task group) serialize
/// over an internal lock so stdin queries and stdout frames remain strictly paired.
public final class GitBatchReader: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let inPipe: Pipe
    private let outPipe: Pipe
    private let errPipe: Pipe
    private var readBuffer = Data()
    private var closed = false

    public init(directory: URL) throws {
        let process = try GitProcess.makeProcess(arguments: ["cat-file", "--batch"], in: directory)
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain stderr quietly in the background so a flood of errors could never block.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }

        try process.run()

        self.process = process
        self.inPipe = inPipe
        self.outPipe = outPipe
        self.errPipe = errPipe
    }

    deinit {
        close()
    }

    /// Reads the blob contents for `sha:path`, returning `nil` if the object is missing or
    /// is not a blob (for instance, a tree or missing rename path).
    public func blob(sha: String, path: String) throws -> String? {
        guard !sha.isEmpty, !path.isEmpty,
              !sha.contains("\n"), !path.contains("\n"),
              !sha.contains("\0"), !path.contains("\0") else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        guard !closed else {
            throw GitError.failed(command: "cat-file --batch", code: -1, stderr: "reader closed")
        }

        let query = Data("\(sha):\(path)\n".utf8)
        try inPipe.fileHandleForWriting.write(contentsOf: query)

        guard let header = try readLine() else {
            throw GitError.failed(command: "cat-file --batch", code: -1, stderr: "unexpected EOF")
        }

        if let meta = Self.parseHeader(header) {
            let payload = try readExact(meta.size)
            _ = try readExact(1) // trailing newline emitted after object payload
            guard meta.type == "blob" else { return nil }
            return String(decoding: payload, as: UTF8.self)
        }

        if header.hasSuffix(" missing") {
            return nil
        }

        throw GitError.failed(
            command: "cat-file --batch",
            code: -1,
            stderr: "unexpected batch header: \(header)"
        )
    }

    /// Closes stdin so `git cat-file --batch` exits cleanly, and waits for process exit.
    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        try? inPipe.fileHandleForWriting.close()
        errPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.waitUntilExit()
        }
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
    }

    // MARK: - Buffered frame reading (called with `lock` held)

    private func readSomeBytes() throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let fd = outPipe.fileHandleForReading.fileDescriptor
        while true {
            #if canImport(Darwin)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                return Data(buffer[0..<count])
            } else if count == 0 {
                return nil
            } else {
                let err = errno
                if err == EINTR { continue }
                throw GitError.failed(
                    command: "cat-file --batch",
                    code: err,
                    stderr: String(cString: strerror(err))
                )
            }
            #else
            let chunk = outPipe.fileHandleForReading.availableData
            return chunk.isEmpty ? nil : chunk
            #endif
        }
    }

    private func readLine() throws -> String? {
        while true {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let lineLength = readBuffer.distance(from: readBuffer.startIndex, to: nl)
                let line = String(decoding: readBuffer.prefix(lineLength), as: UTF8.self)
                readBuffer.removeFirst(lineLength + 1)
                return line
            }
            guard let chunk = try readSomeBytes() else {
                return nil
            }
            readBuffer.append(chunk)
        }
    }

    private func readExact(_ count: Int) throws -> Data {
        while readBuffer.count < count {
            guard let chunk = try readSomeBytes() else {
                throw GitError.failed(command: "cat-file --batch", code: -1, stderr: "unexpected EOF")
            }
            readBuffer.append(chunk)
        }
        let slice = Data(readBuffer.prefix(count))
        readBuffer.removeFirst(count)
        return slice
    }

    private static func parseHeader(_ header: String) -> (type: String, size: Int)? {
        let parts = header.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count >= 40,
              parts[0].allSatisfy(\.isHexDigit),
              let size = Int(parts[2]), size >= 0 else {
            return nil
        }
        return (String(parts[1]), size)
    }
}
