import SwiftUI
import AppKit

struct QueryEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var engine: Engine = .postgres
    var focus: WorkspaceFocus? = nil
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
        editor.run = run; editor.string = text; editor.setSelectedRange(selection)
        editor.delegate = context.coordinator; editor.setAccessibilityLabel("Query editor")
        scroll.documentView = editor; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? EditorTextView else { return }
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        editor.run = run
        focus?.register(editor, for: .editor)
        editor.toolTip = "Focus query editor ⌥⌘2"
        if editor.string != text { editor.string = text }
        if editor.selectedRange() != selection { editor.setSelectedRange(selection) }
        editor.scheduleHighlighting(engine: engine)
    }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: QueryEditor
        var isUpdating = false
        init(_ parent: QueryEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if !isUpdating, let editor = notification.object as? EditorTextView {
                let selected = editor.selectedRange()
                parent.text = editor.string
                parent.selection = selected
                editor.scheduleHighlighting(engine: parent.engine)
            }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let editor = notification.object as? EditorTextView,
                  editor.string == parent.text else { return }
            if parent.selection != editor.selectedRange() { parent.selection = editor.selectedRange() }
        }
    }
    class EditorTextView: NSTextView {
        var run: (() -> Void)?
        private var highlightTask: Task<Void, Never>?
        private var requestedText: String?
        private var requestedEngine: Engine?

        deinit { highlightTask?.cancel() }

        func scheduleHighlighting(engine: Engine) {
            let snapshot = string
            guard requestedText != snapshot || requestedEngine != engine else { return }
            requestedText = snapshot; requestedEngine = engine
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                let tokens = await Task.detached(priority: .userInitiated) {
                    SyntaxHighlighter.tokens(in: snapshot, engine: engine)
                }.value
                guard !Task.isCancelled, let self, self.string == snapshot, self.requestedEngine == engine else { return }
                self.applyHighlighting(tokens)
            }
        }

        func applyHighlighting(_ tokens: [SyntaxHighlighter.Token]) {
            guard let layoutManager else { return }
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (string as NSString).length))
            for token in tokens {
                let color: NSColor
                switch token.kind {
                case .keyword: color = .systemPurple
                case .string: color = .systemRed
                case .comment: color = .secondaryLabelColor
                case .number: color = .systemBlue
                case .identifier: color = .systemTeal
                }
                layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
            }
        }

        override func keyDown(with event: NSEvent) { if event.modifierFlags.contains(.command) && event.keyCode == 36 { run?() } else { super.keyDown(with: event) } }
    }
}

