import AppKit
import SwiftUI
import XCTest
@testable import DBCenter

final class QueryExecutionTests: XCTestCase {
    func testSelectionUsesUTF16OffsetsAndPreservesExactText() {
        let query = "-- 😀\nSELECT 1;\nSELECT 'café';"
        let selection = (query as NSString).range(of: "SELECT 'café';")
        XCTAssertEqual(QueryExecution.text(query: query, selection: selection), "SELECT 'café';")
        XCTAssertEqual(QueryExecution.text(query: query, selection: NSRange(location: 8, length: 0)), query)
    }

    func testWhitespaceAndInvalidSelectionsNeverFallBackToFullQuery() {
        let query = "SELECT 1;\n  \nDROP TABLE people;"
        XCTAssertEqual(QueryExecution.text(query: query, selection: (query as NSString).range(of: "\n  \n")), "\n  \n")
        XCTAssertEqual(QueryExecution.text(query: query, selection: NSRange(location: NSNotFound, length: 3)), "")
        XCTAssertEqual(QueryExecution.text(query: query, selection: NSRange(location: 1, length: Int.max)), "")
    }

    @MainActor
    func testNativeSelectionUpdatesSharedExecutionAndQueryReplacementClearsIt() async {
        let workspace = Workspace(server: Server())
        workspace.query = "SELECT 1; SELECT 2;"
        let view = QueryEditor(text: Binding(get: { workspace.query }, set: { workspace.query = $0 }),
                               selection: Binding(get: { workspace.querySelection }, set: { workspace.querySelection = $0 }), run: {})
        let coordinator = QueryEditor.Coordinator(view)
        let editor = QueryEditor.EditorTextView()
        editor.string = workspace.query
        editor.setSelectedRange((editor.string as NSString).range(of: "SELECT 2;"))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: editor))
        XCTAssertEqual(workspace.executionText, "SELECT 2;")
        // The workspace retains selection even when a toolbar or menu takes focus.
        XCTAssertEqual(workspace.query, "SELECT 1; SELECT 2;")
        workspace.query = "SELECT 3;"
        XCTAssertEqual(workspace.querySelection.length, 0)
        XCTAssertEqual(workspace.executionText, "SELECT 3;")
        // User edits synchronize both the latest text and the current native selection.
        editor.string = "SELECT 4; SELECT 5;"
        editor.setSelectedRange((editor.string as NSString).range(of: "SELECT 5;"))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(workspace.executionText, "SELECT 5;")
    }
}
