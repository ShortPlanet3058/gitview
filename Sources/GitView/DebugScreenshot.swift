import SwiftUI
import AppKit

/// `GitView --repo <path> --screenshot out.png [--screenshot-delay 10] [--quit]`
///
/// Renders the root view offscreen with `ImageRenderer` after the delay. Used to verify
/// screens from the command line: it needs no screen-recording permission, does not care
/// which Space or app is in front, and never steals focus. Pure-SwiftUI content renders
/// fully; AppKit-backed views (the Advanced table) may come out blank.
@MainActor
enum DebugScreenshot {
    static func scheduleIfRequested(model: AnalysisModel) {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--screenshot"), flag + 1 < arguments.count else { return }
        let path = arguments[flag + 1]
        var delay = 10.0
        if let d = arguments.firstIndex(of: "--screenshot-delay"), d + 1 < arguments.count, let value = Double(arguments[d + 1]) {
            delay = value
        }
        let quit = arguments.contains("--quit")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            render(model: model, to: path)
            if quit { NSApplication.shared.terminate(nil) }
        }
    }

    static func render(model: AnalysisModel, to path: String) {
        let content = AppShell()
            .environmentObject(model)
            .frame(width: 1380, height: 820)
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
