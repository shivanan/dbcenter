import SwiftUI
import Security

@MainActor final class AISettings: ObservableObject {
    @Published private(set) var model: String
    @Published var availableModels: [String]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = defaults.string(forKey: "openAI.model") ?? ""
        availableModels = defaults.stringArray(forKey: "openAI.models") ?? []
    }
    func save(key: String, model: String) throws {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw DBError("Select or enter a model ID.") }
        try AIKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
        self.model = model; defaults.set(model, forKey: "openAI.model")
    }
    func cacheModels(_ models: [String]) { availableModels = models; defaults.set(models, forKey: "openAI.models") }
}

enum AIKeychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.dbcenter.openai", kSecAttrAccount as String: "api-key"] }
    static func read() throws -> String {
        var attributes = query; attributes[kSecReturnData as String] = true; attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?; let status = SecItemCopyMatching(attributes as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data else { throw DBError("Could not read the OpenAI key from Keychain (\(status)).") }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ key: String) throws {
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw DBError("Could not remove the OpenAI key (\(status)).") }; return
        }
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query; attributes[kSecValueData as String] = data; attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DBError("Could not save the OpenAI key in Keychain (\(status)).") }
    }
}

struct AISettingsView: View {
    @EnvironmentObject var settings: AISettings
    @State private var key = ""
    @State private var model = ""
    @State private var loaded = false
    @State private var loadingModels = false
    @State private var message: String?
    @State private var error: String?
    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("API key", text: $key)
                Text("Stored in macOS Keychain. Clear the field and save to remove the key.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Model") { AIModelPicker(value: $model, options: settings.availableModels).frame(width: 300, height: 26) }
                HStack {
                    Button(loadingModels ? "Loading…" : "Load Available Models") { loadModels() }.disabled(key.isEmpty || loadingModels || !loaded)
                    Spacer()
                    Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(!loaded || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loadingModels)
                }
                Text("Choose a model that supports text generation through the Responses API, or type its model ID. The API model list can include non-text models.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Query generation") {
                Text("Generate sends your prompt, database name, and schema names to OpenAI. Record values, connection credentials, and existing editor text are not sent. Review the generated query before running it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let message { Text(message).foregroundStyle(.secondary) }
        }.formStyle(.grouped).frame(width: 560, height: 410)
        .task {
            model = settings.model
            do { key = try AIKeychain.read(); loaded = true } catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        error = nil; message = nil
        do { try settings.save(key: key, model: model); message = "Settings saved." } catch { self.error = error.localizedDescription }
    }
    private func loadModels() {
        loadingModels = true; error = nil; message = nil
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { loadingModels = false }
            do { settings.cacheModels(try await OpenAIClient().models(key: key)); message = "Models loaded. Select a text model and save." }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct AIModelPicker: NSViewRepresentable {
    @Binding var value: String
    let options: [String]
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox(); combo.completes = true; combo.delegate = context.coordinator
        combo.setAccessibilityLabel("OpenAI model"); return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if combo.objectValues.compactMap({ $0 as? String }) != options { combo.removeAllItems(); combo.addItems(withObjectValues: options) }
        if combo.stringValue != value { combo.stringValue = value }
    }
    class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: AIModelPicker
        init(_ parent: AIModelPicker) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) { if let combo = notification.object as? NSComboBox { parent.value = combo.stringValue } }
        func comboBoxSelectionDidChange(_ notification: Notification) { if let combo = notification.object as? NSComboBox, let value = combo.objectValueOfSelectedItem as? String { parent.value = value } }
    }
}
