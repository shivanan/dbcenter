import XCTest
@testable import DBCenter

final class ResultExportTests: XCTestCase {
    func testJSONPreservesDuplicateColumnsNullAndTextWithoutTypeGuessing() throws {
        let result = QueryResult(columns: ["value", "value", "text"],
                                 rows: [[nil, "001", "café\n\"quoted\""], ["", "false", "https://example.com"]],
                                 truncated: true)
        let data = try ResultExportFormat.json.data(for: result)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(document["columns"] as? [String], result.columns)
        let rows = try XCTUnwrap(document["rows"] as? [[Any]])
        XCTAssertTrue(rows[0][0] is NSNull)
        XCTAssertEqual(rows[0][1] as? String, "001")
        XCTAssertEqual(rows[0][2] as? String, "café\n\"quoted\"")
        XCTAssertEqual(rows[1][0] as? String, "")
        XCTAssertEqual(rows[1][1] as? String, "false")
        XCTAssertEqual(document["truncated"] as? Bool, true)
    }

    func testJSONExportsEmptyCommandResult() throws {
        let result = QueryResult(affected: 3)
        let data = try ResultExportFormat.json.data(for: result)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(document["rows"] as? [[String]], [])
        XCTAssertEqual(document["columns"] as? [String], [])
        XCTAssertEqual(document["affectedRows"] as? Int, 3)
    }

    func testCSVRetainsExistingEscapingAndLineEndings() throws {
        let result = QueryResult(columns: ["a", "b"], rows: [["a,\"b\"\nc", nil]])
        let data = try ResultExportFormat.csv.data(for: result)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"a\",\"b\"\r\n\"a,\"\"b\"\"\nc\",\"\"")
    }
}
