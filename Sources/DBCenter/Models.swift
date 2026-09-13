import Foundation
import SwiftUI
import Security

enum Engine: String, Codable, CaseIterable, Identifiable {
    case postgres = "Postgres", sqlServer = "SQL Server", mongo = "MongoDB", redis = "Redis", influx = "InfluxDB"
    var id: String { rawValue }
    var port: Int { switch self { case .postgres: 5432; case .sqlServer: 1433; case .mongo: 27017; case .redis: 6379; case .influx: 8086 } }
    var symbol: String { switch self { case .postgres: "cylinder.split.1x2"; case .sqlServer: "externaldrive.connected.to.line.below"; case .mongo: "leaf"; case .redis: "bolt"; case .influx: "waveform.path" } }
    var color: Color { switch self { case .postgres: .blue; case .sqlServer: .purple; case .mongo: .green; case .redis: .red; case .influx: .orange } }
    var language: String { switch self { case .postgres, .sqlServer: "SQL"; case .mongo: "JSON command"; case .redis: "Redis command"; case .influx: "Flux" } }
    var objectLabel: String { switch self { case .postgres, .sqlServer: "Tables & views"; case .mongo: "Collections"; case .redis: "Keys · first scan"; case .influx: "Measurements" } }
    var databaseLabel: String { self == .influx ? "Bucket" : "Database" }
    var initialDatabase: String { switch self { case .postgres: "postgres"; case .sqlServer: "master"; case .mongo: "admin"; case .redis: "0"; case .influx: "" } }
    func example(database: String) -> String {
        switch self {
        case .postgres: "SELECT current_database(), version();"
        case .sqlServer: "SELECT DB_NAME() AS database_name, @@VERSION AS version;"
        case .mongo: "{\n  \"find\": \"collection_name\",\n  \"filter\": {},\n  \"limit\": 100\n}"
        case .redis: "SCAN 0 COUNT 100"
        case .influx: "from(bucket: \(jsonString(database)))\n  |> range(start: -1h)\n  |> limit(n: 100)"
        }
    }
}
struct Server: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var engine: Engine = .postgres
    var host = "localhost"
    var port = 5432
    var username = ""
    var database = "postgres"
    var tls = true
    var organization = ""
    var authDatabase = "admin"
    var endpoint: String { "\(host):\(port)" }
}
struct QueryResult: Sendable {
    var columns: [String] = []
    var rows: [[String?]] = []
    var raw: String? = nil
    var affected: Int64 = 0
    var truncated = false
    var elapsed: TimeInterval = 0
    var message: String { columns.isEmpty ? "Completed · \(max(0, affected)) rows affected" : "\(rows.count.formatted()) rows · \(columns.count) columns" }
}
struct DBError: LocalizedError { let message: String; var errorDescription: String? { message }; init(_ message: String) { self.message = message } }
func jsonString(_ s: String) -> String { String(data: try! JSONEncoder().encode(s), encoding: .utf8)! }

enum Credentials {
    private static func attributes(_ id: UUID) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.dbcenter.credentials", kSecAttrAccount as String: id.uuidString] }
    static func save(_ password: String, for id: UUID) throws {
        let query = attributes(id)
        let data = Data(password.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked; status = SecItemAdd(item as CFDictionary, nil) }
        guard status == errSecSuccess else { throw DBError("Could not save credential in Keychain (\(status)).") }
    }
    static func read(_ id: UUID) throws -> String {
        var query = attributes(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data else { throw DBError("Could not read credential from Keychain (\(status)).") }
        return String(decoding: data, as: UTF8.self)
    }
    static func delete(_ id: UUID) { SecItemDelete(attributes(id) as CFDictionary) }
}

enum QueryParser {
    static func redisArguments(_ input: String) throws -> [String] {
        var args: [String] = [], word = "", quote: Character?, escaped = false, started = false
        for char in input {
            if escaped { word.append(char == "n" ? "\n" : char == "t" ? "\t" : char == "r" ? "\r" : char); escaped = false; started = true }
            else if char == "\\" { escaped = true; started = true }
            else if let active = quote { if char == active { quote = nil } else { word.append(char) } }
            else if char == "\"" || char == "'" { quote = char; started = true }
            else if char.isWhitespace { if started { args.append(word); word = ""; started = false } }
            else { word.append(char); started = true }
        }
        guard quote == nil && !escaped else { throw DBError("Unclosed quote or escape in Redis command.") }
        if started { args.append(word) }
        guard !args.isEmpty else { throw DBError("Enter a command first.") }
        return args
    }
    static func csv(_ text: String) throws -> QueryResult {
        var records: [[String]] = [], row: [String] = [], field = "", quoted = false
        let chars = Array(text); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { if quoted && i + 1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 } else { quoted.toggle() } }
            else if c == "," && !quoted { row.append(field); field = "" }
            else if (c == "\n" || c == "\r" || c == "\r\n") && !quoted { if c == "\r" && i + 1 < chars.count && chars[i+1] == "\n" { i += 1 }; row.append(field); records.append(row); row = []; field = "" }
            else { field.append(c) }; i += 1
        }
        guard !quoted else { throw DBError("Malformed CSV response: unclosed quoted field.") }
        if !field.isEmpty || !row.isEmpty { row.append(field); records.append(row) }
        var result = QueryResult(), header: [String] = [], defaults: [String] = []
        var wantsHeader = true
        for record in records {
            if record.allSatisfy({ $0.isEmpty }) { wantsHeader = true; continue }
            if record[0].hasPrefix("#") { if record[0] == "#default" { defaults = record }; wantsHeader = true; continue }
            if wantsHeader {
                header = record.enumerated().map { $0.element.isEmpty ? "column_\($0.offset)" : $0.element }
                for name in header where !result.columns.contains(name) { result.columns.append(name); for index in result.rows.indices { result.rows[index].append(nil) } }
                wantsHeader = false; continue
            }
            if record.enumerated().map({ $0.element.isEmpty ? "column_\($0.offset)" : $0.element }) == header { continue }
            if result.rows.count >= 10000 { result.truncated = true; continue }
            var values = [String?](repeating: nil, count: result.columns.count)
            for (index, name) in header.enumerated() where index < record.count {
                let value = record[index].isEmpty && index < defaults.count ? defaults[index] : record[index]
                values[result.columns.firstIndex(of: name)!] = value
            }
            result.rows.append(values)
        }
        result.raw = text; return result
    }
    static func mongo(_ text: String) throws -> QueryResult {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let dict = object as? [String: Any] ?? [:]
        let cursor = dict["cursor"] as? [String: Any]
        let documents = (cursor?["firstBatch"] ?? cursor?["nextBatch"]) as? [[String: Any]] ?? [dict]
        let columns = Array(Set(documents.flatMap { $0.keys })).sorted()
        func display(_ value: Any?) -> String? {
            guard let value, !(value is NSNull) else { return nil }
            if let string = value as? String { return string }
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), let string = String(data: data, encoding: .utf8) { return string }
            return String(describing: value)
        }
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return QueryResult(columns: columns, rows: documents.prefix(10000).map { doc in columns.map { display(doc[$0]) } }, raw: String(decoding: pretty, as: UTF8.self), truncated: documents.count > 10000 || ((cursor?["id"] as? NSNumber)?.int64Value ?? 0) != 0)
    }
}
