import Foundation

/// Action applied to a single commit row in an interactive rebase plan.
public enum RebaseAction: String, CaseIterable, Identifiable, Sendable {
    case pick
    case reword
    case squash
    case fixup
    case drop

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pick:   return "Pick"
        case .reword: return "Reword"
        case .squash: return "Squash"
        case .fixup:  return "Fixup"
        case .drop:   return "Drop"
        }
    }
}

/// One commit row inside an interactive rebase plan (ordered oldest-first).
public struct RebaseTodoItem: Identifiable, Hashable, Sendable {
    public var id: String { sha }
    public let sha: String
    public let shortSHA: String
    public let subject: String
    public let author: String
    public var action: RebaseAction
    public var newMessage: String?

    public init(
        sha: String,
        shortSHA: String,
        subject: String,
        author: String,
        action: RebaseAction = .pick,
        newMessage: String? = nil
    ) {
        self.sha = sha
        self.shortSHA = shortSHA
        self.subject = subject
        self.author = author
        self.action = action
        self.newMessage = newMessage
    }
}

/// Pure validation & script/todo serialization helpers for `git rebase -i`.
public enum InteractiveRebaseBuilder {
    public static func validate(items: [RebaseTodoItem]) -> String? {
        guard !items.isEmpty else {
            return "No commits selected to rebase."
        }
        guard let firstKept = items.first(where: { $0.action != .drop }) else {
            return "At least one commit must be kept (cannot drop all commits)."
        }
        if firstKept.action == .squash || firstKept.action == .fixup {
            return "The first kept commit cannot be squashed or fixed up."
        }
        for item in items where item.action == .reword {
            if let custom = item.newMessage,
               custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Reworded commit \(item.shortSHA) needs a non-empty commit message."
            }
        }
        return nil
    }

    public static func sequenceTodo(from items: [RebaseTodoItem]) -> String {
        let lines = items.map { item in
            "\(item.action.rawValue) \(item.sha) \(item.subject)"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension GitRepository {
    /// Loads commits in `baseRef..HEAD` ordered oldest-first for interactive rebase.
    public func commitsForInteractiveRebase(onto baseRef: String, limit: Int = 50) throws -> [RebaseTodoItem] {
        let trimmedBase = baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else { return [] }
        let root = try validate()
        let output = try GitProcess.capture(
            arguments: [
                "log", "--reverse", "--max-count=\(max(1, limit))",
                "--format=%H%x1f%h%x1f%aN%x1f%s",
                "\(trimmedBase)..HEAD",
            ],
            in: root
        )
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { raw -> RebaseTodoItem? in
                let fields = raw.split(separator: "\u{1F}", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 4, !fields[0].isEmpty else { return nil }
                return RebaseTodoItem(
                    sha: fields[0],
                    shortSHA: fields[1],
                    subject: fields[3],
                    author: fields[2]
                )
            }
    }

    /// Runs non-interactive `git rebase -i` driven by temporary `GIT_SEQUENCE_EDITOR` and `GIT_EDITOR` scripts.
    public func interactiveRebase(onto baseRef: String, items: [RebaseTodoItem]) throws {
        let trimmedBase = baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else {
            throw GitWriteError(command: "rebase -i", message: "Choose a base branch or commit to rebase onto.")
        }
        if let problem = InteractiveRebaseBuilder.validate(items: items) {
            throw GitWriteError(command: "rebase -i", message: problem)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitview-rebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let todoURL = tempDir.appendingPathComponent("todo.txt")
        try InteractiveRebaseBuilder.sequenceTodo(from: items).write(
            to: todoURL,
            atomically: true,
            encoding: .utf8
        )

        let seqScriptURL = tempDir.appendingPathComponent("seq-editor.sh")
        let seqScript = """
        #!/bin/sh
        cp \(InteractiveRebaseBuilder.shellSingleQuoted(todoURL.path)) "$1"
        """
        try seqScript.write(to: seqScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: seqScriptURL.path)

        let rewordMessages: [String] = items.compactMap { item in
            guard item.action == .reword else { return nil }
            let chosen = item.newMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (chosen?.isEmpty == false) ? chosen! : item.subject
        }

        let counterURL = tempDir.appendingPathComponent("msg-index.txt")
        try "0\n".write(to: counterURL, atomically: true, encoding: .utf8)
        for (idx, msg) in rewordMessages.enumerated() {
            let msgFile = tempDir.appendingPathComponent("msg-\(idx).txt")
            try (msg + "\n").write(to: msgFile, atomically: true, encoding: .utf8)
        }

        let msgScriptURL = tempDir.appendingPathComponent("msg-editor.sh")
        let msgScript = """
        #!/bin/sh
        if grep -q "^# This is a combination" "$1" 2>/dev/null; then
            exit 0
        fi
        COUNTER_FILE=\(InteractiveRebaseBuilder.shellSingleQuoted(counterURL.path))
        TEMP_DIR=\(InteractiveRebaseBuilder.shellSingleQuoted(tempDir.path))
        IDX=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
        MSG_FILE="$TEMP_DIR/msg-$IDX.txt"
        if [ -f "$MSG_FILE" ]; then
            cp "$MSG_FILE" "$1"
            echo $((IDX + 1)) > "$COUNTER_FILE"
        fi
        exit 0
        """
        try msgScript.write(to: msgScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: msgScriptURL.path)

        try write(
            ["rebase", "-i", trimmedBase],
            environmentOverrides: [
                "GIT_SEQUENCE_EDITOR": seqScriptURL.path,
                "GIT_EDITOR": msgScriptURL.path,
            ]
        )
    }
}
