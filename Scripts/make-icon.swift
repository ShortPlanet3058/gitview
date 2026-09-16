#!/usr/bin/env swift
// Renders GitView's app icon and writes Resources/AppIcon.icns.
//
// The icon is the same mark the app draws for itself in the sidebar — the branch glyph on
// the accent blue — rather than a separate piece of artwork that could drift away from it.
// Drawn with SwiftUI so the rounded square is the real continuous curve macOS uses, and so
// changing the app's accent colour here is a one-line change rather than a redraw.
//
// Usage: swift Scripts/make-icon.swift
// Run from the repository root; only needed when the mark itself changes.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  opacity: 1)
    }
}

/// One icon at a given point size. Proportions follow Apple's macOS grid: on a 1024 canvas
/// the rounded square is 824 across, which is what keeps it the same visual weight as every
/// other icon in the Dock.
struct IconCanvas: View {
    let size: CGFloat

    private var square: CGFloat { size * 824 / 1024 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: square * 0.225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(rgb: 0x4C8DF7), Color(rgb: 0x1D4ED8)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: square, height: square)
                // The soft contact shadow every macOS icon has; without it the icon looks
                // pasted onto the Dock rather than sitting in it.
                .shadow(color: .black.opacity(0.28), radius: size * 0.022, y: size * 0.012)
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: square * 0.52, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

@MainActor
func png(size: CGFloat, scale: CGFloat) -> Data? {
    let renderer = ImageRenderer(content: IconCanvas(size: size))
    renderer.scale = scale
    guard let cgImage = renderer.cgImage else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

@MainActor
func main() throws {
    let fileManager = FileManager.default
    let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
    try? fileManager.removeItem(at: iconset)
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

    // Every size macOS asks for, each rendered rather than resampled from one master, so
    // the 16pt icon is drawn at 16pt and stays legible instead of turning to mush.
    let sizes: [CGFloat] = [16, 32, 128, 256, 512]
    for size in sizes {
        for scale in [CGFloat(1), CGFloat(2)] {
            guard let data = png(size: size, scale: scale) else {
                throw NSError(domain: "make-icon", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "render failed at \(size)@\(scale)x"])
            }
            let suffix = scale == 1 ? "" : "@2x"
            let name = "icon_\(Int(size))x\(Int(size))\(suffix).png"
            try data.write(to: iconset.appendingPathComponent(name))
        }
    }

    try fileManager.createDirectory(at: URL(fileURLWithPath: "Resources"),
                                    withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["--convert", "icns", iconset.path, "--output", "Resources/AppIcon.icns"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "make-icon", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
    }
    let bytes = (try? fileManager.attributesOfItem(atPath: "Resources/AppIcon.icns"))?[.size] as? Int ?? 0
    print("wrote Resources/AppIcon.icns (\(bytes) bytes)")
}

try MainActor.assumeIsolated { try main() }
