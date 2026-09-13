import AppKit
import XCTest
@testable import DBCenter

final class WorkspaceFocusTests: XCTestCase {
    @MainActor
    func testFocusTargetsEditorAndSelectsDatabaseText() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        editor.string = "SELECT 1"; editor.setSelectedRange(NSRange(location: 3, length: 0))
        let combo = NSComboBox(frame: NSRect(x: 0, y: 200, width: 200, height: 24))
        combo.stringValue = "postgres"
        window.contentView!.addSubview(editor); window.contentView!.addSubview(combo)
        let focus = WorkspaceFocus()
        focus.register(editor, for: .editor); focus.register(combo, for: .database)
        focus.request(.editor)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
        focus.request(.database)
        XCTAssertTrue(window.firstResponder === combo.currentEditor())
        XCTAssertEqual((combo.currentEditor() as? NSTextView)?.selectedRange(), NSRange(location: 0, length: 8))
    }

    @MainActor
    func testPendingSearchFocusIsConsumedWithoutStealingLaterFocus() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        let search = NSSearchField(frame: NSRect(x: 0, y: 200, width: 200, height: 24))
        window.contentView!.addSubview(editor)
        let focus = WorkspaceFocus()
        focus.register(editor, for: .editor)
        focus.request(.tableSearch)
        window.contentView!.addSubview(search)
        focus.register(search, for: .tableSearch)
        await nextMainQueueTurn()
        XCTAssertTrue(window.firstResponder === search.currentEditor())
        focus.request(.editor)
        focus.register(search, for: .tableSearch)
        await nextMainQueueTurn()
        XCTAssertTrue(window.firstResponder === editor)
    }

    @MainActor
    func testGridFocusSelectsFirstCellAndPreservesExistingCell() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let table = ResultGrid.CopyTable(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let coordinator = ResultGrid.Coordinator()
        let result = QueryResult(columns: ["a", "b"], rows: [["first", "second"]])
        coordinator.result = result; table.result = result
        table.dataSource = coordinator; table.delegate = coordinator
        for index in [-1, 0, 1] { table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))) }
        window.contentView!.addSubview(table)
        table.reloadData()
        let focus = WorkspaceFocus()
        focus.register(table, for: .results)
        focus.request(.results)
        XCTAssertTrue(window.firstResponder === table)
        XCTAssertEqual(table.copyText, "first")
        table.selectCell(.init(row: 0, column: 1))
        focus.request(.results)
        XCTAssertEqual(table.copyText, "second")
    }

    @MainActor private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
