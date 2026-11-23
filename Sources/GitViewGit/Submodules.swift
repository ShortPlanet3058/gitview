import Foundation

/// Parsed state of a git submodule reported by `git submodule status`.
public struct SubmoduleInfo: Identifiable, Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case clean
        case uninitialized
        case modified
        case mergeConflict

        public var label: String {
            switch self {
            case .clean:         return "Clean"
            case .uninitialized: return "Not initialized"
            case .modified:      return "Modified"
            case .mergeConflict: return "Conflict"
            }
        }
    }

    public var id: String { path }
    public let path: String
    public let sha: String
    public let describe: String?
    public let state: State

    public init(path: String, sha: String, describe: String?, state: State) {
        self.path = path
        self.sha = sha
        self.describe = describe
        self.state = state
    }
}

public enum SubmoduleParser {
    public static func parse(_ output: String) -> [SubmoduleInfo] {
        output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let prefix = line.first else { return nil }
            let state: SubmoduleInfo.State
            switch prefix {
            case "-": state = .uninitialized
            case "+": state = .modified
            case "U": state = .mergeConflict
            case " ": state = .clean
            default:  return nil
            }

            let remainder = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            let firstSplit = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard firstSplit.count == 2 else { return nil }
            let sha = String(firstSplit[0])
            var pathAndDescribe = String(firstSplit[1]).trimmingCharacters(in: .whitespaces)
            var describe: String?

            if pathAndDescribe.hasSuffix(")"), let openParen = pathAndDescribe.lastIndex(of: "(") {
                let before = pathAndDescribe[..<openParen]
                if before.last == " " {
                    let insideStart = pathAndDescribe.index(after: openParen)
                    let insideEnd = pathAndDescribe.index(before: pathAndDescribe.endIndex)
                    describe = String(pathAndDescribe[insideStart..<insideEnd])
                    pathAndDescribe = String(before).trimmingCharacters(in: .whitespaces)
                }
            }

            guard !sha.isEmpty, !pathAndDescribe.isEmpty else { return nil }
            return SubmoduleInfo(path: pathAndDescribe, sha: sha, describe: describe, state: state)
        }
    }
}

extension GitRepository {
    public func submodules() -> [SubmoduleInfo] {
        guard let root = try? validate(),
              let output = try? GitProcess.capture(arguments: ["submodule", "status"], in: root) else {
            return []
        }
        return SubmoduleParser.parse(output)
    }

    public func updateSubmodules(recursive: Bool = true) throws {
        var arguments = ["submodule", "update", "--init"]
        if recursive { arguments.append("--recursive") }
        try write(arguments)
    }
}
