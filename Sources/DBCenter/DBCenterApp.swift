import SwiftUI

struct DBCenterApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var aiSettings = AISettings()
    var body: some Scene {
        Window("DB Center", id: "main") {
            ContentView().environmentObject(store).environmentObject(aiSettings).frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            WorkspaceFocusCommands(store: store)
            CommandGroup(after: .newItem) {
                Button("New Connection…") { store.editor = Server() }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Query") {
                Button("Run Query") { if let id = store.selected, let workspace = store.workspaces[id] { Task { await workspace.run() } } }.keyboardShortcut(.return, modifiers: .command)
                Button("Refresh Database") { if let id = store.selected, let workspace = store.workspaces[id] { Task { await workspace.refresh() } } }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        Settings { AISettingsView().environmentObject(aiSettings) }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @State private var showInspector = true
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(get: { store.selected }, set: { id in if let server = store.servers.first(where: { $0.id == id }) { store.select(server) } })) {
                    Section("Connections") {
                        ForEach(store.servers.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.engine.rawValue.localizedCaseInsensitiveContains(search) }) { server in
                            ServerRow(server: server, workspace: store.workspaces[server.id]).tag(server.id)
                                .contextMenu {
                                    Button("Edit Connection…") { store.editor = server }.disabled(store.workspaces[server.id]?.busy == true)
                                    Button("Disconnect") { Task { await store.workspaces[server.id]?.disconnect() } }.disabled(store.workspaces[server.id]?.busy == true)
                                    Divider()
                                    Button("Remove Connection", role: .destructive) { Task { await store.remove(server) } }.disabled(store.workspaces[server.id]?.busy == true)
                                }
                        }
                    }
                }.listStyle(.sidebar).searchable(text: $search, placement: .sidebar, prompt: "Find a connection")
                Divider()
                HStack {
                    Button { store.editor = Server() } label: { Label("New Connection", systemImage: "plus") }.buttonStyle(.borderless)
                    Spacer()
                    Text("\(store.servers.count)").foregroundStyle(.tertiary).monospacedDigit()
                }.padding(14)
            }.navigationSplitViewColumnWidth(min: 210, ideal: 245, max: 340)
        } detail: {
            if let id = store.selected, let workspace = store.workspaces[id] {
                WorkspaceView(workspace: workspace, showInspector: $showInspector).id(id)
            } else { WelcomeView() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { store.editor = Server() } label: { Label("New Connection", systemImage: "plus") }.help("New connection ⇧⌘N") }
            ToolbarItem(placement: .primaryAction) { Button { showInspector.toggle() } label: { Label("Database Inspector", systemImage: "sidebar.right") }.help("Toggle database inspector") }
        }
        .sheet(item: $store.editor) { server in ConnectionSheet(server: server).environmentObject(store) }
        .alert("DB Center", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
}
struct ServerRow: View {
    let server: Server
    var workspace: Workspace?
    var body: some View {
        HStack(spacing: 10) {
            EngineIcon(engine: server.engine, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name).fontWeight(.medium).lineLimit(1)
                Text(server.engine.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let workspace { ConnectionDot(workspace: workspace) }
        }.padding(.vertical, 5)
    }
}
struct ConnectionDot: View {
    @ObservedObject var workspace: Workspace
    var body: some View { Circle().fill(workspace.busy ? Color.orange : workspace.connected ? Color.green : Color.gray.opacity(0.4)).frame(width: 6, height: 6).help(workspace.busy ? "Working" : workspace.connected ? "Connected" : "Disconnected") }
}
struct EngineIcon: View {
    let engine: Engine
    var size: CGFloat = 36
    var body: some View { Image(systemName: engine.symbol).font(.system(size: size * 0.47, weight: .medium)).foregroundStyle(engine.color).frame(width: size, height: size).background(engine.color.opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.23)) }
}
struct WelcomeView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 52, weight: .light)).foregroundStyle(.tint).padding(.bottom, 26)
            Text("Every database. One workspace.").font(.system(size: 29, weight: .semibold, design: .rounded))
            Text("Connect, explore, and query — right at home on your Mac.").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 12)
            Button { store.editor = Server() } label: { Label("Add a Connection", systemImage: "plus").padding(.horizontal, 10).padding(.vertical, 4) }.buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 30)
            HStack(spacing: 24) {
                ForEach(Engine.allCases) { engine in
                    Button { var s = Server(); s.engine = engine; s.port = engine.port; s.database = engine.initialDatabase; s.tls = engine != .redis; store.editor = s } label: {
                        VStack(spacing: 10) { EngineIcon(engine: engine, size: 42); Text(engine.rawValue).font(.caption).foregroundStyle(.secondary) }.frame(width: 76)
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 48)
            Spacer()
            HStack(spacing: 6) { Image(systemName: "lock.shield"); Text("Credentials stored securely in macOS Keychain") }.font(.caption).foregroundStyle(.tertiary).padding(.bottom, 26)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var aiSettings: AISettings
    @ObservedObject var workspace: Workspace
    @Binding var showInspector: Bool
    @State private var resultMode = "Grid"
    @StateObject private var focus = WorkspaceFocus()
    @State private var objectSearch = ""
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    EngineIcon(engine: workspace.server.engine)
                    VStack(alignment: .leading, spacing: 3) { Text(workspace.server.name).font(.headline); Text(workspace.server.endpoint).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(workspace.server.engine.databaseLabel).font(.caption).foregroundStyle(.secondary)
                    DatabaseCombo(value: workspace.database, options: workspace.databases, enabled: workspace.connected && !workspace.busy, focus: focus) { value in Task { await workspace.switchDatabase(value) } }.frame(width: 180, height: 26)
                }.padding(18)
                Divider()
                VSplitView {
                    VStack(spacing: 0) {
                        HStack {
                            Label("Query", systemImage: "chevron.left.forwardslash.chevron.right").font(.system(size: 12, weight: .semibold))
                            Text(workspace.server.engine.language).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule())
                            Spacer()
                            Menu { ForEach(Array(workspace.history.enumerated()), id: \.offset) { _, query in Button(String(query.prefix(90))) { workspace.query = query } } } label: { Image(systemName: "clock.arrow.circlepath") }.menuStyle(.borderlessButton).frame(width: 24).disabled(workspace.history.isEmpty).help("Query history for this session")
                            Button { withAnimation { workspace.aiExpanded.toggle() } } label: { Label("AI", systemImage: "sparkles") }
                                .help("Generate a query with OpenAI").tint(workspace.aiExpanded ? .accentColor : nil)
                            if workspace.connected {
                                Button { Task { await workspace.run() } } label: { Label(workspace.busy ? "Running…" : workspace.querySelection.length > 0 ? "Run Selection" : "Run Query", systemImage: "play.fill") }.buttonStyle(.borderedProminent).disabled(workspace.busy || workspace.executionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).help("Run selected text, or the entire query if nothing is selected ⌘↩")
                            } else { Button("Connect") { Task { await workspace.connect() } }.buttonStyle(.borderedProminent).disabled(workspace.busy) }
                        }.padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
                        Divider()
                        if workspace.aiExpanded {
                            AIQueryPanel(workspace: workspace).environmentObject(aiSettings)
                            Divider()
                        }
                        QueryEditor(text: $workspace.query, selection: $workspace.querySelection, engine: workspace.server.engine, focus: focus) { Task { await workspace.run() } }
                        HStack { Text("\(workspace.query.components(separatedBy: "\n").count) lines"); Spacer(); Text(workspace.querySelection.length > 0 ? "⌘ ↩  Run selection" : "⌘ ↩  Run query") }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 18).padding(.vertical, 6)
                    }.frame(minHeight: 180, idealHeight: 300)
                    VStack(spacing: 0) {
                        HStack {
                            Label(workspace.resultTitle, systemImage: "tablecells").lineLimit(1).font(.system(size: 12, weight: .semibold))
                            if let result = workspace.result { Text(result.message).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if workspace.result?.raw != nil { Picker("Result format", selection: $resultMode) { Text("Grid").tag("Grid"); Text("Raw").tag("Raw") }.pickerStyle(.segmented).labelsHidden().frame(width: 115) }
                            Menu {
                                ForEach(ResultExportFormat.allCases, id: \.self) { format in
                                    Button("Export as \(format.rawValue.uppercased())…") { export(format) }
                                }
                            } label: { Image(systemName: "square.and.arrow.up") }
                            .menuStyle(.borderlessButton).fixedSize().disabled(workspace.result == nil)
                            .help("Export results as CSV or JSON").accessibilityLabel("Export results")
                        }.padding(.horizontal, 16).padding(.vertical, 11).background(.bar)
                        Divider()
                        if let error = workspace.error {
                            ScrollView { VStack(alignment: .leading, spacing: 12) { Label("Couldn’t complete the request", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange); Text(error).font(.system(size: 12, design: .monospaced)).textSelection(.enabled); if !workspace.connected { Button("Try Again") { Task { await workspace.connect() } }.disabled(workspace.busy) } }.frame(maxWidth: .infinity, alignment: .leading).padding(24) }
                        } else if workspace.busy {
                            VStack(spacing: 12) { ProgressView().controlSize(.small); Text(workspace.connected ? "Working on your request…" : "Connecting to server…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let result = workspace.result {
                            if resultMode == "Raw", let raw = result.raw { ScrollView([.horizontal, .vertical]) { Text(raw).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(16).frame(maxWidth: .infinity, alignment: .leading) } }
                            else if result.columns.isEmpty { ContentUnavailableView("Command completed", systemImage: "checkmark.circle", description: Text(result.message)) }
                            else { ResultGrid(result: result, focus: focus) }
                        } else {
                            ContentUnavailableView("Ready when you are", systemImage: "text.cursor", description: Text("Write a \(workspace.server.engine.language) query above.\nYour results will appear here."))
                        }
                    }.frame(minHeight: 190)
                }
                Divider()
                HStack(spacing: 7) {
                    ConnectionDot(workspace: workspace)
                    Text(workspace.busy ? "Working" : workspace.connected ? "Connected" : "Disconnected")
                    Text("·").foregroundStyle(.tertiary); Text(workspace.server.engine.rawValue)
                    Spacer()
                    if workspace.result?.truncated == true { Text("Partial results — narrow query or fetch next batch").foregroundStyle(.orange) }
                    if let result = workspace.result { Text(String(format: "%.3f s", result.elapsed)).monospacedDigit() }
                    if workspace.connected { Button("Disconnect") { Task { await workspace.disconnect() } }.buttonStyle(.borderless).disabled(workspace.busy) }
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9).background(.bar)
            }.frame(maxWidth: .infinity)
            if showInspector { Divider(); InspectorView(workspace: workspace, search: $objectSearch, focus: focus).frame(width: 255) }
        }.navigationTitle(workspace.server.name).background(Color(nsColor: .textBackgroundColor))
        .onDisappear { workspace.cancelAI() }
        .onChange(of: workspace.previewID) { _, _ in resultMode = "Grid" }
        .focusedSceneValue(\.workspaceFocusActions, WorkspaceFocusActions(
            database: workspace.connected && !workspace.busy ? { focus.request(.database) } : nil,
            editor: { focus.request(.editor) },
            tableSearch: { showInspector = true; focus.request(.tableSearch) },
            results: workspace.result?.columns.isEmpty == false && !workspace.busy && workspace.error == nil
                ? { resultMode = "Grid"; focus.request(.results) } : nil
        ))
    }
    private func export(_ format: ResultExportFormat) {
        guard let result = workspace.result else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "query-results.\(format.rawValue)"; panel.allowedContentTypes = [format.contentType]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try format.data(for: result).write(to: url, options: .atomic) } catch { workspace.error = "Export failed: \(error.localizedDescription)" }
        }
    }
}

