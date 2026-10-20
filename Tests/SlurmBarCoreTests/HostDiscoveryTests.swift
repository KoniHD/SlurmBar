import XCTest
import Darwin
@testable import SlurmBarCore

final class HostDiscoveryTests: XCTestCase {
    private func resolve(_ config: String, alias: String = "cluster") -> DiscoveredHost {
        HostDiscovery.resolve(alias: alias, config: config, home: "/Users/tester", localHostname: "laptop.example", localUser: "tester", uid: 501)
    }

    func testOnlyLiteralAliasesAreSuggested() {
        XCTAssertEqual(HostDiscovery.aliases(in: "Host alpha beta\nHost *.example !bad\nHost = gamma # comment\nMatch exec touch\nHost -bad x/y"), ["alpha", "beta", "gamma"])
    }

    func testHostSpecificAndWildcardFirstValueWins() {
        let result = resolve("""
        Host cluster
          HostName compute.example
          User scientist
          Port 2200
        Host * !other
          ControlMaster auto
          ControlPersist 12h
          ControlPath ~/.ssh/%n-%h-%p-%r
          User ignored
        """)
        XCTAssertEqual(result.controlPath, "/Users/tester/.ssh/cluster-compute.example-2200-scientist")
        XCTAssertNil(result.resolutionIssue)
        XCTAssertEqual(resolve("Host *\nUser first\nControlPath ~/.ssh/%r\nHost cluster\nUser second").controlPath, "/Users/tester/.ssh/first")
    }

    func testQuotedPathsNegationAndTokens() {
        let result = resolve("""
        Host * !cluster
          ControlPath /wrong/path
        Host clus?er
          HostName "compute.example" # comment
          ControlPath "%d/SSH sockets/%L-%n-%u-%i"
        """)
        XCTAssertEqual(result.controlPath, "/Users/tester/SSH sockets/laptop-cluster-tester-501")
    }

    func testLiteralHashAndBackslashInControlPaths() {
        XCTAssertEqual(resolve("Host cluster\nControlPath /tmp/master#socket # trailing comment").controlPath, "/tmp/master#socket")
        let unsupportedEscape = resolve(#"ControlPath /tmp/master\socket"#)
        XCTAssertNil(unsupportedEscape.controlPath)
        XCTAssertNotNil(unsupportedEscape.resolutionIssue)
    }

    func testUnsupportedConditionsAndDisabledSocketsDoNotGuess() {
        for config in [
            "Match exec \"touch /tmp/slurmbar-must-not-run\"\nControlPath ~/.ssh/master-%C",
            "Host cluster\nCanonicalizeHostname yes\nControlPath ~/.ssh/master-%C",
            "Host cluster\nControlPath none",
            "Host cluster\nControlPath ~/.ssh/%q",
            "Host cluster\nUser tester",
            "Host cluster\nHostName 127.1\nControlPath ~/.ssh/master-%C"
        ] {
            let result = resolve(config)
            XCTAssertNil(result.controlPath, config)
            XCTAssertNotNil(result.resolutionIssue, config)
            XCTAssertEqual(result.suggestedControlPath, "")
        }
    }

    func testGlobIncludesKeepInlineOrderingAndNeverExecuteCommands() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sshDirectory = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: sshDirectory.appendingPathComponent("conf.d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "Include conf.d/*\nHost *\nUser fallback\nControlPath ~/.ssh/%n-%r\n".write(to: sshDirectory.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host cluster\nUser scientist\n".write(to: sshDirectory.appendingPathComponent("conf.d/01-cluster"), atomically: true, encoding: .utf8)
        let found = HostDiscovery.discover(home: home.path, systemConfigPath: nil)
        XCTAssertEqual(found.first(where: { $0.alias == "cluster" })?.controlPath, home.path + "/.ssh/cluster-scientist")
        let sentinel = home.appendingPathComponent("executed")
        try "Match exec \"touch \(sentinel.path)\"\nControlPath ~/.ssh/%n\n".write(to: sshDirectory.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        XCTAssertNil(HostDiscovery.resolve(alias: "cluster", home: home.path, systemConfigPath: nil).controlPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testHashedPathsMatchInstalledOpenSSHWithoutConnecting() throws {
        // Only our self-contained fixture is passed to ssh -G: no user config, Match exec, or DNS canonicalization.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var hostBuffer = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(gethostname(&hostBuffer, hostBuffer.count), 0)
        let localHostname = String(decoding: hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        for jump in ["", "ProxyJump gateway", "ProxyJump user@gateway:2222", "ProxyJump first,user@last:2200"] {
            let config = """
            Host cluster
                HostName compute.example
                User scientist
                Port 2200
                ControlMaster auto
                ControlPersist 12h
                ControlPath ~/.ssh/master-%C
                CanonicalizeHostname no
                \(jump)
            """
            try config.write(to: file, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-G", "-F", file.path, "cluster"]
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let expected = text.split(separator: "\n").first { $0.hasPrefix("controlpath ") }.map { String($0.dropFirst("controlpath ".count)) }
            XCTAssertNotNil(expected)
            let actual = HostDiscovery.resolve(alias: "cluster", config: config, home: NSHomeDirectory(), localHostname: localHostname, localUser: NSUserName())
            XCTAssertEqual(actual.controlPath, expected, jump)
        }
    }
}
