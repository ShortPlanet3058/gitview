import Foundation

/// Classifies source paths so the CLI and the app agree on what a test is.
public enum PathClassifier {
    /// Matches SwiftPM's `Tests/` convention, Xcode's `…Tests` group convention, and the
    /// common `FooTests.swift` / `FooTest.swift` file naming.
    public static func isTest(path: String) -> Bool {
        let components = path.split(separator: "/")
        for component in components.dropLast() {
            if component == "Tests" || component == "Test" { return true }
            if component.hasSuffix("Tests") { return true }
        }
        guard let file = components.last else { return false }
        let stem = file.hasSuffix(".swift") ? String(file.dropLast(6)) : String(file)
        return stem.hasSuffix("Tests") || stem.hasSuffix("Test")
            || stem.hasPrefix("Test") || stem.hasSuffix("Mock") || stem.hasSuffix("Fixtures")
    }
}
