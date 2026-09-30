import SwiftUI

@MainActor final class Workspace: ObservableObject {
    let server: Server
    @Published var query: String {
        didSet { if oldValue != query { queryRevision += 1; querySelection = NSRange(location: 0, length: 0) } }
    }
    private(set) var queryRevision = 0
    @Published var aiExpanded = false
    @Published var aiPrompt = ""
    @Published var aiBusy = false
    @Published var aiMessage: String?
    @Published var aiError: String?
    @Published var pendingAIQuery: String?
    @Published var previousAIDraft: String?
    private var aiTask: Task<Void, Never>?
    private var aiRequestID: UUID?
    @Published var querySelection = NSRange(location: 0, length: 0)
    var executionText: String { QueryExecution.text(query: query, selection: querySelection) }
    @Published var database: String
    @Published var databases: [String] = []
    @Published var objects: [DatabaseObject] = []
    @Published var resultTitle = "Results"
    @Published var previewID = UUID()
    @Published var result: QueryResult?
    @Published var error: String?
    @Published var metadataError: String?
    @Published var busy = false
    @Published var connected = false
    @Published var history: [String] = []
    private var driver: DatabaseDriver?
    init(server: Server) { self.server = server; database = server.database; query = server.engine.example(database: server.database) }
    func connect() async {
        guard !busy && !connected else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            let driver = try DatabaseDriver(server: server, password: Credentials.read(server.id)); self.driver = driver
            try await driver.connect(database: database); connected = true
            do {
                databases = try await driver.databases()
                if database.isEmpty, let first = databases.first { database = first; query = server.engine.example(database: first) }
                if !databases.contains(database) && !database.isEmpty { databases.insert(database, at: 0) }
            } catch { databases = [database]; metadataError = "Database discovery: \(error.localizedDescription)" }
            await loadObjects()
        } catch { self.error = error.localizedDescription; connected = false; await driver?.close(); driver = nil }
    }
    func switchDatabase(_ value: String) async {
        guard !busy, value != database, let driver else { return }; cancelAI(); busy = true; error = nil
        defer { busy = false }
        do { try await driver.connect(database: value); database = value; result = nil; await loadObjects() }
        catch { self.error = error.localizedDescription; connected = false; await driver.close(); self.driver = nil }
    }
    func refresh() async { guard connected, !busy else { return }; busy = true; await loadObjects(); busy = false }
    private func loadObjects() async {
        objects = []
        do { objects = try await driver?.catalogObjects(database: database) ?? []; metadataError = nil }
        catch { metadataError = error.localizedDescription }
    }
    func run() async {
        let submitted = executionText
        guard !busy, connected, let driver, !submitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true; error = nil; result = nil; resultTitle = "Results"
        defer { busy = false }
        do { result = try await driver.execute(submitted, database: database); history.removeAll { $0 == submitted }; history.insert(submitted, at: 0); history = Array(history.prefix(30)) }
        catch { self.error = error.localizedDescription }
    }
    func preview(_ object: DatabaseObject) async {
        guard !busy, connected, let driver else { return }
        busy = true; error = nil; result = nil
        resultTitle = "Preview · \(object.displayName)"; previewID = UUID()
        defer { busy = false }
        do {
            let preview = try await driver.previewObject(object, database: database)
            result = preview.result
            history.removeAll { $0 == preview.query }; history.insert(preview.query, at: 0)
            history = Array(history.prefix(30))
        } catch { self.error = error.localizedDescription }
    }
    func details(_ object: DatabaseObject) async throws -> [ObjectDetailsSection] {
        guard !busy, connected, let driver else { throw DBError("Connect and wait for the current operation to finish.") }
        busy = true
        defer { busy = false }
        return try await driver.objectDetails(object, database: database)
    }
    func generateAI(settings: AISettings) {
        guard !aiBusy, !busy, connected, let driver else { return }
        aiError = nil; aiMessage = nil; pendingAIQuery = nil
        let key: String
        do {
            key = try AIKeychain.read()
            guard !key.isEmpty else { throw DBError("Add your OpenAI API key in Settings (⌘,).") }
            guard !settings.model.isEmpty else { throw DBError("Choose an OpenAI model in Settings (⌘,).") }
            guard !aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        } catch { aiError = error.localizedDescription; return }
        let requestID = UUID(), database = database, revision = queryRevision
        let prompt = aiPrompt, model = settings.model
        aiRequestID = requestID; aiBusy = true
        aiTask = Task {
            defer { if aiRequestID == requestID { aiBusy = false; aiTask = nil; aiRequestID = nil } }
            do {
                aiMessage = "Reading database schema…"
                let schema: AISchema
                busy = true
                do { schema = try await driver.aiSchema(database: database); busy = false }
                catch { busy = false; throw error }
                try Task.checkCancellation()
                aiMessage = "Generating with \(model) · \(schema.objects.count) objects…"
                let generated = try await OpenAIClient().generate(key: key, model: model, prompt: prompt, schema: schema)
                try Task.checkCancellation()
                guard aiRequestID == requestID, self.database == database, connected else { return }
                receiveAIQuery(generated, originalRevision: revision)
            } catch {
                guard aiRequestID == requestID else { return }
                aiMessage = nil
                if !Task.isCancelled { aiError = error.localizedDescription }
            }
        }
    }
    func receiveAIQuery(_ code: String, originalRevision: Int) {
        if queryRevision != originalRevision {
            pendingAIQuery = code
            aiMessage = "Your editor changed during generation. Insert the generated query when ready."
        } else { insertAIQuery(code) }
    }
    func insertAIQuery(_ code: String) {
        previousAIDraft = query
        query = code
        querySelection = NSRange(location: 0, length: (code as NSString).length)
        pendingAIQuery = nil
        aiMessage = "Query inserted. Review it, then use Run Query to execute."
    }
    func restoreAIDraft() {
        guard let previousAIDraft else { return }
        query = previousAIDraft; self.previousAIDraft = nil; aiMessage = "Previous query restored."
    }
    func cancelAI() {
        aiTask?.cancel(); aiTask = nil; aiRequestID = nil; aiBusy = false
        pendingAIQuery = nil; aiMessage = nil
    }
    func disconnect() async { guard !busy else { return }; cancelAI(); busy = true; await driver?.close(); driver = nil; connected = false; busy = false }
}

