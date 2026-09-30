import XCTest
import Darwin
@testable import DBCenter

final class SSHTunnelTests: XCTestCase {
    func testLegacyRegistrationsDecodeWithoutSSH() throws {
        let data = try JSONEncoder().encode(Server())
        let dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(dictionary["ssh"])
        XCTAssertNil(try JSONDecoder().decode(Server.self, from: data).ssh)
        var server = Server(); server.ssh = SSHConfiguration(enabled: true, host: "jump.example.com", username: "alice")
        XCTAssertEqual(try JSONDecoder().decode(Server.self, from: JSONEncoder().encode(server)), server)
    }
    func testForwardingIsLoopbackOnlyAndArgumentsCannotBecomeShellCommands() throws {
        let config = SSHConfiguration(enabled: true, host: "jump.example.com", username: "alice")
        try config.validate(destination: "2001:db8::2", port: 5432)
        let args = SSHTunnel.arguments(config: config, destination: "2001:db8::2", destinationPort: 5432, localPort: 49152, control: "/tmp/a b/ctl")
        XCTAssertTrue(args.contains("127.0.0.1:49152:[2001:db8::2]:5432"))
        XCTAssertTrue(args.contains("/tmp/a b/ctl"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(args.contains("PreferredAuthentications=password"))
        XCTAssertEqual(args.last, "jump.example.com")
        for host in ["-oProxyCommand=evil", "localhost\nProxyCommand evil", "[::1]", "a/b"] {
            var bad = config; bad.host = host
            XCTAssertThrowsError(try bad.validate(destination: "localhost", port: 5432))
        }
    }
    func testInvalidKeyAndPortsFailBeforeLaunchingSSH() {
        var config = SSHConfiguration(enabled: true, host: "localhost", username: "alice", authentication: .keyFile, keyFile: "/nonexistent/private-key")
        XCTAssertThrowsError(try config.validate(destination: "localhost", port: 5432))
        config.authentication = .password; config.port = 0
        XCTAssertThrowsError(try config.validate(destination: "localhost", port: 5432))
        config.port = 22
        XCTAssertThrowsError(try config.validate(destination: "localhost", port: 65536))
    }
    func testFailedStartupAndStopAreSafe() throws {
        guard ProcessInfo.processInfo.environment["DBCENTER_SSH_INTEGRATION"] == "1" else { throw XCTSkip("Run scripts/test-ssh-integration.sh") }
        let tunnel = SSHTunnel()
        let config = SSHConfiguration(enabled: true, host: "127.0.0.1", port: try SSHTunnel.availablePort(), username: "test")
        XCTAssertThrowsError(try tunnel.start(config: config, destination: "localhost", port: 5432, credentialID: UUID()))
        XCTAssertEqual(tunnel.localPort, 0)
        XCTAssertThrowsError(try tunnel.check())
        tunnel.stop(); tunnel.stop()
    }
    func testRealSSHForwardAndIndependentTunnelLifecycle() throws {
        let config = try fixtureConfiguration()
        let first = fixtureTunnel(), second = fixtureTunnel()
        defer { first.stop(); second.stop() }
        try first.start(config: config, destination: "fixture.internal", port: 18089, credentialID: UUID())
        try second.start(config: config, destination: "fixture.internal", port: 18089, credentialID: UUID())
        XCTAssertNotEqual(first.localPort, second.localPort)
        try first.check(); try second.check()
        let firstPort = first.localPort
        let response = try http(port: firstPort)
        XCTAssertTrue(response.contains("200 OK"), response)
        first.stop()
        XCTAssertThrowsError(try first.check())
        XCTAssertThrowsError(try http(port: firstPort))
        try second.check()
        XCTAssertTrue(try http(port: second.localPort).contains("200 OK"))
    }
    func testDatabasesConnectThroughRemoteOnlyHostname() async throws {
        let ssh = try fixtureConfiguration()
        for (engine, port, database, query) in [(Engine.postgres, 15439, "postgres", "SELECT 42"), (.mongo, 27029, "admin", "{\"ping\":1}"), (.redis, 16389, "0", "PING"), (.influx, 18089, "metrics", "from(bucket: \"metrics\") |> range(start: -1h)")] {
            var server = Server(); server.engine = engine; server.host = "fixture.internal"; server.port = port
            server.database = database; server.tls = false; server.ssh = ssh
            server.username = engine == .postgres ? "dbcenter_test" : ""; server.organization = "test org"
            let knownHosts = fixtureRoot.appendingPathComponent(UUID().uuidString)
            let driver = DatabaseDriver(server: server, password: engine == .influx ? "test-token" : "", makeTunnel: { SSHTunnel(knownHostsFile: knownHosts) })
            do {
                try await driver.connect(database: database)
                let result = try await driver.execute(query, database: database)
                XCTAssertFalse(result.rows.isEmpty, engine.rawValue)
                if engine == .redis {
                    try await driver.connect(database: "1")
                    let ping = try await driver.execute("PING", database: "1")
                    XCTAssertFalse(ping.rows.isEmpty)
                }
                await driver.close()
            } catch { await driver.close(); throw error }
        }
    }
    func testPasswordAuthenticationAndRejectedPassword() throws {
        var config = try fixtureConfiguration(); config.authentication = .password
        let helper = fixtureRoot.appendingPathComponent("askpass")
        try "#!/bin/sh\nprintf '%s\\n' fixture-password\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let tunnel = SSHTunnel(knownHostsFile: fixtureRoot.appendingPathComponent(UUID().uuidString), askpassExecutable: helper)
        defer { tunnel.stop() }
        try tunnel.start(config: config, destination: "fixture.internal", port: 18089, credentialID: UUID())
        XCTAssertTrue(try http(port: tunnel.localPort).contains("200 OK"))
        tunnel.stop()
        config.authentication = .keyFile; config.keyFile = fixtureRoot.appendingPathComponent("encrypted-key").path
        try tunnel.start(config: config, destination: "fixture.internal", port: 18089, credentialID: UUID())
        XCTAssertTrue(try http(port: tunnel.localPort).contains("200 OK"))
        tunnel.stop(); config.authentication = .password
        try "#!/bin/sh\nprintf '%s\\n' wrong-password\n".write(to: helper, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try tunnel.start(config: config, destination: "fixture.internal", port: 18089, credentialID: UUID())) {
            XCTAssertTrue($0.localizedDescription.contains("Permission denied"), $0.localizedDescription)
        }
        XCTAssertEqual(tunnel.localPort, 0)
    }
    func testChangedHostKeyIsRejected() throws {
        let config = try fixtureConfiguration()
        let tunnel = SSHTunnel(knownHostsFile: fixtureRoot.appendingPathComponent("wrong-hosts"))
        defer { tunnel.stop() }
        XCTAssertThrowsError(try tunnel.start(config: config, destination: "fixture.internal", port: 18089, credentialID: UUID())) {
            XCTAssertTrue($0.localizedDescription.contains("HOST IDENTIFICATION HAS CHANGED"), $0.localizedDescription)
        }
        XCTAssertEqual(tunnel.localPort, 0)
    }
    func testDatabaseConnectionFailureClosesTunnel() async throws {
        var server = Server(); server.ssh = try fixtureConfiguration(); server.host = "fixture.internal"
        server.engine = .redis; server.port = 12345; server.tls = false; server.database = "0"
        let tunnel = fixtureTunnel()
        let driver = DatabaseDriver(server: server, password: "", makeTunnel: { tunnel })
        do { try await driver.connect(database: "0"); XCTFail("Expected unavailable destination") } catch { }
        XCTAssertThrowsError(try tunnel.check())
        XCTAssertEqual(tunnel.localPort, 0)
        await driver.close()
    }
    private var fixtureRoot: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["DBCENTER_SSH_TEST_ROOT"] ?? NSTemporaryDirectory()) }
    private func fixtureTunnel() -> SSHTunnel { SSHTunnel(knownHostsFile: fixtureRoot.appendingPathComponent(UUID().uuidString)) }
    private func fixtureConfiguration() throws -> SSHConfiguration {
        let env = ProcessInfo.processInfo.environment
        guard env["DBCENTER_SSH_INTEGRATION"] == "1", let key = env["DBCENTER_SSH_TEST_KEY"], let port = env["DBCENTER_SSH_TEST_PORT"].flatMap(Int.init) else { throw XCTSkip("Run scripts/test-ssh-integration.sh") }
        return SSHConfiguration(enabled: true, host: "127.0.0.1", port: port, username: "dbcenter_test", authentication: .keyFile, keyFile: key)
    }
    private func http(port: Int) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = UInt16(port).bigEndian
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { throw DBError("Socket closed") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request = "GET /api/v2/buckets?org=test%20org HTTP/1.0\r\nAuthorization: Token test-token\r\n\r\n"
        _ = request.withCString { Darwin.send(fd, $0, strlen($0), 0) }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &bytes, bytes.count, 0)
        guard count > 0 else { throw DBError("No HTTP response") }
        return String(decoding: bytes.prefix(count), as: UTF8.self)
    }
}
