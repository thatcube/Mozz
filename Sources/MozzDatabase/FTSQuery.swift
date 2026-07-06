import Foundation

/// Builds safe FTS5 MATCH patterns from raw, user-typed search text.
///
/// User input can contain FTS5 operators (`"`, `*`, `AND`, `:`, `-`, `(`) that
/// would either error or change query semantics. We defensively tokenize on
/// non-alphanumerics, wrap each token in double quotes (escaping embedded
/// quotes), and append `*` so every token is a prefix match — giving fast,
/// forgiving as-you-type search with implicit AND across tokens.
enum FTSQuery {
    static func pattern(for rawQuery: String) -> String? {
        let tokens = rawQuery
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return nil }

        return tokens
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " ")
    }
}