@MainActor final class AppStore: ObservableObject {
    @Published var servers: [Server] = []
    @Published var selected: UUID?
    @Published var editor: Server?
    @Published var error: String?
    @Published var workspaces: [UUID: Workspace] = [:]
    private let file: URL
    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DBCenter")
        file = root.appendingPathComponent("servers.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) { servers = try JSONDecoder().decode([Server].self, from: Data(contentsOf: file)) }
        } catch { self.error = "Could not load saved servers: \(error.localizedDescription)" }
    }
    func workspace(for server: Server) -> Workspace {
        if let workspace = workspaces[server.id] { return workspace }
        let workspace = Workspace(server: server); workspaces[server.id] = workspace; return workspace
    }
    func select(_ server: Server) { let workspace = workspace(for: server); selected = server.id; Task { await workspace.connect() } }
    func save(_ server: Server, password: String, sshSecret: String = "") async throws {
        if let ssh = server.ssh, ssh.enabled { try ssh.validate(destination: server.host, port: server.port) }
        if server.ssh?.enabled == true && (sshSecret.contains("\n") || sshSecret.contains("\r")) { throw DBError("SSH passwords and passphrases must not contain line breaks.") }
        try Credentials.save(sshSecret, for: server.id, ssh: true)
        try Credentials.save(password, for: server.id)
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == server.id }) { updated[index] = server } else { updated.append(server) }
        try JSONEncoder().encode(updated).write(to: file, options: [.atomic])
        if let old = workspaces[server.id] { await old.disconnect() }
        workspaces.removeValue(forKey: server.id); servers = updated; editor = nil; select(server)
    }
    func remove(_ server: Server) async {
        do {
            let updated = servers.filter { $0.id != server.id }
            try JSONEncoder().encode(updated).write(to: file, options: [.atomic])
            await workspaces[server.id]?.disconnect(); workspaces.removeValue(forKey: server.id); Credentials.delete(server.id); Credentials.delete(server.id, ssh: true)
            servers = updated; if selected == server.id { selected = nil }
        } catch { self.error = error.localizedDescription }
    }
}
