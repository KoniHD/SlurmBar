import XCTest
import Darwin
@testable import SlurmBarCore

final class ControlSocketScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // Short /tmp path keeps socket paths under the 104-byte sun_path limit.
        root = URL(fileURLWithPath: "/tmp/sbs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSocket(_ path: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) })
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    }

    func testFindsSocketsInNestedFoldersButSkipsOtherFiles() throws {
        let control = root.appendingPathComponent("control")
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false)
        try makeSocket(root.appendingPathComponent("top").path)
        try makeSocket(control.appendingPathComponent("cm-host").path)
        try Data("Host x".utf8).write(to: root.appendingPathComponent("config"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("fifo").path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                                   withDestinationURL: root.appendingPathComponent("top"))

        let found = ControlSocketScanner.sockets(in: [root])
        XCTAssertEqual(found, [control.appendingPathComponent("cm-host").path, root.appendingPathComponent("top").path].sorted())
    }

    func testDepthLimitsRecursionAndSymlinkedFoldersAreNotFollowed() throws {
        let deep = root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try makeSocket(deep.appendingPathComponent("s").path)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"),
                                                   withDestinationURL: root.appendingPathComponent("a"))

        XCTAssertEqual(ControlSocketScanner.sockets(in: [root], depth: 2), [])
        XCTAssertEqual(ControlSocketScanner.sockets(in: [root], depth: 3), [deep.appendingPathComponent("s").path])
    }

    func testSocketsOwnedByAnotherUserAreIgnored() throws {
        try makeSocket(root.appendingPathComponent("mine").path)
        XCTAssertEqual(ControlSocketScanner.sockets(in: [root], uid: getuid() + 1), [])
    }

    func testAgentSocketsAreSkipped() throws {
        let agent = root.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: false)
        try makeSocket(agent.appendingPathComponent("s.mTpCm6.agent.Qgsc").path)
        try makeSocket(root.appendingPathComponent("master-62ce").path)
        XCTAssertEqual(ControlSocketScanner.sockets(in: [root]), [root.appendingPathComponent("master-62ce").path])
    }

    func testMissingFolderYieldsNoSockets() {
        XCTAssertEqual(ControlSocketScanner.sockets(in: [root.appendingPathComponent("missing")]), [])
    }
}
