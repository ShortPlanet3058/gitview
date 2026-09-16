import Foundation

/// Identifies a file's language for the repository breakdown.
///
/// This is deliberately separate from the parsers: naming a language needs only a lookup
/// table, while *analysing* one needs a grammar. So a repository's Dockerfiles, YAML and
/// shell scripts are named and measured here even though no function-level risk exists for
/// them.
///
/// The data mirrors GitHub Linguist's — which is what GitHub itself uses — so the breakdown
/// matches what you see there, without a network call, an API token, a rate limit, or
/// sending the repository's identity anywhere. It also works for repositories that are not
/// on GitHub at all.
public struct KnownLanguage: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case programming, markup, data, prose
    }
    public let name: String
    public let kind: Kind
    /// Linguist's colour, `nil` where Linguist defines none.
    public let colorHex: UInt32?

    public init(_ name: String, _ kind: Kind, _ colorHex: UInt32? = nil) {
        self.name = name; self.kind = kind; self.colorHex = colorHex
    }
}

public enum LanguageCatalog {
    /// Files identified by their whole name rather than an extension.
    static let byFilename: [String: KnownLanguage] = [
        "dockerfile": KnownLanguage("Dockerfile", .programming, 0x384D54),
        "containerfile": KnownLanguage("Dockerfile", .programming, 0x384D54),
        "makefile": KnownLanguage("Makefile", .programming, 0x427819),
        "gnumakefile": KnownLanguage("Makefile", .programming, 0x427819),
        "cmakelists.txt": KnownLanguage("CMake", .programming, 0xDA3434),
        "rakefile": KnownLanguage("Ruby", .programming, 0x701516),
        "gemfile": KnownLanguage("Ruby", .programming, 0x701516),
        "podfile": KnownLanguage("Ruby", .programming, 0x701516),
        "fastfile": KnownLanguage("Ruby", .programming, 0x701516),
        "vagrantfile": KnownLanguage("Ruby", .programming, 0x701516),
        "package.swift": KnownLanguage("Swift", .programming, 0xF05138),
        "justfile": KnownLanguage("Just", .programming, 0x384D54),
        "procfile": KnownLanguage("Procfile", .data, nil),
        "license": KnownLanguage("Text", .prose, nil),
        "readme": KnownLanguage("Markdown", .prose, 0x083FA1),
        ".gitignore": KnownLanguage("Ignore List", .data, nil),
        ".gitattributes": KnownLanguage("Git Attributes", .data, nil),
        ".editorconfig": KnownLanguage("EditorConfig", .data, nil),
        ".env": KnownLanguage("Dotenv", .data, nil),
    ]

