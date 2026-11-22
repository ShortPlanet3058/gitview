import SwiftUI
import AppKit

/// `GitView --repo <path> [--screen <name>] [--mode standard|advanced] [--view list|graph]
/// [--select <unit>] [--select-pair <name>] --screenshot out.png [--screenshot-delay 10] [--quit]`
///
/// Renders the root view offscreen with `ImageRenderer` after the delay.
@MainActor
enum DebugScreenshot {
    static func scheduleIfRequested(session: WorkspaceSession) {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--screenshot"), flag + 1 < arguments.count else { return }
        let path = arguments[flag + 1]
        var delay = 10.0
        if let d = arguments.firstIndex(of: "--screenshot-delay"),
           d + 1 < arguments.count,
           let value = Double(arguments[d + 1]) {
            delay = value
        }
        let quit = arguments.contains("--quit")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            render(session: session, to: path)
            if quit { NSApplication.shared.terminate(nil) }
        }
    }

    static func render(session: WorkspaceSession, to path: String) {
        var height: CGFloat = 820
        let arguments = CommandLine.arguments
        if let h = arguments.firstIndex(of: "--screenshot-height"),
           h + 1 < arguments.count,
           let value = Double(arguments[h + 1]) {
            height = CGFloat(value)
        }
        let content = AppShell()
            .withWorkspaceEnvironment(session)
            .environment(\.staticRendering, true)
            .frame(width: 1380, height: height)
            .background(Theme.page)
        let appearance = NSApplication.shared.effectiveAppearance
        let scheme: ColorScheme = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("GitView: screenshot render failed\n".utf8))
                return
            }
            do { try png.write(to: URL(fileURLWithPath: path)) }
            catch { FileHandle.standardError.write(Data("GitView: screenshot write failed: \(error)\n".utf8)) }
        }
    }
}