struct InspectorView: View {
    @State private var detailObject: DatabaseObject?
    @ObservedObject var workspace: Workspace
    @Binding var search: String
    let focus: WorkspaceFocus
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Database Inspector").font(.system(size: 12, weight: .semibold)); Spacer(); Button { Task { await workspace.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).disabled(workspace.busy || !workspace.connected).help("Refresh objects") }.padding(17)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Label(workspace.database.isEmpty ? "No database selected" : workspace.database, systemImage: "cylinder").font(.headline).textSelection(.enabled)
                info("Engine", workspace.server.engine.rawValue)
                info("Host", workspace.server.host)
                info("Port", String(workspace.server.port))
                info("Transport", workspace.server.tls ? "TLS" : "TCP / HTTP")
                if let ssh = workspace.server.ssh, ssh.enabled { info("SSH tunnel", "\(ssh.username)@\(ssh.host):\(ssh.port)") }
                if !workspace.server.username.isEmpty { info("User", workspace.server.username) }
            }.padding(17)
            Divider()
            HStack { Text(workspace.server.engine.objectLabel).font(.system(size: 12, weight: .semibold)); Spacer(); Text("\(workspace.objects.count)").foregroundStyle(.secondary).font(.caption) }.padding(17)
            TableSearchField(text: $search, focus: focus).frame(height: 24).padding(.horizontal, 14).padding(.bottom, 10)
            if let error = workspace.metadataError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal, 16).padding(.bottom, 8) }
            if workspace.objects.isEmpty { Text(workspace.connected ? "No objects to display." : "Connect to explore this database.").font(.caption).foregroundStyle(.secondary).padding(17); Spacer() }
            else {
                List(workspace.objects.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }) { object in
                    HStack(spacing: 6) {
                        Label(object.displayName, systemImage: workspace.server.engine == .mongo ? "doc.on.doc" : workspace.server.engine == .redis ? "key" : "tablecells")
                            .font(.system(size: 12)).lineLimit(1).help(object.displayName)
                        Spacer(minLength: 0)
                        Button { Task { await workspace.preview(object) } } label: { Image(systemName: "play.fill") }
                            .help("Preview up to 50 records from \(object.displayName)")
                            .accessibilityLabel("Preview \(object.displayName)")
                        Button { detailObject = object } label: { Image(systemName: "info.circle") }
                            .help("Show structure or details for \(object.displayName)")
                            .accessibilityLabel("Details for \(object.displayName)")
                    }.buttonStyle(.borderless).disabled(workspace.busy || !workspace.connected)
                }.listStyle(.plain)
            }
        }.background(Color(nsColor: .controlBackgroundColor))
        .sheet(item: $detailObject) { object in ObjectDetailsView(workspace: workspace, object: object) }
    }
    private func info(_ title: String, _ value: String) -> some View { HStack(alignment: .top) { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).lineLimit(2).textSelection(.enabled).multilineTextAlignment(.trailing) }.font(.caption) }
}