    static let byExtension: [String: KnownLanguage] = {
        var map: [String: KnownLanguage] = [:]
        func add(_ language: KnownLanguage, _ extensions: [String]) {
            for ext in extensions { map[ext] = language }
        }
        // Programming
        add(KnownLanguage("Swift", .programming, 0xF05138), ["swift"])
        add(KnownLanguage("C", .programming, 0x555555), ["c", "h"])
        add(KnownLanguage("C++", .programming, 0xF34B7D), ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "ipp", "inl"])
        add(KnownLanguage("C#", .programming, 0x178600), ["cs", "csx"])
        add(KnownLanguage("Objective-C", .programming, 0x438EFF), ["m", "mm"])
        add(KnownLanguage("Python", .programming, 0x3572A5), ["py", "pyi", "pyw", "pyx", "pxd"])
        add(KnownLanguage("JavaScript", .programming, 0xF1E05A), ["js", "jsx", "mjs", "cjs"])
        add(KnownLanguage("TypeScript", .programming, 0x3178C6), ["ts", "mts", "cts"])
        add(KnownLanguage("TSX", .programming, 0x3178C6), ["tsx"])
        add(KnownLanguage("Java", .programming, 0xB07219), ["java"])
        add(KnownLanguage("Kotlin", .programming, 0xA97BFF), ["kt", "kts"])
        add(KnownLanguage("Scala", .programming, 0xC22D40), ["scala", "sc"])
        add(KnownLanguage("Groovy", .programming, 0x4298B8), ["groovy", "gradle"])
        add(KnownLanguage("Rust", .programming, 0xDEA584), ["rs"])
        add(KnownLanguage("Go", .programming, 0x00ADD8), ["go"])
        add(KnownLanguage("Ruby", .programming, 0x701516), ["rb", "rake", "gemspec", "ru"])
        add(KnownLanguage("PHP", .programming, 0x4F5D95), ["php", "phtml", "php3", "php4", "php5"])
        add(KnownLanguage("Perl", .programming, 0x0298C3), ["pl", "pm", "t"])
        add(KnownLanguage("Lua", .programming, 0x000080), ["lua"])
        add(KnownLanguage("Shell", .programming, 0x89E051), ["sh", "bash", "zsh", "fish", "ksh", "command"])
        add(KnownLanguage("PowerShell", .programming, 0x012456), ["ps1", "psm1", "psd1"])
        add(KnownLanguage("Batchfile", .programming, 0xC1F12E), ["bat", "cmd"])
        add(KnownLanguage("Dart", .programming, 0x00B4AB), ["dart"])
        add(KnownLanguage("Elixir", .programming, 0x6E4A7E), ["ex", "exs"])
        add(KnownLanguage("Erlang", .programming, 0xB83998), ["erl", "hrl"])
        add(KnownLanguage("Haskell", .programming, 0x5E5086), ["hs", "lhs"])
        add(KnownLanguage("OCaml", .programming, 0x3BE133), ["ml", "mli"])
        add(KnownLanguage("F#", .programming, 0xB845FC), ["fs", "fsi", "fsx"])
        add(KnownLanguage("Clojure", .programming, 0xDB5855), ["clj", "cljs", "cljc", "edn"])
        add(KnownLanguage("Julia", .programming, 0xA270BA), ["jl"])
        add(KnownLanguage("R", .programming, 0x198CE7), ["r", "rmd"])
        add(KnownLanguage("MATLAB", .programming, 0xE16737), ["mat"])
        add(KnownLanguage("Zig", .programming, 0xEC915C), ["zig"])
        add(KnownLanguage("Nim", .programming, 0xFFC200), ["nim", "nims"])
        add(KnownLanguage("Crystal", .programming, 0x000100), ["cr"])
        add(KnownLanguage("V", .programming, 0x4F87C4), ["v"])
        add(KnownLanguage("Solidity", .programming, 0xAA6746), ["sol"])
        add(KnownLanguage("Assembly", .programming, 0x6E4C13), ["asm", "s"])
        add(KnownLanguage("Verilog", .programming, 0xB2B7F8), ["sv", "vh"])
        add(KnownLanguage("VHDL", .programming, 0xADB2CB), ["vhd", "vhdl"])
        add(KnownLanguage("CUDA", .programming, 0x3A4E3A), ["cu", "cuh"])
        add(KnownLanguage("Metal", .programming, 0x8F14E9), ["metal"])
        add(KnownLanguage("GLSL", .programming, 0x5686A5), ["glsl", "vert", "frag", "shader"])
        add(KnownLanguage("Vim Script", .programming, 0x199F4B), ["vim"])
        add(KnownLanguage("Emacs Lisp", .programming, 0xC065DB), ["el"])
        add(KnownLanguage("Scheme", .programming, 0x1E4AEC), ["scm", "ss"])
        add(KnownLanguage("Common Lisp", .programming, 0x3FB68B), ["lisp", "lsp"])
        add(KnownLanguage("Fortran", .programming, 0x4D41B1), ["f", "f90", "f95", "for"])
        add(KnownLanguage("COBOL", .programming, nil), ["cob", "cbl"])
        add(KnownLanguage("Pascal", .programming, 0xE3F171), ["pas", "pp"])
        add(KnownLanguage("Ada", .programming, 0x02F88C), ["adb", "ads"])
        add(KnownLanguage("Tcl", .programming, 0xE4CC98), ["tcl"])
        add(KnownLanguage("Racket", .programming, 0x3C5CAA), ["rkt"])
        add(KnownLanguage("Gleam", .programming, 0xFFAFF3), ["gleam"])
        add(KnownLanguage("Odin", .programming, 0x60AFFE), ["odin"])
        add(KnownLanguage("Hack", .programming, 0x878787), ["hack", "hhi"])
        add(KnownLanguage("Apex", .programming, 0x1797C0), ["cls", "trigger"])
        add(KnownLanguage("SQL", .programming, 0xE38C00), ["sql", "psql", "mysql"])
        add(KnownLanguage("Starlark", .programming, 0x76D275), ["bzl", "star"])
        add(KnownLanguage("CMake", .programming, 0xDA3434), ["cmake"])
        add(KnownLanguage("Makefile", .programming, 0x427819), ["mk", "mak"])
        add(KnownLanguage("HCL", .programming, 0x844FBA), ["tf", "tfvars", "hcl"])
        add(KnownLanguage("Nix", .programming, 0x7E7EFF), ["nix"])
        add(KnownLanguage("Jsonnet", .programming, 0x0064BD), ["jsonnet", "libsonnet"])
        add(KnownLanguage("GraphQL", .data, 0xE10098), ["graphql", "gql"])
        add(KnownLanguage("Protocol Buffer", .data, 0x0080FF), ["proto"])
        add(KnownLanguage("Thrift", .programming, 0xD12127), ["thrift"])
        // Markup & styles
        add(KnownLanguage("HTML", .markup, 0xE34C26), ["html", "htm", "xhtml"])
        add(KnownLanguage("CSS", .markup, 0x663399), ["css"])
        add(KnownLanguage("SCSS", .markup, 0xC6538C), ["scss"])
        add(KnownLanguage("Sass", .markup, 0xA53B70), ["sass"])
        add(KnownLanguage("Less", .markup, 0x1D365D), ["less"])
        add(KnownLanguage("Vue", .markup, 0x41B883), ["vue"])
        add(KnownLanguage("Svelte", .markup, 0xFF3E00), ["svelte"])
        add(KnownLanguage("Astro", .markup, 0xFF5A03), ["astro"])
        add(KnownLanguage("Handlebars", .markup, 0xF7931E), ["hbs", "handlebars"])
        add(KnownLanguage("Twig", .markup, 0xC1D026), ["twig"])
        add(KnownLanguage("ERB", .markup, 0x701516), ["erb"])
        add(KnownLanguage("Blade", .markup, 0xF7523F), ["blade"])
        add(KnownLanguage("XML", .data, 0x0060AC), ["xml", "xsd", "xsl", "plist", "storyboard", "xib", "svg"])
        // Data & config
        add(KnownLanguage("JSON", .data, 0x292929), ["json", "json5", "jsonc"])
        add(KnownLanguage("YAML", .data, 0xCB171E), ["yml", "yaml"])
        add(KnownLanguage("TOML", .data, 0x9C4221), ["toml"])
        add(KnownLanguage("INI", .data, 0xD1DBE0), ["ini", "cfg", "conf"])
        add(KnownLanguage("CSV", .data, 0x237346), ["csv", "tsv"])
        add(KnownLanguage("Properties", .data, 0x2A6277), ["properties"])
        add(KnownLanguage("Lockfile", .data, nil), ["lock", "resolved"])
        // Prose
        add(KnownLanguage("Markdown", .prose, 0x083FA1), ["md", "markdown", "mdx"])
        add(KnownLanguage("reStructuredText", .prose, 0x141414), ["rst"])
        add(KnownLanguage("AsciiDoc", .prose, 0x73A0C5), ["adoc", "asciidoc"])
        add(KnownLanguage("TeX", .prose, 0x3D6117), ["tex", "sty", "bib"])
        add(KnownLanguage("Text", .prose, nil), ["txt"])
        add(KnownLanguage("Localization", .data, nil), ["strings", "stringsdict", "xcstrings", "po", "pot"])
        return map
    }()

    /// Identifies a file, preferring a whole-name match so `Dockerfile` and `Makefile`
    /// are recognised even though they have no extension.
    public static func language(forPath path: String) -> KnownLanguage? {
        let file = String(path.split(separator: "/").last ?? "").lowercased()
        if let match = byFilename[file] { return match }
        // `Dockerfile.web` and `web.Dockerfile` both occur in the wild.
        if file.hasPrefix("dockerfile.") || file.hasSuffix(".dockerfile") { return byFilename["dockerfile"] }
        if file.hasPrefix("makefile.") { return byFilename["makefile"] }
        if file.hasPrefix("readme.") { return byExtension[String(file.split(separator: ".").last ?? "")] ?? byFilename["readme"] }
        guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return nil }
        return byExtension[String(file[file.index(after: dot)...])]
    }

    /// Total known languages, for the "N languages recognised" caption.
    public static var count: Int {
        Set(byExtension.values.map(\.name)).union(byFilename.values.map(\.name)).count
    }
}
