import Foundation
import CDBDrivers

/// Each server owns a serial worker queue and a persistent native driver handle.
/// Blocking C driver operations never run on the main thread or Swift's cooperative pool.
final class DatabaseDriver: @unchecked Sendable {
    let server: Server
    private let password: String
    private let queue = DispatchQueue(label: "com.dbcenter.driver", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var currentDatabase = ""
    init(server: Server, password: String) { self.server = server; self.password = password }
    deinit { if let handle { db_close(handle) } }
    private func work<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: error) } }
        }
    }
    func close() async { _ = try? await work { self.closeNative() } }
    private func closeNative() { if let handle { db_close(handle) }; handle = nil; currentDatabase = "" }
    static func pgEscape(_ s: String) -> String { "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }
    static func odbcEscape(_ s: String) -> String { "{" + s.replacingOccurrences(of: "}", with: "}}") + "}" }
    private func openNative(database: String) throws {
        if handle != nil && (currentDatabase == database || server.engine == .mongo) { currentDatabase = database; return }
        closeNative()
        let s = server
        var kind: Int32 = 0, connection = ""
        switch s.engine {
        case .postgres:
            let pairs = ["host": s.host, "port": String(s.port), "user": s.username, "password": password, "dbname": database, "sslmode": s.tls ? "verify-full" : "disable", "connect_timeout": "10", "application_name": "DBCenter", "options": "-c statement_timeout=30000"]
            connection = pairs.map { "\($0.key)=\(Self.pgEscape($0.value))" }.joined(separator: " ")
        case .sqlServer:
            kind = 1
            connection = "Driver={ODBC Driver 18 for SQL Server};Server=\(Self.odbcEscape("\(s.host),\(s.port)"));Database=\(Self.odbcEscape(database));UID=\(Self.odbcEscape(s.username));PWD=\(Self.odbcEscape(password));Encrypt=\(s.tls ? "yes" : "no");TrustServerCertificate=no;APP=DBCenter;"
        case .mongo:
            kind = 2
            var url = URLComponents(); url.scheme = "mongodb"; url.host = s.host; url.port = s.port
            if !s.username.isEmpty { url.user = s.username; url.password = password }
            url.path = "/" + database
            url.queryItems = [URLQueryItem(name: "authSource", value: s.authDatabase), URLQueryItem(name: "tls", value: s.tls ? "true" : "false"), URLQueryItem(name: "serverSelectionTimeoutMS", value: "10000"), URLQueryItem(name: "socketTimeoutMS", value: "30000"), URLQueryItem(name: "appName", value: "DBCenter")]
            guard let uri = url.string else { throw DBError("Invalid MongoDB host or database.") }; connection = uri
        case .redis:
            kind = 3
            guard !s.tls else { throw DBError("This Redis adapter supports TCP connections. For local Redis, turn off TLS. Redis TLS support is not yet implemented.") }
        case .influx: return
        }
        var error: UnsafeMutablePointer<CChar>?
        handle = db_open(kind, connection, s.host, Int32(s.port), &error)
        guard handle != nil else { let message = error.map { String(cString: $0) } ?? "Could not connect."; db_string_free(error); throw DBError(message) }
        currentDatabase = database
        do {
            if s.engine == .redis {
                if !password.isEmpty { _ = try native(database: database, query: "", args: s.username.isEmpty ? ["AUTH", password] : ["AUTH", s.username, password]) }
                _ = try native(database: database, query: "", args: ["SELECT", database])
                _ = try native(database: database, query: "", args: ["PING"])
            }
            if s.engine == .mongo { _ = try native(database: database, query: "{\"ping\":1}") }
        } catch { closeNative(); throw error }
    }
    private func native(database: String, query: String, args: [String] = []) throws -> QueryResult {
        guard let handle else { throw DBError("Connect to the server first.") }
        let strings = args.map { strdup($0)! }; defer { strings.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) }
        let pointer = pointers.withUnsafeMutableBufferPointer { db_query(handle, database, query, Int32(args.count), $0.baseAddress) }
        guard let pointer else { throw DBError("Driver returned no result.") }; defer { db_result_free(pointer) }
        let r = pointer.pointee
        if let error = r.error { throw DBError(String(cString: error)) }
        if let json = r.json { return try QueryParser.mongo(String(cString: json)) }
        let columns = (0..<Int(r.columns)).map { r.names![$0].map { String(cString: $0) } ?? "Column \($0+1)" }
        var rows: [[String?]] = []
        for row in 0..<Int(r.rows) {
            var values: [String?] = []
            for col in 0..<Int(r.columns) {
                let cell = r.cells![row * Int(r.columns) + col]
                values.append(cell.map { String(cString: $0) })
            }
            rows.append(values)
        }
        return QueryResult(columns: columns, rows: rows, affected: r.affected, truncated: r.truncated != 0)
    }
    func connect(database: String) async throws {
        if server.engine == .influx { _ = try await request(path: "/api/v2/buckets", query: [URLQueryItem(name: "org", value: server.organization), URLQueryItem(name: "limit", value: "1")]); return }
        try await work { try self.openNative(database: database) }
    }
    func execute(_ query: String, database: String) async throws -> QueryResult {
        let start = Date()
        var result: QueryResult
        if server.engine == .influx {
            let data = try await request(path: "/api/v2/query", query: [URLQueryItem(name: "org", value: server.organization)], body: Data(query.utf8))
            result = try QueryParser.csv(String(decoding: data, as: UTF8.self))
        } else {
            result = try await work {
                try self.openNative(database: database)
                let args = self.server.engine == .redis ? try QueryParser.redisArguments(query) : []
                if let verb = args.first?.uppercased(), ["SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "MONITOR", "HELLO", "AUTH", "SELECT", "QUIT"].contains(verb) { throw DBError("Use the connection settings and database picker to change the session. Streaming Redis commands are not supported in this query editor.") }
                return try self.native(database: database, query: query, args: args)
            }
        }
        result.elapsed = Date().timeIntervalSince(start); return result
    }
    func databases() async throws -> [String] {
        switch server.engine {
        case .postgres: return try await execute("SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname", database: server.database).rows.compactMap { $0.first ?? nil }
        case .sqlServer: return try await execute("SELECT name FROM sys.databases WHERE HAS_DBACCESS(name) = 1 ORDER BY name", database: server.database).rows.compactMap { $0.first ?? nil }
        case .mongo:
            let r = try await execute("{\"listDatabases\":1,\"nameOnly\":true}", database: "admin")
            let d = try JSONSerialization.jsonObject(with: Data((r.raw ?? "{}").utf8)) as? [String: Any]
            return (d?["databases"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.sorted() ?? []
        case .redis:
            let r = try await execute("CONFIG GET databases", database: server.database)
            let count = Int(r.rows.last?.last.flatMap { $0 } ?? "") ?? 16
            return (0..<min(max(count, 1), 1024)).map(String.init)
        case .influx:
            var names: [String] = []; var offset = 0
            while true {
                let data = try await request(path: "/api/v2/buckets", query: [URLQueryItem(name: "org", value: server.organization), URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "offset", value: String(offset))])
                let d = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let batch = d?["buckets"] as? [[String: Any]] ?? []
                names += batch.compactMap { $0["name"] as? String }; if batch.count < 100 { break }; offset += 100
            }
            return names.sorted()
        }
    }
    func objects(database: String) async throws -> [String] {
        switch server.engine {
        case .postgres:
            return try await execute("SELECT table_schema || '.' || table_name FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema') ORDER BY 1", database: database).rows.compactMap { $0.first ?? nil }
        case .sqlServer:
            return try await execute("SELECT TABLE_SCHEMA + '.' + TABLE_NAME FROM INFORMATION_SCHEMA.TABLES ORDER BY 1", database: database).rows.compactMap { $0.first ?? nil }
        case .mongo:
            let r = try await execute("{\"listCollections\":1,\"nameOnly\":true,\"cursor\":{\"batchSize\":10000}}", database: database)
            guard let index = r.columns.firstIndex(of: "name") else { return [] }; return r.rows.compactMap { $0[index] }.sorted()
        case .redis:
            let r = try await execute("SCAN 0 COUNT 100", database: database)
            return r.rows.filter { ($0[0] ?? "").hasPrefix("1.") }.compactMap { $0[1] }.sorted()
        case .influx:
            let r = try await execute("import \"influxdata/influxdb/schema\"\nschema.measurements(bucket: \(jsonString(database)))", database: database)
            guard let index = r.columns.firstIndex(of: "_value") else { return [] }; return r.rows.compactMap { $0[index] }.sorted()
        }
    }
    private func request(path: String, query: [URLQueryItem], body: Data? = nil) async throws -> Data {
        var url = URLComponents(); url.scheme = server.tls ? "https" : "http"; url.host = server.host; url.port = server.port; url.path = path; url.queryItems = query
        guard let url = url.url else { throw DBError("Invalid InfluxDB endpoint.") }
        var request = URLRequest(url: url, timeoutInterval: 30); request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("Token \(password)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.flux", forHTTPHeaderField: "Content-Type")
        request.setValue(body == nil ? "application/json" : "application/csv", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw DBError("InfluxDB request failed: \(String(decoding: data.prefix(2000), as: UTF8.self))") }
        return data
    }
}