struct ResultGrid: NSViewRepresentable {
    var result: QueryResult
    var focus: WorkspaceFocus? = nil
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
        focus?.register(table, for: .results)
        table.toolTip = "Focus result grid ⌥⌘4"
    }
    class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var result = QueryResult()
        func numberOfRows(in tableView: NSTableView) -> Int { result.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, let col = Int(id.rawValue), row < result.rows.count else { return nil }
            let field = (tableView.makeView(withIdentifier: id, owner: self) as? ResultCellField) ?? ResultCellField(labelWithString: "")
            field.identifier = id; field.font = .monospacedSystemFont(ofSize: 12, weight: .regular); field.lineBreakMode = .byTruncatingTail
            let value: String? = col < 0 ? String(row+1) : result.rows[row][col]
            field.stringValue = value ?? "NULL"; field.textColor = value == nil || col < 0 ? .secondaryLabelColor : .labelColor; field.toolTip = value ?? "NULL"
            field.isCellSelected = (tableView as? CopyTable)?.selectedCell == ResultCell(row: row, column: col)
            return field
        }
    }
    struct ResultCell: Equatable {
        let row: Int
        let column: Int
    }
    class ResultCellField: NSTextField {
        var isCellSelected = false {
            didSet {
                wantsLayer = true
                layer?.cornerRadius = 3
                layer?.borderWidth = isCellSelected ? 1 : 0
                layer?.borderColor = NSColor.controlAccentColor.cgColor
                drawsBackground = isCellSelected
                backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15)
                setAccessibilitySelected(isCellSelected)
            }
        }
        // Let the table own cell selection and the Copy responder action.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    class CopyTable: NSTableView {
        var result = QueryResult() {
            didSet { if oldValue != result { selectCell(nil) } }
        }
        private(set) var selectedCell: ResultCell?

        func selectCell(_ cell: ResultCell?) {
            let previous = selectedCell
            selectedCell = cell.flatMap {
                result.rows.indices.contains($0.row) && result.rows[$0.row].indices.contains($0.column) ? $0 : nil
            }
            selectionHighlightStyle = selectedCell == nil ? .regular : .none
            if selectedCell != nil { deselectAll(nil) }
            for candidate in [previous, selectedCell].compactMap({ $0 }) {
                let column = column(withIdentifier: NSUserInterfaceItemIdentifier(String(candidate.column)))
                guard column >= 0, candidate.row < numberOfRows else { continue }
                (view(atColumn: column, row: candidate.row, makeIfNecessary: false) as? ResultCellField)?.isCellSelected = candidate == selectedCell
            }
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let row = row(at: point), column = column(at: point)
            let extendingRows = !event.modifierFlags.intersection([.shift, .command]).isEmpty
            if row >= 0, column >= 0,
               let index = Int(tableColumns[column].identifier.rawValue), index >= 0, !extendingRows {
                selectCell(ResultCell(row: row, column: index))
                window?.makeFirstResponder(self)
            } else {
                selectCell(nil)
                super.mouseDown(with: event)
            }
        }

        override func keyDown(with event: NSEvent) {
            guard let cell = selectedCell,
                  event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty,
                  [123, 124, 125, 126].contains(event.keyCode) else {
                if !event.modifierFlags.contains(.command) { selectCell(nil) }
                super.keyDown(with: event)
                return
            }
            let visibleColumn = column(withIdentifier: NSUserInterfaceItemIdentifier(String(cell.column)))
            let nextColumn = min(max(visibleColumn + (event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : 0), 0), tableColumns.count - 1)
            let nextRow = min(max(cell.row + (event.keyCode == 126 ? -1 : event.keyCode == 125 ? 1 : 0), 0), result.rows.count - 1)
            guard let index = Int(tableColumns[nextColumn].identifier.rawValue), index >= 0 else { return }
            selectCell(ResultCell(row: nextRow, column: index))
            scrollRowToVisible(nextRow); scrollColumnToVisible(nextColumn)
        }

        override func selectAll(_ sender: Any?) {
            selectCell(nil)
            super.selectAll(sender)
        }

        var copyText: String {
            if let cell = selectedCell {
                return result.rows[cell.row][cell.column] ?? "NULL"
            }
            let rows = selectedRowIndexes.isEmpty ? Array(result.rows.indices) : Array(selectedRowIndexes)
            return ([result.columns] + rows.filter { $0 < result.rows.count }.map { result.rows[$0].map { $0 ?? "NULL" } }).map { $0.joined(separator: "\t") }.joined(separator: "\n")
        }
        @objc func copy(_ sender: Any?) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copyText, forType: .string)
        }
    }
}

struct DatabaseCombo: NSViewRepresentable {
    var value: String
    var options: [String]
    var enabled: Bool
    var focus: WorkspaceFocus? = nil
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
        focus?.register(combo, for: .database)
        combo.toolTip = "Focus database selector ⌥⌘1"
    }
    class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: DatabaseCombo
        init(_ parent: DatabaseCombo) { self.parent = parent }
        @objc func commit(_ combo: NSComboBox) { let value = combo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { parent.change(value) } }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard let combo = notification.object as? NSComboBox, let item = combo.objectValueOfSelectedItem as? String else { return }; parent.change(item) }
    }
}
