import XCTest
@testable import DBCenter

final class ParserTests: XCTestCase {
    func testRedisArgumentsPreserveSpacesEmptyStringsAndEscapes() throws {
        XCTAssertEqual(try QueryParser.redisArguments(#"SET "a key" "hello\nworld""#), ["SET", "a key", "hello\nworld"])
        XCTAssertEqual(try QueryParser.redisArguments("SET key ''"), ["SET", "key", ""])
        XCTAssertThrowsError(try QueryParser.redisArguments("GET 'open"))
        XCTAssertThrowsError(try QueryParser.redisArguments(" "))
    }
    func testInfluxCSVHandlesQuotedMultilineFieldsAndMultipleSchemas() throws {
        let csv = "#datatype,string,long,string\r\n#default,_result,,\r\n,result,table,note\r\n,,0,\"a,b\n\"\"quoted\"\"\"\r\n\r\n#datatype,string,long,double\n#default,_result,,\n,result,table,_value\n,,1,2.5\n"
        let result = try QueryParser.csv(csv)
        XCTAssertEqual(result.columns, ["column_0", "result", "table", "note", "_value"])
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0][1], "_result")
        XCTAssertEqual(result.rows[0][3], "a,b\n\"quoted\"")
        XCTAssertNil(result.rows[0][4])
        XCTAssertEqual(result.rows[1][4], "2.5")
        XCTAssertThrowsError(try QueryParser.csv("a,b\n\"broken"))
    }
    func testMongoDocumentsPreserveNullNestedValuesAndCursorNotice() throws {
        let result = try QueryParser.mongo(#"{"cursor":{"id":42,"firstBatch":[{"name":"Ana","value":null},{"name":"Bo","nested":{"n":1}}]},"ok":1}"#)
        XCTAssertEqual(result.columns, ["name", "nested", "value"])
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertNil(result.rows[0][2])
        XCTAssertEqual(result.rows[1][1], #"{"n":1}"#)
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(try QueryParser.mongo(#"{"cursor":{"id":0,"firstBatch":[]},"ok":1}"#).truncated)
    }
    func testConnectionEscapingAndCredentialFreePersistence() throws {
        XCTAssertEqual(DatabaseDriver.pgEscape("a'b\\c"), "'a\\'b\\\\c'")
        XCTAssertEqual(DatabaseDriver.odbcEscape("a};PWD=x"), "{a}};PWD=x}")
        let data = try JSONEncoder().encode(Server())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("password"))
    }
}

final class DriverIntegrationTests: XCTestCase {
    private func server(_ engine: Engine, port: Int, database: String) throws -> Server {
        guard ProcessInfo.processInfo.environment["DBCENTER_INTEGRATION"] == "1" else { throw XCTSkip("Set DBCENTER_INTEGRATION=1 and run scripts/test-integration.sh") }
        var s = Server(); s.engine = engine; s.name = "Integration"; s.host = "127.0.0.1"; s.port = port; s.database = database; s.tls = false
        return s
    }
    func testPostgresNativeSessionNullUnicodeErrorsAndDiscovery() async throws {
        var s = try server(.postgres, port: 15439, database: "postgres"); s.username = "dbcenter_test"
        let driver = DatabaseDriver(server: s, password: "")
        try await driver.connect(database: s.database)
        let result = try await driver.execute("SELECT 42 AS answer, NULL AS missing, 'café 🐘' AS unicode", database: s.database)
        XCTAssertEqual(result.rows[0], ["42", nil, "café 🐘"])
        _ = try await driver.execute("CREATE TEMP TABLE session_test (id int)", database: s.database)
        _ = try await driver.execute("INSERT INTO session_test VALUES (7)", database: s.database)
        let persisted = try await driver.execute("SELECT * FROM session_test", database: s.database)
        XCTAssertEqual(persisted.rows[0][0], "7")
        do { _ = try await driver.execute("SELECT invalid_column", database: s.database); XCTFail("Expected query error") } catch { XCTAssertTrue(error.localizedDescription.contains("invalid_column")) }
        let databases = try await driver.databases(); XCTAssertTrue(databases.contains("postgres"))
        let objects = try await driver.objects(database: s.database); XCTAssertTrue(objects.contains { $0.contains("session_test") })
        await driver.close()
    }
    func testMongoNativeCommandDocumentsAndDiscovery() async throws {
        let s = try server(.mongo, port: 27029, database: "dbcenter_test")
        let driver = DatabaseDriver(server: s, password: "")
        try await driver.connect(database: s.database)
        _ = try await driver.execute(#"{"insert":"people","documents":[{"name":"café 🍃","score":42}]}"#, database: s.database)
        let result = try await driver.execute(#"{"find":"people","filter":{},"limit":1}"#, database: s.database)
        let index = try XCTUnwrap(result.columns.firstIndex(of: "name")); XCTAssertEqual(result.rows[0][index], "café 🍃")
        let objects = try await driver.objects(database: s.database); XCTAssertTrue(objects.contains("people"))
        let databases = try await driver.databases(); XCTAssertTrue(databases.contains(s.database))
        do { _ = try await driver.execute("not json", database: s.database); XCTFail("Expected JSON error") } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        await driver.close()
    }
    func testRedisNativeSessionAndDatabaseIsolation() async throws {
        let s = try server(.redis, port: 16389, database: "0")
        let driver = DatabaseDriver(server: s, password: "")
        try await driver.connect(database: "0")
        _ = try await driver.execute(#"SET "a key" "café ⚡""#, database: "0")
        let result = try await driver.execute(#"GET "a key""#, database: "0"); XCTAssertEqual(result.rows[0][1], "café ⚡")
        try await driver.connect(database: "1")
        let missing = try await driver.execute(#"GET "a key""#, database: "1"); XCTAssertNil(missing.rows[0][1])
        let objects = try await driver.objects(database: "0"); XCTAssertTrue(objects.contains("a key"))
        let databases = try await driver.databases(); XCTAssertEqual(databases.count, 16)
        do { _ = try await driver.execute("NOT_A_COMMAND", database: "0"); XCTFail("Expected Redis error") } catch { XCTAssertTrue(error.localizedDescription.contains("unknown command")) }
        await driver.close()
    }
    func testInfluxHTTPContract() async throws {
        var s = try server(.influx, port: 18089, database: "metrics"); s.organization = "test org"
        let driver = DatabaseDriver(server: s, password: "test-token")
        try await driver.connect(database: s.database)
        let databases = try await driver.databases(); XCTAssertEqual(databases, ["metrics"])
        let result = try await driver.execute("from(bucket: \"metrics\") |> range(start: -1h)", database: s.database)
        XCTAssertEqual(result.rows.count, 1); XCTAssertEqual(result.rows[0].last!, "42")
    }
    func testODBCDriverLoadsAndReportsConnectionFailure() async throws {
        var s = try server(.sqlServer, port: 11439, database: "master"); s.username = "sa"
        let driver = DatabaseDriver(server: s, password: "test-password")
        do { try await driver.connect(database: s.database); XCTFail("No server expected on this port") }
        catch { XCTAssertFalse(error.localizedDescription.contains("driver missing")); XCTAssertFalse(error.localizedDescription.contains("incompatible")); XCTAssertFalse(error.localizedDescription.isEmpty) }
        await driver.close()
    }
}

extension DriverIntegrationTests {
    func testObjectPreviewAndStructureWithUnusualPostgresNames() async throws {
        var s = try server(.postgres, port: 15439, database: "postgres"); s.username = "dbcenter_test"
        let driver = DatabaseDriver(server: s, password: "")
        try await driver.connect(database: s.database)
        _ = try await driver.execute("CREATE SCHEMA \"odd.schema\"; CREATE TABLE \"odd.schema\".\"a.b'c\" (id integer NOT NULL, note text DEFAULT 'hello'); INSERT INTO \"odd.schema\".\"a.b'c\" SELECT n, 'value' FROM generate_series(1, 60) AS n;", database: s.database)
        let objects = try await driver.catalogObjects(database: s.database)
        let object = try XCTUnwrap(objects.first { $0.schema == "odd.schema" && $0.name == "a.b'c" })
        let preview = try await driver.previewObject(object, database: s.database)
        XCTAssertEqual(preview.result.rows.count, 50)
        let details = try await driver.objectDetails(object, database: s.database)
        XCTAssertEqual(details[0].result.rows.count, 2)
        XCTAssertEqual(details[0].result.rows[0][1], "id")
        XCTAssertEqual(details[0].result.rows[0][6], "NO")
        await driver.close()
    }
    func testMongoObjectPreviewLimitAndCollectionDetails() async throws {
        let s = try server(.mongo, port: 27029, database: "dbcenter_test")
        let driver = DatabaseDriver(server: s, password: "")
        try await driver.connect(database: s.database)
        let object = DatabaseObject(name: "preview.items")
        let docs = (1...60).map { "{\"value\":\($0)}" }.joined(separator: ",")
        _ = try await driver.execute("{\"insert\":\"preview.items\",\"documents\":[\(docs)]}", database: s.database)
        let preview = try await driver.previewObject(object, database: s.database)
        XCTAssertEqual(preview.result.rows.count, 50)
        XCTAssertFalse(preview.result.truncated)
        let details = try await driver.objectDetails(object, database: s.database)
        XCTAssertTrue(details[0].result.raw?.contains("preview.items") == true)
        XCTAssertTrue(details[0].result.raw?.contains("options") == true)
        await driver.close()
    }
}

extension DriverIntegrationTests {
    func testAISchemaIncludesSQLColumnsButNoRecordValues() async throws {
        var s = try server(.postgres, port: 15439, database: "postgres"); s.username = "dbcenter_test"
        let driver = DatabaseDriver(server: s, password: "")
        try await driver.connect(database: s.database)
        _ = try await driver.execute("CREATE TABLE ai_context_test (id integer, private_note text); INSERT INTO ai_context_test VALUES (1, 'DO_NOT_SEND_RECORD_CONTENT');", database: s.database)
        let schema = try await driver.aiSchema(database: s.database)
        let table = try XCTUnwrap(schema.objects.first { $0.name == "ai_context_test" })
        XCTAssertEqual(table.columns, ["id", "private_note"])
        XCTAssertFalse(try schema.json().contains("DO_NOT_SEND_RECORD_CONTENT"))
        await driver.close()
    }
    func testAIMongoSchemaReturnsFieldNamesWithoutValues() async throws {
        let s = try server(.mongo, port: 27029, database: "ai_context_test")
        let driver = DatabaseDriver(server: s, password: "")
        try await driver.connect(database: s.database)
        _ = try await driver.execute(#"{"insert":"people","documents":[{"name":"DO_NOT_SEND_RECORD_CONTENT","age":30}]}"#, database: s.database)
        let schema = try await driver.aiSchema(database: s.database)
        let object = try XCTUnwrap(schema.objects.first { $0.name == "people" })
        XCTAssertTrue(object.columns.contains("name"))
        XCTAssertTrue(object.columns.contains("age"))
        XCTAssertFalse(try schema.json().contains("DO_NOT_SEND_RECORD_CONTENT"))
        await driver.close()
    }
}
