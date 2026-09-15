import SwiftUI

struct ObjectDetailsView: View {
    @ObservedObject var workspace: Workspace
    let object: DatabaseObject
    @Environment(\.dismiss) private var dismiss
    @State private var sections: [ObjectDetailsSection] = []
    @State private var error: String?
    @State private var loading = true
    @State private var selectedSection = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(object.displayName).font(.title2.bold()).textSelection(.enabled)
                    Text("\(workspace.server.engine.rawValue) · \(workspace.database)").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            if loading { ProgressView("Loading details…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error {
                ContentUnavailableView("Couldn’t load details", systemImage: "exclamationmark.triangle", description: Text(error))
                Button("Try Again") { Task { await load() } }.padding(.bottom, 20)
            } else {
                Picker("Details", selection: $selectedSection) {
                    ForEach(sections) { section in Text(section.title).tag(section.id) }
                }.pickerStyle(.segmented).padding(16)
                if let section = sections.first(where: { $0.id == selectedSection }) {
                    if workspace.server.engine == .mongo, let raw = section.result.raw {
                        ScrollView([.vertical, .horizontal]) { Text(raw).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(16) }
                    } else if section.result.rows.isEmpty {
                        ContentUnavailableView("No details returned", systemImage: "info.circle", description: Text("The object may have been removed, have no fields, or be hidden by database permissions."))
                    } else { ResultGrid(result: section.result) }
                }
            }
        }.frame(width: 800, height: 480)
        .task { await load() }
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { sections = try await workspace.details(object); selectedSection = sections.first?.id ?? "" }
        catch { self.error = error.localizedDescription }
    }
}
