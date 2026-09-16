import Foundation
import SwiftTreeSitter

/// Development aid: one hand-counted snippet per language.
///
/// Every snippet contains the same shape — a type with a method that has an `if`, a loop,
/// a short-circuit operator and a switch with a default arm — so the extracted numbers can
/// be checked by eye across languages.
public enum LanguageProbe {
    public struct Sample: Sendable {
        public let source: String
        public let expectedUnits: Int
    }

    /// Re-runs extraction and reports which node types contributed to each unit's score.
    public static func trace(_ support: LanguageSupport, source: String) throws -> [(String, Int, [String: Int])] {
        let extractor = try UnitExtractor(support: support)
        return try extractor.trace(source: source)
    }

    public static func sExpression(of source: String, support: LanguageSupport) -> String? {
        let parser = Parser()
        try? parser.setLanguage(support.makeLanguage())
        return parser.parse(source)?.rootNode?.sExpressionString
    }

    public static let samples: [String: Sample] = [
        "swift": Sample(source: """
        struct S {
            func work(_ x: Int) -> Int {
                guard x > 0 else { return 0 }
                for i in 0..<x { if i > 2 && x < 9 { return i } }
                switch x { case 1: break; default: break }
                return x
            }
        }
        """, expectedUnits: 2),

        "c": Sample(source: """
        int work(int x) {
            if (x > 0 && x < 9) { return 1; }
            for (int i = 0; i < x; i++) { }
            switch (x) { case 1: break; default: break; }
            return x;
        }
        """, expectedUnits: 1),

        "cpp": Sample(source: """
        class S {
        public:
            int work(int x) {
                if (x > 0 || x < 9) { return 1; }
                for (int i = 0; i < x; i++) { }
                return x;
            }
        };
        """, expectedUnits: 2),

        "csharp": Sample(source: """
        class S {
            public int Work(int x) {
                if (x > 0 && x < 9) { return 1; }
                foreach (var i in items) { }
                switch (x) { case 1: break; default: break; }
                return x;
            }
        }
        """, expectedUnits: 2),

        "python": Sample(source: """
        class S:
            def work(self, x):
                if x > 0 and x < 9:
                    return 1
                for i in range(x):
                    pass
                return x
        """, expectedUnits: 2),

        "javascript": Sample(source: """
        class S {
            work(x) {
                if (x > 0 && x < 9) { return 1; }
                for (const i of list) { }
                switch (x) { case 1: break; default: break; }
                return x;
            }
        }
        const helper = (a) => a ? 1 : 2;
        """, expectedUnits: 3),

        "typescript": Sample(source: """
        interface Thing { id: number }
        class S {
            work(x: number): number {
                if (x > 0 && x < 9) { return 1; }
                for (const i of list) { }
                return x;
            }
        }
        """, expectedUnits: 3),

        "tsx": Sample(source: """
        class S {
            work(x: number): number {
                if (x > 0 && x < 9) { return 1; }
                return x;
            }
        }
        """, expectedUnits: 2),

        "java": Sample(source: """
        class S {
            int work(int x) {
                if (x > 0 && x < 9) { return 1; }
                for (int i = 0; i < x; i++) { }
                switch (x) { case 1: break; default: break; }
                return x;
            }
        }
        """, expectedUnits: 2),

        "kotlin": Sample(source: """
        class S {
            fun work(x: Int): Int {
                if (x > 0 && x < 9) { return 1 }
                for (i in 0..x) { }
                when (x) { 1 -> {} else -> {} }
                return x
            }
        }
        """, expectedUnits: 2),

        "rust": Sample(source: """
        struct S;
        impl S {
            fn work(&self, x: i32) -> i32 {
                if x > 0 && x < 9 { return 1; }
                for i in 0..x { }
                match x { 1 => {}, _ => {} }
                x
            }
        }
        """, expectedUnits: 3),

        "go": Sample(source: """
        type S struct{}
        func (s *S) Work(x int) int {
            if x > 0 && x < 9 { return 1 }
            for i := 0; i < x; i++ { }
            switch x { case 1: default: }
            return x
        }
        """, expectedUnits: 2),

        "ruby": Sample(source: """
        class S
          def work(x)
            return 1 if x > 0 && x < 9
            for i in 0..x do end
            case x when 1 then nil else nil end
            x
          end
        end
        """, expectedUnits: 2),

        "php": Sample(source: """
        <?php
        class S {
            function work($x) {
                if ($x > 0 && $x < 9) { return 1; }
                foreach ($items as $i) { }
                switch ($x) { case 1: break; default: break; }
                return $x;
            }
        }
        """, expectedUnits: 2),

        "css": Sample(source: """
        .button { color: red; padding: 4px; margin: 0; }
        .card { display: flex; }
        """, expectedUnits: 2),
    ]
}
