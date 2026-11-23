import Foundation

/// Lightweight working-tree status summary shown on pinned and recent repository entries.
public struct RepositoryQuickStatus: Hashable, Sendable {
    public let branch: String?
    public let dirtyCount: Int
    public let ahead: Int
    public let behind: Int

    public init(branch: String?, dirtyCount: Int, ahead: Int, behind: Int) {
        self.branch = branch
        self.dirtyCount = dirtyCount
        self.ahead = ahead
        self.behind = behind
    }
}

extension GitRepository {
    public func quickStatus() -> RepositoryQuickStatus? {
        guard let root = try? validate(),
              let porcelain = try? GitProcess.capture(
                arguments: ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"],
                in: root
              ) else {
            return nil
        }
        let state = WorkingStateParser.parse(porcelain: porcelain, stashList: "", operation: nil)
        return RepositoryQuickStatus(
            branch: state.branch,
            dirtyCount: state.files.count,
            ahead: state.ahead,
            behind: state.behind
        )
    }
}
