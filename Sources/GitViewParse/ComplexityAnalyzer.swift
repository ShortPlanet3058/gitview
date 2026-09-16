import Foundation
import SwiftTreeSitter

/// Counts decision points and nesting within a unit's subtree.
///
/// These numbers exist to *rank units against each other*. They are not cyclomatic
/// complexity in any certified sense and should not be reported as such.
struct ComplexityAnalyzer {
    /// Node ids of every extracted unit, so a walk can stop at a nested declaration.
    let unitNodeIDs: Set<UInt>

    struct Result {
        var complexity: Int
        var nestingDepth: Int
    }

    /// Walks `root`'s subtree, pruning at any nested unit.
    ///
    /// Pruning matters: without it a type's complexity would be the sum of all its methods,
    /// so every class would outrank every function and the ranking would be worthless.
    /// Closures are *not* separate units, so they stay counted in their enclosing function —
    /// which is right, since a closure's branches are that function's branches.
    func analyze(root: Node) -> Result {
        // Complexity starts at 1: a unit with no branches still has one path through it.
        var result = Result(complexity: 1, nestingDepth: 0)
        visit(node: root, depth: 0, isRoot: true, into: &result)
        return result
    }

    private func visit(node: Node, depth: Int, isRoot: Bool, into result: inout Result) {
        let type = node.nodeType ?? ""

        // Stop at a nested declaration — it is its own unit and owns its own numbers.
        if !isRoot, unitNodeIDs.contains(node.id) { return }

        var childDepth = depth
        if SwiftNodeType.branching.contains(type) {
            result.complexity += 1
        }
        if type == "switch_entry", !isDefaultSwitchEntry(node) {
            // `case` arms are decision points; `default` is the fall-through, not a branch.
            result.complexity += 1
        }
        if SwiftNodeType.nesting.contains(type) {
            childDepth += 1
            result.nestingDepth = max(result.nestingDepth, childDepth)
        }

        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            visit(node: child, depth: childDepth, isRoot: false, into: &result)
        }
    }

    /// `switch_entry` covers both `case` and `default` arms; only `case` is a branch.
    ///
    /// The arm marker node is `default_keyword`, not `default` — verified against the
    /// grammar's own output, not assumed. Getting this wrong silently counts every
    /// `default:` as a decision point.
    private func isDefaultSwitchEntry(_ node: Node) -> Bool {
        guard node.nodeType == "switch_entry" else { return false }
        for index in 0..<node.childCount where node.child(at: index)?.nodeType == "default_keyword" {
            return true
        }
        return false
    }
}