struct ConnectionSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var server: Server
    @State private var password = ""
    @State private var ssh = SSHConfiguration()
    @State private var sshSecret = ""
    @State private var error: String?
    @State private var saving = false
    @State private var credentialLoaded = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) { EngineIcon(engine: server.engine, size: 44); VStack(alignment: .leading, spacing: 4) { Text(store.servers.contains(where: { $0.id == server.id }) ? "Edit Connection" : "New Connection").font(.title2.bold()); Text("A new home for your database.").foregroundStyle(.secondary) }; Spacer() }.padding(24)
            Divider()
            Form {
                Section {
                    Picker("Database engine", selection: $server.engine) { ForEach(Engine.allCases) { Text($0.rawValue).tag($0) } }
                    TextField("Connection name", text: $server.name, prompt: Text("e.g. Local development"))
                }
                Section("Server") {
                    TextField("Host", text: $server.host, prompt: Text("localhost"))
                    TextField("Port", value: $server.port, format: .number.grouping(.never))
                    TextField(server.engine.databaseLabel, text: $server.database, prompt: Text(server.engine == .influx ? "Discovered after connecting" : "Initial database"))
                    Toggle("Use TLS", isOn: $server.tls)
                    if server.engine == .redis { Text("Redis currently supports TCP only. TLS is not yet available.").font(.caption).foregroundStyle(.secondary) }
                }
                Section(server.engine == .influx ? "InfluxDB 2 authentication" : "Authentication") {
                    if server.engine == .influx { TextField("Organization", text: $server.organization) }
                    else { TextField("Username", text: $server.username) }
                    SecureField(server.engine == .influx ? "API token" : "Password", text: $password)
                    if server.engine == .mongo { TextField("Auth database", text: $server.authDatabase) }
                    Label("Saved in your macOS Keychain", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
                Section("SSH tunnel") {
                    Toggle("Enable SSH tunnel", isOn: $ssh.enabled)
                    if ssh.enabled {
                        TextField("SSH host", text: $ssh.host, prompt: Text("bastion.example.com"))
                        TextField("SSH port", value: $ssh.port, format: .number.grouping(.never))
                        TextField("SSH username", text: $ssh.username)
                        Picker("Authentication", selection: $ssh.authentication) {
                            Text("Password").tag(SSHConfiguration.Authentication.password)
                            Text("SSH key file").tag(SSHConfiguration.Authentication.keyFile)
                        }
                        if ssh.authentication == .keyFile {
                            HStack {
                                TextField("Private key", text: $ssh.keyFile)
                                Button("Choose…") {
                                    let panel = NSOpenPanel()
                                    panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                                    panel.showsHiddenFiles = true; panel.message = "Choose your SSH private key"
                                    if panel.runModal() == .OK, let url = panel.url { ssh.keyFile = url.path }
                                }
                            }
                        }
                        SecureField(ssh.authentication == .password ? "SSH password" : "Key passphrase (optional)", text: $sshSecret)
                        Text("Database host and port are reached from the SSH server. Secrets are stored in Keychain. New SSH host keys are remembered automatically; changed keys are rejected.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled).padding(.horizontal, 24).padding(.bottom, 12) }
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button(saving ? "Saving…" : "Save & Connect") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || !valid) }.padding(18)
        }.frame(width: 550, height: 740)
        .onAppear { do { password = try Credentials.read(server.id); ssh = server.ssh ?? SSHConfiguration(); sshSecret = try Credentials.read(server.id, ssh: true); credentialLoaded = true } catch { self.error = error.localizedDescription } }
        .onChange(of: server.engine) { _, engine in server.port = engine.port; server.database = engine.initialDatabase; server.tls = engine != .redis }
    }
    private var valid: Bool { credentialLoaded && !server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...65535).contains(server.port) && (server.engine == .influx ? !server.organization.isEmpty : !server.database.isEmpty) }
    private func save() { saving = true; error = nil; server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines); server.host = server.host.trimmingCharacters(in: .whitespacesAndNewlines); Task { do { server.ssh = ssh; try await store.save(server, password: password, sshSecret: sshSecret) } catch { self.error = error.localizedDescription }; saving = false } }
}
