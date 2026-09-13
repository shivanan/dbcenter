import Foundation
import UniformTypeIdentifiers

enum ResultExportFormat: String, CaseIterable {
    case csv, json

    var contentType: UTType { self == .csv ? .commaSeparatedText : .json }

    func data(for result: QueryResult) throws -> Data {
        switch self {
        case .csv:
            func escape(_ value: String) -> String {
                "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            let records = [result.columns] + result.rows.map { $0.map { $0 ?? "" } }
            return Data(records.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n").utf8)
        case .json:
            // Positional rows preserve duplicate column names and column order.
            struct Document: Encodable {
                let columns: [String]
                let rows: [[String?]]
                let affectedRows: Int64
                let truncated: Bool
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(Document(columns: result.columns, rows: result.rows,
                                               affectedRows: result.affected, truncated: result.truncated))
        }
    }
}
