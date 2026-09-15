import Foundation

enum QueryExecution {
    static func text(query: String, selection: NSRange) -> String {
        guard selection.length > 0 else { return query }
        let source = query as NSString
        // A stale selection must never cause the full query to run accidentally.
        guard selection.location != NSNotFound, selection.location >= 0,
              selection.length >= 0, selection.location <= source.length,
              selection.length <= source.length - selection.location else { return "" }
        return source.substring(with: selection)
    }
}
