import SwiftUI

@MainActor final class Workspace: ObservableObject {
    let server: Server
    @Published var query: String
    @Published var database: String
    @Published var databases: [String] = []
    @Published var objects: [String] = []
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
        guard !busy, value != database, let driver else { return }; busy = true; error = nil
        defer { busy = false }
        do { try await driver.connect(database: value); database = value; result = nil; await loadObjects() }
        catch { self.error = error.localizedDescription; connected = false }
    }
    func refresh() async { guard connected, !busy else { return }; busy = true; await loadObjects(); busy = false }
    private func loadObjects() async {
        objects = []
        do { objects = try await driver?.objects(database: database) ?? []; metadataError = nil }
        catch { metadataError = error.localizedDescription }
    }
    func run() async {
        guard !busy, connected, let driver, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true; error = nil; let submitted = query; result = nil
        defer { busy = false }
        do { result = try await driver.execute(submitted, database: database); history.removeAll { $0 == submitted }; history.insert(submitted, at: 0); history = Array(history.prefix(30)) }
        catch { self.error = error.localizedDescription }
    }
    func disconnect() async { guard !busy else { return }; busy = true; await driver?.close(); driver = nil; connected = false; busy = false }
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
    func save(_ server: Server, password: String) async throws {
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
            await workspaces[server.id]?.disconnect(); workspaces.removeValue(forKey: server.id); Credentials.delete(server.id)
            servers = updated; if selected == server.id { selected = nil }
        } catch { self.error = error.localizedDescription }
    }
}
