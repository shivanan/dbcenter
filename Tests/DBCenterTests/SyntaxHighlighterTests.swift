import AppKit
import XCTest
@testable import DBCenter

final class SyntaxHighlighterTests: XCTestCase {
    private func values(_ text: String, _ engine: Engine, _ kind: SyntaxHighlighter.Kind) -> [String] {
        SyntaxHighlighter.tokens(in: text, engine: engine).filter { $0.kind == kind }.map { (text as NSString).substring(with: $0.range) }
    }
    func testSQLStringsNestedCommentsAndDollarQuotesExcludeKeywords() {
        let text = "SELECT '😀 FROM ''WHERE''', $$SELECT 'x'$$, $body$FROM$body$, 42 /* WHERE /* SELECT */ END */ -- JOIN\nFROM people"
        XCTAssertEqual(values(text, .postgres, .keyword), ["SELECT", "FROM"])
        XCTAssertEqual(values(text, .postgres, .string), ["'😀 FROM ''WHERE'''", "$$SELECT 'x'$$", "$body$FROM$body$"])
        XCTAssertEqual(values(text, .postgres, .number), ["42"])
        XCTAssertEqual(values(text, .postgres, .comment).count, 2)
        XCTAssertEqual(values("SELECT [a]]b], \"table\" FROM x", .sqlServer, .identifier), ["[a]]b]", "\"table\""])
    }
    func testJSONKeysStringsBooleansAndNumbers() {
        let text = #"{"find":"😀 people", "filter":{"active":true,"value":null},"limit":1e2}"#
        XCTAssertEqual(values(text, .mongo, .identifier), ["\"find\"", "\"filter\"", "\"active\"", "\"value\"", "\"limit\""])
        XCTAssertEqual(values(text, .mongo, .keyword), ["true", "null"])
        XCTAssertEqual(values(text, .mongo, .number), ["1e2"])
        XCTAssertEqual(values(text, .mongo, .string), ["\"😀 people\""])
    }
    func testRedisAndFlux() {
        XCTAssertEqual(values("  SET key \"SELECT\"\nGET key", .redis, .keyword), ["SET", "GET"])
        let flux = "// from ignored\nfrom(bucket: \"metrics\") |> range(start: -1h) |> limit(n: 100)"
        XCTAssertEqual(values(flux, .influx, .keyword), ["from", "range", "limit"])
        XCTAssertEqual(values(flux, .influx, .number), ["1", "100"])
        XCTAssertEqual(values(flux, .influx, .comment), ["// from ignored"])
    }
    func testIncompleteTokensAndLargeQueriesAreSafe() {
        XCTAssertEqual(values("SELECT 'unfinished 😀", .postgres, .string), ["'unfinished 😀"])
        XCTAssertEqual(values("/* unfinished", .postgres, .comment), ["/* unfinished"])
        XCTAssertEqual(values("$tag$unfinished", .postgres, .string), ["$tag$unfinished"])
        XCTAssertTrue(SyntaxHighlighter.tokens(in: String(repeating: "x", count: 250_001), engine: .postgres).isEmpty)
    }
    @MainActor
    func testHighlightingDoesNotMutateTextSelectionOrStoredAttributes() async {
        let editor = QueryEditor.EditorTextView()
        editor.isRichText = false
        editor.string = "SELECT '😀'"
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        editor.layoutManager!.ensureLayout(for: editor.textContainer!)
        let original = editor.textStorage!.copy() as! NSAttributedString
        editor.applyHighlighting(SyntaxHighlighter.tokens(in: editor.string, engine: .postgres))
        XCTAssertEqual(editor.textStorage!, original)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 3))
        XCTAssertNotNil(editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil))
        editor.applyHighlighting([])
        XCTAssertNil(editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil))
    }
}
