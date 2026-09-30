import AppKit
import Darwin

struct SSHConfiguration: Codable, Equatable {
    enum Authentication: String, Codable, CaseIterable { case password, keyFile }
    var enabled = false
    var host = ""
    var port = 22
    var username = ""
    var authentication: Authentication = .password
    var keyFile = ""

    func validate(destination: String, port destinationPort: Int) throws {
        // These values become OpenSSH arguments and forwarding specifications, never shell commands.
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        for host in [host, destination] {
            guard !host.isEmpty, !host.hasPrefix("-"), host.rangeOfCharacter(from: forbidden) == nil,
                  !host.contains("/"), !host.contains("["), !host.contains("]") else {
                throw DBError("Enter a hostname or an unbracketed IP address for both SSH and database hosts.")
            }
        }
        guard !username.isEmpty, !username.hasPrefix("-"), username.rangeOfCharacter(from: forbidden) == nil,
              (1...65535).contains(port), (1...65535).contains(destinationPort) else {
            throw DBError("Enter an SSH username and valid SSH/database ports (1–65535).")
        }
        if authentication == .keyFile {
            guard keyFile.hasPrefix("/"), FileManager.default.isReadableFile(atPath: keyFile) else {
                throw DBError("Choose a readable SSH private key file.")
            }
        }
    }
}

/// Owned by one database driver. All start/check operations run on that driver's worker queue.
/// The lock also allows application termination to stop a tunnel during a connection attempt.
final class SSHTunnel: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var process: Process?
    private var directory: URL?
    private var terminationObserver: NSObjectProtocol?
    private(set) var localPort = 0
    private let knownHostsFile: URL?
    private let askpassExecutable: URL?

    init(knownHostsFile: URL? = nil, askpassExecutable: URL? = nil) {
        self.knownHostsFile = knownHostsFile; self.askpassExecutable = askpassExecutable
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in self?.stop() }
    }
    deinit { if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }; stop() }

    static func arguments(config: SSHConfiguration, destination: String, destinationPort: Int, localPort: Int, control: String) -> [String] {
        let target = destination.contains(":") ? "[\(destination)]" : destination
        var args = ["-F", "/dev/null", "-N", "-T", "-M", "-S", control,
                    "-o", "ControlPersist=no", "-o", "ExitOnForwardFailure=yes",
                    "-o", "ConnectTimeout=10", "-o", "ConnectionAttempts=1",
                    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                    "-o", "StrictHostKeyChecking=accept-new", "-o", "NumberOfPasswordPrompts=1",
                    "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes", "-o", "ForwardAgent=no",
                    "-L", "127.0.0.1:\(localPort):\(target):\(destinationPort)",
                    "-p", String(config.port), "-l", config.username]
        if config.authentication == .password {
            args += ["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no"]
        } else {
            args += ["-o", "PreferredAuthentications=publickey", "-i", config.keyFile]
        }
        return args + [config.host]
    }

    func start(config: SSHConfiguration, destination: String, port: Int, credentialID: UUID) throws {
        try config.validate(destination: destination, port: port)
        stop()
        // Reserving an ephemeral port and handing it to ssh has a small race. Retry only bind failures.
        for attempt in 0..<3 {
            let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dbc-ssh-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let log = folder.appendingPathComponent("error")
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: log)
            let child = Process()
            do {
                let assignedPort = try Self.availablePort()
                child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                child.arguments = Self.arguments(config: config, destination: destination, destinationPort: port, localPort: assignedPort, control: folder.appendingPathComponent("ctl").path)
                if let knownHostsFile {
                    let host = child.arguments!.removeLast()
                    child.arguments! += ["-o", "UserKnownHostsFile=\(knownHostsFile.path)", host]
                }
                var env = ProcessInfo.processInfo.environment
                env["SSH_ASKPASS"] = askpassExecutable?.path ?? Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
                env["SSH_ASKPASS_REQUIRE"] = "force"; env["DISPLAY"] = "DBCenter"
                env["DBCENTER_SSH_ASKPASS_ID"] = credentialID.uuidString
                child.environment = env
                child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = output
                lock.lock()
                directory = folder; process = child; localPort = assignedPort
                do { try child.run(); lock.unlock() } catch { lock.unlock(); throw error }
                try output.close()
                let deadline = Date().addingTimeInterval(30)
                while child.isRunning && Date() < deadline {
                    // OpenSSH creates its private control socket after authentication and forward setup.
                    if FileManager.default.fileExists(atPath: folder.appendingPathComponent("ctl").path) { return }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                let message = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                stop()
                if attempt < 2 && message.contains("Address already in use") { continue }
                throw DBError("SSH tunnel failed. \(message.isEmpty ? "Authentication timed out or SSH exited. Check the SSH host and credentials." : String(message.suffix(3000)))")
            } catch {
                try? output.close(); stop(); try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
    }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        guard process?.isRunning == true else { throw DBError("The SSH tunnel closed. Disconnect and reconnect to create a new tunnel.") }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let process, process.isRunning {
            process.terminate()
            // Bound shutdown even if ssh is stuck in authentication or a network operation.
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        process = nil; localPort = 0
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
    }
    static func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DBError("Could not allocate an SSH forwarding socket.") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard Darwin.bind(fd, $0, size) == 0 else { return Int32(-1) }
                return getsockname(fd, $0, &size)
            }
        }
        guard result == 0 else { throw DBError("Could not reserve a local SSH forwarding port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// OpenSSH invokes this same executable as askpass. Only a Keychain item ID is in the environment.
/// Run before SwiftUI initializes, and refuse host-key/other interactive prompts.
@main enum DBCenterLauncher {
    static func main() {
        if let value = ProcessInfo.processInfo.environment["DBCENTER_SSH_ASKPASS_ID"] {
            guard let id = UUID(uuidString: value), let prompt = CommandLine.arguments.dropFirst().first,
                  prompt.lowercased().contains("password") || prompt.lowercased().contains("passphrase"),
                  let secret = try? Credentials.read(id, ssh: true), !secret.contains("\n"), !secret.contains("\r") else { exit(1) }
            FileHandle.standardOutput.write(Data((secret + "\n").utf8)); exit(0)
        }
        DBCenterApp.main()
    }
}
