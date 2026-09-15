import Foundation

struct AISchema: Codable, Sendable {
    struct Object: Codable, Sendable {
        let name: String
        let schema: String?
        let columns: [String]
        let note: String?
    }
    let engine: String
    let database: String
    let objects: [Object]
    let note: String
    func json() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 200_000 else { throw DBError("Database schema is too large for AI context (200 KB limit).") }
        return String(decoding: data, as: UTF8.self)
    }
}

extension DatabaseDriver {
    func aiSchema(database: String) async throws -> AISchema {
        try Task.checkCancellation()
        let objects = try await catalogObjects(database: database)
        var entries: [AISchema.Object] = []
        if server.engine == .postgres || server.engine == .sqlServer {
            let filter = server.engine == .postgres ? " WHERE TABLE_SCHEMA NOT IN ('pg_catalog', 'information_schema')" : ""
            let columns = try await execute("SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS\(filter) ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION", database: database)
            guard !columns.truncated else { throw DBError("Column catalog exceeds 10,000 rows; AI generation requires a smaller schema.") }
            var names: [DatabaseObject: [String]] = [:]
            for row in columns.rows {
                guard row.count >= 3, let schema = row[0], let table = row[1], let column = row[2] else { continue }
                names[DatabaseObject(name: table, schema: schema), default: []].append(column)
            }
            entries = objects.map { .init(name: $0.name, schema: $0.schema, columns: names[$0] ?? [], note: names[$0] == nil ? "Column metadata unavailable" : nil) }
        } else {
            guard objects.count <= 200 else { throw DBError("AI context supports up to 200 collections, keys, or measurements per database.") }
            for object in objects {
                try Task.checkCancellation()
                switch server.engine {
                case .mongo:
                    // Project field names on the server: document values never leave MongoDB.
                    let query = "{\"aggregate\":\(jsonString(object.name)),\"pipeline\":[{\"$limit\":20},{\"$project\":{\"fields\":{\"$objectToArray\":\"$$ROOT\"}}},{\"$unwind\":\"$fields\"},{\"$group\":{\"_id\":\"$fields.k\"}}],\"cursor\":{\"batchSize\":10000}}"
                    let result = try await execute(query, database: database)
                    guard !result.truncated else { throw DBError("Field discovery was incomplete for \(object.name).") }
                    let index = result.columns.firstIndex(of: "_id")
                    let fields = index.map { i in result.rows.compactMap { $0[i] }.sorted() } ?? []
                    entries.append(.init(name: object.name, schema: nil, columns: fields, note: "Top-level fields inferred from up to 20 documents; not exhaustive."))
                case .redis:
                    let type = try await execute("TYPE \(ObjectQueries.redisArgument(object.name))", database: database).rows.first?[1] ?? "unknown"
                    entries.append(.init(name: object.name, schema: nil, columns: [], note: "Redis type: \(type)"))
                case .influx:
                    let sections = try await objectDetails(object, database: database)
                    var fields: [String] = []
                    for section in sections {
                        guard !section.result.truncated else { throw DBError("Incomplete measurement metadata for \(object.name).") }
                        if let index = section.result.columns.firstIndex(of: "_value") { fields += section.result.rows.compactMap { $0[index] } }
                    }
                    entries.append(.init(name: object.name, schema: nil, columns: Array(Set(fields)).sorted(), note: "Field and tag keys observed in the last 30 days."))
                default: break
                }
            }
        }
        try Task.checkCancellation()
        return AISchema(engine: server.engine.rawValue, database: database, objects: entries,
                        note: server.engine == .redis ? "Keys from one SCAN iteration; not a full key inventory." : "Metadata visible to the connected database user; no record values included.")
    }
}
