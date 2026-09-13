import SwiftUI
import AppKit

enum WorkspaceFocusTarget: Hashable {
    case database, editor, tableSearch, results
}

/// Routes menu commands to the native controls in the active workspace only.
@MainActor final class WorkspaceFocus: ObservableObject {
    private struct Destination { weak var view: NSView? }
    private var destinations: [WorkspaceFocusTarget: Destination] = [:]
    private var pending: WorkspaceFocusTarget?

    func register(_ view: NSView, for target: WorkspaceFocusTarget) {
        destinations[target] = Destination(view: view)
        // Representables can update before their view is attached to the window.
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.destinations[target]?.view === view, self.pending == target else { return }
            self.apply(target)
        }
    }

    func request(_ target: WorkspaceFocusTarget) {
        pending = target
        apply(target)
    }

    private func apply(_ target: WorkspaceFocusTarget) {
        guard let view = destinations[target]?.view, let window = view.window,
              window.attachedSheet == nil,
              (view as? NSControl)?.isEnabled != false else { return }
        if window.makeFirstResponder(view) {
            if let field = view as? NSTextField { field.selectText(nil) }
            if let table = view as? ResultGrid.CopyTable, table.selectedCell == nil,
               !table.result.rows.isEmpty, !table.result.columns.isEmpty {
                table.selectCell(.init(row: 0, column: 0))
                table.scrollRowToVisible(0)
                table.scrollColumnToVisible(table.column(withIdentifier: NSUserInterfaceItemIdentifier("0")))
            }
            pending = nil
        }
    }
}

struct WorkspaceFocusActions {
    var database: (() -> Void)?
    var editor: () -> Void
    var tableSearch: () -> Void
    var results: (() -> Void)?
}
private struct WorkspaceFocusKey: FocusedValueKey {
    typealias Value = WorkspaceFocusActions
}
extension FocusedValues {
    var workspaceFocusActions: WorkspaceFocusActions? {
        get { self[WorkspaceFocusKey.self] }
        set { self[WorkspaceFocusKey.self] = newValue }
    }
}

struct WorkspaceFocusCommands: Commands {
    @FocusedValue(\.workspaceFocusActions) private var actions
    @ObservedObject var store: AppStore

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Focus Database Selector") { actions?.database?() }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(actions?.database == nil || store.editor != nil)
            Button("Focus Query Editor") { actions?.editor() }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(actions == nil || store.editor != nil)
            Button("Focus Table Search") { actions?.tableSearch() }
                .keyboardShortcut("3", modifiers: [.command, .option])
                .disabled(actions == nil || store.editor != nil)
            Button("Focus Result Grid") { actions?.results?() }
                .keyboardShortcut("4", modifiers: [.command, .option])
                .disabled(actions?.results == nil || store.editor != nil)
        }
    }
}

struct TableSearchField: NSViewRepresentable {
    @Binding var text: String
    let focus: WorkspaceFocus

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Filter tables / objects"
        field.setAccessibilityLabel("Table search")
        field.toolTip = "Focus table search ⌥⌘3"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        focus.register(field, for: .tableSearch)
    }
    class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: TableSearchField
        init(_ parent: TableSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }
    }
}
