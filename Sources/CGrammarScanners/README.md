# Vendored tree-sitter external scanners

`tree-sitter-python`, `tree-sitter-javascript` and `tree-sitter-css` decide whether to
compile their external scanner with

```swift
if FileManager.default.fileExists(atPath: "src/scanner.c") { sources.append("src/scanner.c") }
```

That path is **relative to the manifest's working directory**, which is not the package's
own directory when the package is consumed as a dependency. The check therefore fails, the
scanner is silently dropped, and linking fails with undefined
`tree_sitter_<lang>_external_scanner_*` symbols.

Every other grammar we use lists its scanner explicitly and is unaffected.

These three files are verbatim copies from the exact tags pinned in `Package.swift`
(python 0.25.0, javascript 0.25.0, css 0.25.0) together with the `tree_sitter` headers they
include. **If you bump one of those grammar versions, re-copy its scanner in the same
commit** — a scanner must match the parser tables it was generated with.
