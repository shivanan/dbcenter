import XCTest
@testable import DBCenter

final class ObjectActionsTests: XCTestCase {
    func testSQLPreviewQuotesComponentsWithoutSplittingDots() throws {
        let object = DatabaseObject(name: "odd.table\"x]", schema: "my.schema")
        XCTAssertEqual(try ObjectQueries.preview(object, engine: .postgres, database: "db"), "SELECT * FROM \"my.schema\".\"odd.table\"\"x]\" LIMIT 50;")
        XCTAssertEqual(try ObjectQueries.preview(object, engine: .sqlServer, database: "db"), "SELECT TOP (50) * FROM [my.schema].[odd.table\"x]]];")
        XCTAssertNotEqual(object.id, DatabaseObject(name: "schema.odd.table\"x]", schema: "my").id)
        let metadata = ObjectQueries.columns(DatabaseObject(name: "a'b\\c", schema: "s'"), engine: .postgres)
        XCTAssertTrue(metadata.contains("TABLE_SCHEMA = E's\\''"))
        XCTAssertTrue(metadata.contains("TABLE_NAME = E'a\\'b\\\\c'"))
    }
    func testMongoPreviewIsBoundedAndEscapesCollectionName() throws {
        let name = "a\"; strange.collection"
        let query = try ObjectQueries.preview(DatabaseObject(name: name), engine: .mongo, database: "db")
        let command = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(query.utf8)) as? [String: Any])
        XCTAssertEqual(command["find"] as? String, name)
        XCTAssertEqual(command["limit"] as? Int, 50)
        XCTAssertEqual(command["batchSize"] as? Int, 50)
        XCTAssertEqual(command["singleBatch"] as? Bool, true)
    }
    func testOtherEngineEscapingAndLimits() throws {
        let name = "a\"\\\n\u{0001}"
        let query = try ObjectQueries.redisPreview(key: name, type: "list")
        XCTAssertEqual(try QueryParser.redisArguments(query), ["LRANGE", name, "0", "49"])
        XCTAssertThrowsError(try ObjectQueries.redisPreview(key: "missing", type: "none"))
        let flux = try ObjectQueries.preview(DatabaseObject(name: "${bad}"), engine: .influx, database: "metrics")
        XCTAssertTrue(flux.contains("\\${bad}"))
        XCTAssertTrue(flux.contains("|> group()\n  |> limit(n: 50)"))
    }
}
