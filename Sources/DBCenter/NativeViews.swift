import SwiftUI
import AppKit

struct QueryEditor: NSViewRepresentable {
    @Binding var text: String
    var run: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.drawsBackground = true
        let editor = EditorTextView(); editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false; editor.isContinuousSpellCheckingEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular); editor.textColor = .textColor; editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 20, height: 18); editor.allowsUndo = true; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = false; editor.textContainer?.containerSize = NSSize(width: 100000, height: 100000)
        editor.minSize = NSSize(width: 0, height: 0); editor.maxSize = NSSize(width: 100000, height: 100000)
        editor.delegate = context.coordinator; editor.run = run; editor.string = text; editor.setAccessibilityLabel("Query editor")
        scroll.documentView = editor; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? EditorTextView else { return }
        editor.run = run
        if editor.string != text { editor.string = text }
    }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: QueryEditor
        init(_ parent: QueryEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let editor = notification.object as? NSTextView { parent.text = editor.string } }
    }
    class EditorTextView: NSTextView {
        var run: (() -> Void)?
        override func keyDown(with event: NSEvent) { if event.modifierFlags.contains(.command) && event.keyCode == 36 { run?() } else { super.keyDown(with: event) } }
    }
}

struct ResultGrid: NSViewRepresentable {
    var result: QueryResult
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let table = CopyTable(); table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 27; table.intercellSpacing = NSSize(width: 12, height: 0)
        table.gridStyleMask = [.solidVerticalGridLineMask]; table.allowsMultipleSelection = true; table.columnAutoresizingStyle = .noColumnAutoresizing
        table.delegate = context.coordinator; table.dataSource = context.coordinator; table.setAccessibilityLabel("Query results")
        scroll.documentView = table; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? CopyTable else { return }
        context.coordinator.result = result; table.result = result
        if table.tableColumns.map(\.title) != ["#"] + result.columns {
            for column in table.tableColumns { table.removeTableColumn(column) }
            for (index, name) in (["#"] + result.columns).enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index-1))); column.title = name
                column.width = index == 0 ? 48 : max(145, min(300, CGFloat(name.count) * 9 + 32)); column.minWidth = 40; table.addTableColumn(column)
            }
        }
        table.reloadData()
    }
    class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var result = QueryResult()
        func numberOfRows(in tableView: NSTableView) -> Int { result.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, let col = Int(id.rawValue), row < result.rows.count else { return nil }
            let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
            field.identifier = id; field.font = .monospacedSystemFont(ofSize: 12, weight: .regular); field.lineBreakMode = .byTruncatingTail
            let value: String? = col < 0 ? String(row+1) : result.rows[row][col]
            field.stringValue = value ?? "NULL"; field.textColor = value == nil || col < 0 ? .secondaryLabelColor : .labelColor; field.toolTip = value ?? "NULL"
            return field
        }
    }
    class CopyTable: NSTableView {
        var result = QueryResult()
        @objc func copy(_ sender: Any?) {
            let rows = selectedRowIndexes.isEmpty ? Array(result.rows.indices) : Array(selectedRowIndexes)
            let text = ([result.columns] + rows.filter { $0 < result.rows.count }.map { result.rows[$0].map { $0 ?? "NULL" } }).map { $0.joined(separator: "\t") }.joined(separator: "\n")
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

struct DatabaseCombo: NSViewRepresentable {
    var value: String
    var options: [String]
    var enabled: Bool
    var change: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox(); combo.completes = true; combo.numberOfVisibleItems = 12; combo.delegate = context.coordinator
        combo.target = context.coordinator; combo.action = #selector(Coordinator.commit(_:)); combo.setAccessibilityLabel("Database"); return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if combo.objectValues.compactMap({ $0 as? String }) != options { combo.removeAllItems(); combo.addItems(withObjectValues: options) }
        if combo.currentEditor() == nil { combo.stringValue = value }; combo.isEnabled = enabled
    }
    class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: DatabaseCombo
        init(_ parent: DatabaseCombo) { self.parent = parent }
        @objc func commit(_ combo: NSComboBox) { let value = combo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { parent.change(value) } }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard let combo = notification.object as? NSComboBox, let item = combo.objectValueOfSelectedItem as? String else { return }; parent.change(item) }
    }
}
