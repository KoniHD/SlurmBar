import XCTest
@testable import SlurmBarCore

final class SSHTransportTests: XCTestCase {
    func testChannelsRequireKnownFormatAndOpenExternalChannel() {
        let header = "The following connections are open:\r\n"
        XCTAssertEqual(SSHTransport.parseChannels(header), .inactive)
        XCTAssertEqual(SSHTransport.parseChannels("unrecognized output"), .unsupported)
        XCTAssertEqual(SSHTransport.parseChannels(header + "  #1 client-session (t4 [session] r0 nm0 i0/0 o0/0 e[write]/0 fd 5/6/7 sock -1 cc -1 nc0 io 0x01/0x00 I)\r\n"), .active)
        XCTAssertEqual(SSHTransport.parseChannels(header + "  #2 direct-tcpip (t4 [direct-tcpip] r5 nm0 i0/123 o0/45 e[closed]/0 fd 5/6/7 sock -1 cc -1 nc0 io 0x01/0x00 I)\r\n"), .active)
    }

    func testControlCheckerListenersAndClosingChannelsAreInactive() {
        let header = "The following connections are open:\n"
        for line in [
            "  #0 mux-control-client (t16 [mux-control-client] nr0 nm0 i0/0 o0/0 e[closed]/0)",
            "  #1 session (t3 [session] r0 nm0 i0/0 o0/0 e[closed]/0)",
            "  #1 session (t4 [session] r0 nm0 i3/0 o0/0 e[closed]/0)",
            "  #1 session (t4 [session] r0 nm0 i0/0 o3/0 e[closed]/0)",
            "  #1 port listener (t2 [port-listener] r0 nm0 i0/0 o0/0 e[closed]/0)",
            "  #1 misleading (t4 [unknown] r0 nm0 i0/0 o0/0 e[closed]/0)"
        ] { XCTAssertEqual(SSHTransport.parseChannels(header + line), .inactive, line) }
    }

    func testArgumentsDisableConfigurationAndFallback() {
        let args = SSHTransport.arguments(controlPath: "/Users/example/.ssh/control/cluster", command: "sinfo --version")
        XCTAssertEqual(Array(args.prefix(4)), ["-F", "/dev/null", "-S", "/Users/example/.ssh/control/cluster"])
        for option in ["ControlMaster=no", "ProxyCommand=/usr/bin/false", "BatchMode=yes", "ClearAllForwardings=yes", "PermitLocalCommand=no", "ForwardAgent=no"] {
            XCTAssertTrue(args.contains(option))
        }
        XCTAssertEqual(Array(args.suffix(2)), ["slurmbar.invalid", "sinfo --version"])
    }

    func testInvalidPathsAreRejectedBeforeStartingSSH() throws {
        for path in ["relative/path", "/tmp/%C", "/tmp/\0socket", String(repeating: "a", count: 110)] {
            XCTAssertThrowsError(try SSHTransport.validatedSocketPath(path))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try SSHTransport.validatedSocketPath(file.path))
    }

    func testDisabledAndMissingHostNeverRunCommand() async {
        let transport = SSHTransport()
        let disabled = SSHHost(alias: "example", controlPath: "/missing", enabled: false)
        let availability = await transport.availability(for: disabled)
        XCTAssertEqual(availability, .inactive)
        do {
            _ = try await transport.run(command: "echo should-not-run", for: disabled)
            XCTFail("Expected inactive transport error")
        } catch { XCTAssertTrue(error is SSHTransportError) }
    }
}
