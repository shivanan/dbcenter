import AppKit
import XCTest
@testable import DBCenter

final class ResultCellTests: XCTestCase {
    func testCellCopyUsesFullValueWithoutHeaderOrNeighbors() async {
        await MainActor.run {
            let table = ResultGrid.CopyTable()
            let value = "café\t\"quoted\"\n" + String(repeating: "long text ", count: 100)
            table.result = QueryResult(columns: ["duplicate", "duplicate"], rows: [["neighbor", value]])
            table.selectCell(.init(row: 0, column: 1))
            XCTAssertEqual(table.copyText, value)
            XCTAssertEqual(table.selectedCell, .init(row: 0, column: 1))
        }
    }

    func testEmptyAndNullCellCopyMatchDisplayedValues() async {
        await MainActor.run {
            let table = ResultGrid.CopyTable()
            table.result = QueryResult(columns: ["empty", "null"], rows: [["", nil]])
            table.selectCell(.init(row: 0, column: 0))
            XCTAssertEqual(table.copyText, "")
            table.selectCell(.init(row: 0, column: 1))
            XCTAssertEqual(table.copyText, "NULL")
            table.selectCell(nil)
            XCTAssertEqual(table.copyText, "empty\tnull\n\tNULL")
        }
    }

    func testResultReplacementClearsStaleCellSelection() async {
        await MainActor.run {
            let table = ResultGrid.CopyTable()
            let result = QueryResult(columns: ["value"], rows: [["a"], ["b"]])
            table.result = result
            table.selectCell(.init(row: 1, column: 0))
            table.result = result
            XCTAssertEqual(table.selectedCell, .init(row: 1, column: 0))
            table.result = QueryResult(columns: ["value"], rows: [])
            XCTAssertNil(table.selectedCell)
            XCTAssertEqual(table.copyText, "value")
            table.selectCell(.init(row: 50, column: 50))
            XCTAssertNil(table.selectedCell)
        }
    }
}
