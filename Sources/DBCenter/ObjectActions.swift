import Foundation

struct DatabaseObject: Identifiable, Hashable, Sendable {
    let name: String
    var schema: String? = nil
    var id: String { jsonString(schema ?? "") + jsonString(name) }
    var displayName: String { schema.map { "\($0).\(name)" } ?? name }
}

struct ObjectDetailsSection: Identifiable {
    let title: String
    let result: QueryResult
    var id: String { title }
}

enum ObjectQueries {
    static func fluxString(_ value: String) -> String { jsonString(value).replacingOccurrences(of: "${", with: "\\${") }
    static func redisArgument(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func identifier(_ value: String, engine: Engine) -> String {
        engine == .sqlServer ? "[" + value.replacingOccurrences(of: "]", with: "]]") + "]" : "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    static func literal(_ value: String, engine: Engine) -> String {
        engine == .postgres ? "E" + DatabaseDriver.pgEscape(value) : "N'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
    static func preview(_ object: DatabaseObject, engine: Engine, database: String) throws -> String {
        switch engine {
        case .postgres, .sqlServer:
            let name = ([object.schema].compactMap { $0 } + [object.name]).map { identifier($0, engine: engine) }.joined(separator: ".")
            return engine == .postgres ? "SELECT * FROM \(name) LIMIT 50;" : "SELECT TOP (50) * FROM \(name);"
        case .mongo:
            return "{\"find\":\(jsonString(object.name)),\"filter\":{},\"limit\":50,\"batchSize\":50,\"singleBatch\":true}"
        case .influx:
            return "from(bucket: \(fluxString(database)))\n  |> range(start: -30d)\n  |> filter(fn: (r) => r._measurement == \(fluxString(object.name)))\n  |> group()\n  |> limit(n: 50)"
        case .redis: throw DBError("Redis preview requires the key type.")
        }
    }
    static func columns(_ object: DatabaseObject, engine: Engine) -> String {
        let schema = literal(object.schema ?? (engine == .postgres ? "public" : "dbo"), engine: engine)
        return "SELECT ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE, IS_NULLABLE, COLUMN_DEFAULT FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(literal(object.name, engine: engine)) ORDER BY ORDINAL_POSITION;"
    }
    static func redisPreview(key: String, type: String) throws -> String {
        let key = redisArgument(key)
        switch type {
        case "string": return "GET \(key)"
        case "list": return "LRANGE \(key) 0 49"
        case "zset": return "ZRANGE \(key) 0 49"
        case "set": return "SSCAN \(key) 0 COUNT 50"
        case "hash": return "HSCAN \(key) 0 COUNT 50"
        case "stream": return "XRANGE \(key) - + COUNT 50"
        case "none": throw DBError("This key no longer exists. Refresh the inspector.")
        default: throw DBError("Preview is not available for Redis key type ‘\(type)’.")
        }
    }
}

extension DatabaseDriver {
    func catalogObjects(database: String) async throws -> [DatabaseObject] {
        if server.engine == .postgres || server.engine == .sqlServer {
            let filter = server.engine == .postgres ? " WHERE TABLE_SCHEMA NOT IN ('pg_catalog', 'information_schema')" : ""
            let result = try await execute("SELECT TABLE_SCHEMA, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES\(filter) ORDER BY TABLE_SCHEMA, TABLE_NAME", database: database)
            return result.rows.compactMap { row in
                guard row.count >= 2, let schema = row[0], let name = row[1] else { return nil }
                return DatabaseObject(name: name, schema: schema)
            }
        }
        return try await objects(database: database).map { DatabaseObject(name: $0) }
    }

    func previewObject(_ object: DatabaseObject, database: String) async throws -> (query: String, result: QueryResult) {
        var query: String
        if server.engine == .redis {
            let type = try await execute("TYPE \(ObjectQueries.redisArgument(object.name))", database: database).rows.first?[1] ?? "none"
            query = try ObjectQueries.redisPreview(key: object.name, type: type)
        } else { query = try ObjectQueries.preview(object, engine: server.engine, database: database) }
        var result = try await execute(query, database: database)
        if result.rows.count > 50 { result.rows = Array(result.rows.prefix(50)); result.truncated = true }
        return (query, result)
    }

    func objectDetails(_ object: DatabaseObject, database: String) async throws -> [ObjectDetailsSection] {
        switch server.engine {
        case .postgres, .sqlServer:
            return [ObjectDetailsSection(title: "Columns", result: try await execute(ObjectQueries.columns(object, engine: server.engine), database: database))]
        case .mongo:
            let query = "{\"listCollections\":1,\"filter\":{\"name\":\(jsonString(object.name))},\"nameOnly\":false}"
            return [ObjectDetailsSection(title: "Collection options & validation", result: try await execute(query, database: database))]
        case .redis:
            let type = try await execute("TYPE \(ObjectQueries.redisArgument(object.name))", database: database).rows.first?[1] ?? "none"
            let ttl = try await execute("TTL \(ObjectQueries.redisArgument(object.name))", database: database).rows.first?[1] ?? "Unknown"
            let expiry = ttl == "-1" ? "No expiration" : ttl == "-2" ? "Key no longer exists" : "\(ttl) seconds"
            return [ObjectDetailsSection(title: "Key details", result: QueryResult(columns: ["Property", "Value"], rows: [["Key", object.name], ["Type", type], ["Time to live", expiry]]))]
        case .influx:
            var sections: [ObjectDetailsSection] = []
            for (title, function) in [("Field keys · last 30 days", "measurementFieldKeys"), ("Tag keys · last 30 days", "measurementTagKeys")] {
                let query = "import \"influxdata/influxdb/schema\"\nschema.\(function)(bucket: \(ObjectQueries.fluxString(database)), measurement: \(ObjectQueries.fluxString(object.name)), start: -30d)"
                sections.append(ObjectDetailsSection(title: title, result: try await execute(query, database: database)))
            }
            return sections
        }
    }
}
