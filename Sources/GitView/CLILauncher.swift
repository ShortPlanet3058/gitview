import Foundation

/// Installs and removes a small `gitview` shell launcher script so `gitview .` opens a repository in GitView.app.
public enum CLILauncher {
    public static let marker = "# GitView CLI launcher"

    public static var defaultDirectories: [URL] {
        [
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin", isDirectory: true),
        ]
    }

    public static func scriptContent(appPath: String = "/Applications/GitView.app") -> String {
        let escapedAppPath = appPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        #!/bin/sh
        \(marker)
        TARGET="${1:-.}"
        if [ -d "$TARGET" ]; then
          TARGET=$(cd "$TARGET" && pwd)
        elif [ -e "$TARGET" ]; then
          TARGET=$(cd "$(dirname "$TARGET")" && pwd)
        fi
        open -a "\(escapedAppPath)" --args --repo "$TARGET"
        """
    }

    public static func installedPath(searchDirectories: [URL] = defaultDirectories) -> URL? {
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent("gitview")
            guard FileManager.default.isExecutableFile(atPath: candidate.path),
                  let content = try? String(contentsOf: candidate, encoding: .utf8),
                  content.contains(marker) else {
                continue
            }
            return candidate
        }
        return nil
    }

    @discardableResult
    public static func install(
        into directory: URL? = nil,
        appPath: String = "/Applications/GitView.app",
        candidateDirectories: [URL] = defaultDirectories
    ) throws -> URL {
        let targets = directory.map { [$0] } ?? candidateDirectories
        let script = scriptContent(appPath: appPath) + "\n"
        var lastError: Error?

        for targetDir in targets {
            let destination = targetDir.appendingPathComponent("gitview")
            do {
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
                try script.write(to: destination, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: destination.path
                )
                return destination
            } catch {
                lastError = error
            }
        }

        throw lastError ?? NSError(
            domain: "fr.liriscom.gitview.cli",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not write gitview launcher script."]
        )
    }

    public static func uninstall(from path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let contents = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        guard contents.contains(marker) else {
            throw NSError(
                domain: "fr.liriscom.gitview.cli",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Refusing to remove \(path.path) because it was not created by GitView."]
            )
        }
        try FileManager.default.removeItem(at: path)
    }
}
