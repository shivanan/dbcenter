import SwiftUI

struct AIQueryPanel: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject private var settings: AISettings
    @FocusState private var promptFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                TextField("Describe the query you want…", text: $workspace.aiPrompt, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder).focused($promptFocused)
                    .onSubmit { workspace.generateAI(settings: settings) }
                    .accessibilityLabel("AI query request")
                if workspace.aiBusy {
                    ProgressView().controlSize(.small).padding(.top, 5)
                    Button("Cancel") { workspace.cancelAI() }
                } else {
                    Button("Generate") { workspace.generateAI(settings: settings) }
                        .buttonStyle(.borderedProminent)
                        .disabled(workspace.busy || !workspace.connected || workspace.aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                SettingsLink { Image(systemName: "gearshape") }.help("OpenAI settings ⌘,")
            }
            Text("Sends your prompt and this database’s table/field names to OpenAI. Generated code replaces the editor for review.")
                .font(.caption).foregroundStyle(.secondary)
            if workspace.server.engine == .mongo {
                Text("MongoDB field names are inferred from up to 20 documents per collection; document values are not sent.").font(.caption).foregroundStyle(.secondary)
            }
            if !workspace.connected { Text("Connect to a database to include its schema.").font(.caption).foregroundStyle(.secondary) }
            if let error = workspace.aiError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let message = workspace.aiMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let pending = workspace.pendingAIQuery {
                HStack {
                    Button("Insert Generated Query") { workspace.insertAIQuery(pending) }
                    Button("Discard") { workspace.pendingAIQuery = nil; workspace.aiMessage = nil }
                }
            } else if workspace.previousAIDraft != nil && !workspace.aiBusy {
                Button("Restore Previous Query") { workspace.restoreAIDraft() }.font(.caption).buttonStyle(.link)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.04))
        .onAppear { promptFocused = true }
    }
}
