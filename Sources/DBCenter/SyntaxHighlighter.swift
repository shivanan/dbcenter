import Foundation

/// A lightweight lexer for editor colors, not a query validator.
/// All offsets use UTF-16, matching NSTextView and NSLayoutManager.
enum SyntaxHighlighter {
    enum Kind: Sendable { case keyword, string, comment, number, identifier }
    struct Token: Sendable, Equatable { let range: NSRange; let kind: Kind }

    private static let sqlWords = Set("SELECT FROM WHERE AS AND OR NOT NULL TRUE FALSE JOIN LEFT RIGHT INNER OUTER FULL CROSS ON USING GROUP BY ORDER HAVING LIMIT OFFSET FETCH NEXT ROW ROWS ONLY DISTINCT ALL UNION INTERSECT EXCEPT INSERT INTO VALUES UPDATE SET DELETE RETURNING OUTPUT CREATE ALTER DROP TABLE VIEW INDEX DATABASE SCHEMA IF EXISTS PRIMARY KEY FOREIGN REFERENCES UNIQUE CHECK DEFAULT CONSTRAINT WITH RECURSIVE CASE WHEN THEN ELSE END IS IN LIKE ILIKE BETWEEN ASC DESC TOP OVER PARTITION WINDOW BEGIN COMMIT ROLLBACK TRANSACTION EXPLAIN ANALYZE SHOW USE EXEC EXECUTE DECLARE MERGE TRUNCATE GRANT REVOKE COUNT SUM AVG MIN MAX COALESCE CAST CONVERT INT INTEGER BIGINT TEXT VARCHAR BOOLEAN DATE TIMESTAMP".split(separator: " ").map(String.init))
    private static let fluxWords = Set("import package option builtin test if then else and or not exists true false return from range filter map keep drop group sort limit yield aggregateWindow mean sum count first last union join pivot to".split(separator: " ").map(String.init))
    private static let number = try! NSRegularExpression(pattern: #"(?:0[xX][0-9a-fA-F]+|[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)"#)

    static func tokens(in text: String, engine: Engine) -> [Token] {
        let source = text as NSString, count = source.length
        // Keep very large pasted queries responsive; execution is unaffected.
        guard count <= 250_000 else { return [] }
        var output: [Token] = [], index = 0, redisCommand = true
        let sql = engine == .postgres || engine == .sqlServer
        func char(_ i: Int) -> unichar { i < count ? source.character(at: i) : 0 }
        func wordStart(_ c: unichar) -> Bool { (65...90).contains(c) || (97...122).contains(c) || c == 95 }
        func wordPart(_ c: unichar) -> Bool { wordStart(c) || (48...57).contains(c) }
        func emit(_ start: Int, _ kind: Kind) { output.append(Token(range: NSRange(location: start, length: index - start), kind: kind)) }
        while index < count {
            let start = index, c = char(index), next = char(index + 1)
            if c == 10 || c == 13 { redisCommand = true; index += 1; continue }
            if c == 32 || c == 9 { index += 1; continue }
            if (sql && c == 45 && next == 45) || (engine == .influx && c == 47 && next == 47) {
                index += 2
                while index < count && char(index) != 10 && char(index) != 13 { index += 1 }
                emit(start, .comment); continue
            }
            if sql && c == 47 && next == 42 {
                index += 2; var depth = 1
                while index < count && depth > 0 {
                    if char(index) == 47 && char(index + 1) == 42 { depth += 1; index += 2 }
                    else if char(index) == 42 && char(index + 1) == 47 { depth -= 1; index += 2 }
                    else { index += 1 }
                }
                emit(start, .comment); continue
            }
            if engine == .postgres && c == 36 {
                var end = index + 1
                if wordStart(char(end)) { end += 1; while wordPart(char(end)) { end += 1 } }
                if char(end) == 36 {
                    let delimiter = source.substring(with: NSRange(location: index, length: end - index + 1))
                    let body = end + 1
                    let close = source.range(of: delimiter, range: NSRange(location: body, length: count - body))
                    index = close.location == NSNotFound ? count : NSMaxRange(close)
                    emit(start, .string); continue
                }
            }
            let quotedIdentifier = sql && (c == 34 || (engine == .sqlServer && c == 91))
            let quotedString = (c == 39 && (sql || engine == .redis)) || (c == 34 && !sql)
            if quotedIdentifier || quotedString {
                let closing: unichar = c == 91 ? 93 : c
                // PostgreSQL E'...' strings and non-SQL strings accept backslash escapes.
                let escapes = !sql || (engine == .postgres && start > 0 && (char(start - 1) == 69 || char(start - 1) == 101))
                index += 1
                while index < count {
                    if escapes && char(index) == 92 { index = min(index + 2, count) }
                    else if char(index) == closing {
                        index += 1
                        if sql && char(index) == closing { index += 1 } else { break }
                    } else { index += 1 }
                }
                var kind: Kind = quotedIdentifier ? .identifier : .string
                if engine == .mongo {
                    var after = index
                    while [9, 10, 13, 32].contains(char(after)) && after < count { after += 1 }
                    if char(after) == 58 { kind = .identifier }
                }
                emit(start, kind); redisCommand = false; continue
            }
            if engine == .redis && redisCommand {
                while index < count && ![9, 10, 13, 32].contains(char(index)) { index += 1 }
                emit(start, .keyword); redisCommand = false; continue
            }
            if (48...57).contains(c), let match = number.firstMatch(in: text, options: .anchored, range: NSRange(location: index, length: count - index)) {
                index = NSMaxRange(match.range)
                emit(start, .number); continue
            }
            if wordStart(c) {
                index += 1; while wordPart(char(index)) { index += 1 }
                let word = source.substring(with: NSRange(location: start, length: index - start))
                if (sql && sqlWords.contains(word.uppercased())) || (engine == .influx && fluxWords.contains(word)) || (engine == .mongo && ["true", "false", "null"].contains(word)) { emit(start, .keyword) }
                continue
            }
            index += 1
        }
        return output
    }
}
