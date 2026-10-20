import Foundation
import Darwin

public struct SSHHost: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var alias: String
    public var controlPath: String
    public var enabled: Bool
    public var selectedPartitions: [String]

    public init(id: UUID = UUID(), alias: String, controlPath: String, enabled: Bool = true, selectedPartitions: [String] = []) {
        self.id = id
        self.alias = alias
        self.controlPath = controlPath
        self.enabled = enabled
        self.selectedPartitions = selectedPartitions
    }
}

public enum SessionAvailability: Sendable, Equatable {
    case active, inactive, unsupported, unavailable(String)
}

public struct CommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }
}

public enum SSHTransportError: Error, LocalizedError, Sendable {
    case inactive, invalidSocket(String), timedOut, outputLimit, cancelled
    public var errorDescription: String? {
        switch self {
        case .inactive: return "No external SSH session is active."
        case .invalidSocket(let reason): return reason
        case .timedOut: return "SSH command exceeded its time limit."
        case .outputLimit: return "SSH command exceeded its output limit."
        case .cancelled: return "SSH command was cancelled."
        }
    }
}

/// Reuses a user-created OpenSSH master. Never loads SSH configuration or authenticates.
/// Callers must serialize refreshes: an actor alone does not serialize across await points.
public actor SSHTransport {
    public init() {}

    public func availability(for host: SSHHost) async -> SessionAvailability {
        guard host.enabled else { return .inactive }
        do {
            let path = try Self.validatedSocketPath(host.controlPath)
            let result = try await SSHSubprocess.run(arguments: Self.arguments(controlPath: path, operation: "channels"), timeout: 3)
            let diagnostic = result.stderr.lowercased()
            if diagnostic.contains("does not support info request") || diagnostic.contains("invalid multiplex command") || diagnostic.contains("info request type not supported") {
                return .unsupported
            }
            guard result.exitCode == 0 else { return .inactive }
            return Self.parseChannels(result.stdout)
        } catch SSHTransportError.invalidSocket(let reason) {
            return .unavailable(reason)
        } catch is CancellationError {
            return .inactive
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    public func run(command: String, for host: SSHHost) async throws -> CommandResult {
        try Task.checkCancellation()
        guard await availability(for: host) == .active else { throw SSHTransportError.inactive }
        try Task.checkCancellation()
        let path = try Self.validatedSocketPath(host.controlPath)
        return try await SSHSubprocess.run(arguments: Self.arguments(controlPath: path, command: command), timeout: 8)
    }

    // -F /dev/null prevents Include, Match exec, LocalCommand and proxies from user config.
    // If the socket vanishes after checking it, ProxyCommand=false makes fallback fail locally.
    static func arguments(controlPath: String, operation: String? = nil, command: String? = nil) -> [String] {
        var args = ["-F", "/dev/null", "-S", controlPath, "-T", "-n",
                    "-o", "ControlMaster=no", "-o", "ControlPersist=no",
                    "-o", "ProxyCommand=/usr/bin/false", "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=2", "-o", "ConnectionAttempts=1",
                    "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no",
                    "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no",
                    "-o", "ServerAliveInterval=0", "-o", "TCPKeepAlive=no",
                    "-o", "LogLevel=ERROR"]
        if let operation { args += ["-O", operation] }
        args += ["slurmbar.invalid"]
        if let command { args += [command] }
        return args
    }

    /// Matches the diagnostic format emitted by OpenSSH's channel_open_message.
    /// Ignore control clients (including this checker), listeners and closing/opening channels.
    static func parseChannels(_ text: String) -> SessionAvailability {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.first == "The following connections are open:" else { return .unsupported }
        let pattern = #"^\s*#[0-9]+ .+ \(t4 \[(?:session|direct-tcpip)\] r[0-9]+ (?:m|nm)[0-9]+ i0/[0-9]+ o0/[0-9]+ "#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return .unsupported }
        for line in lines.dropFirst() {
            if expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { return .active }
        }
        return .inactive
    }

    static func validatedSocketPath(_ input: String) throws -> String {
        let path = (input as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("%"), path.utf8.count < 104 else {
            throw SSHTransportError.invalidSocket("Choose an absolute, expanded control socket path shorter than 104 bytes (no SSH % tokens).")
        }
        // Resolve parent symlinks (including macOS /var), but reject a symlink socket.
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath()
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw SSHTransportError.invalidSocket("Control socket is absent; connect using another application first.") }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
            throw SSHTransportError.invalidSocket("Control path must be a Unix socket owned by your user.")
        }
        var parentInfo = stat()
        let parent = resolved.deletingLastPathComponent().path
        guard lstat(parent, &parentInfo) == 0, parentInfo.st_uid == getuid(), (parentInfo.st_mode & 0o022) == 0 else {
            throw SSHTransportError.invalidSocket("Keep the control socket in a directory you own that is not writable by other users (for example ~/.ssh/control with mode 700).")
        }
        // A writable ancestor could otherwise let another user replace the private directory.
        var ancestor = resolved.deletingLastPathComponent()
        while true {
            var ancestorInfo = stat()
            guard lstat(ancestor.path, &ancestorInfo) == 0,
                  ancestorInfo.st_uid == 0 || ancestorInfo.st_uid == getuid() else {
                throw SSHTransportError.invalidSocket("Control socket ancestors must be owned by you or root.")
            }
            let sharedStickyRoot = ancestorInfo.st_uid == 0 && (ancestorInfo.st_mode & S_ISVTX) != 0
            guard (ancestorInfo.st_mode & 0o022) == 0 || sharedStickyRoot else {
                throw SSHTransportError.invalidSocket("Control socket ancestors must not be writable by other users.")
            }
            if ancestor.path == "/" { break }
            ancestor.deleteLastPathComponent()
        }
        guard resolved.path.utf8.count < 104 else { throw SSHTransportError.invalidSocket("Resolved control socket path is too long.") }
        // ssh expands % and tilde in ControlPath even when provided with -S.
        guard !resolved.path.contains("%") else { throw SSHTransportError.invalidSocket("Control socket path must not contain SSH % tokens.") }
        return resolved.path
    }
}

private final class SSHCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Pipe drains and deadline checks run off the cooperative executor. No shell is involved.
private enum SSHSubprocess {
    static func run(arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        let cancellation = SSHCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try execute(arguments: arguments, timeout: timeout, cancellation: cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func execute(arguments: [String], timeout: TimeInterval, cancellation: SSHCancellation) throws -> CommandResult {
        guard !cancellation.cancelled else { throw CancellationError() }
        let process = Process()
        let output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "SSH_ASKPASS_REQUIRE": "never"]
        try process.run()
        // Close our write ends so EOF is observable after the child exits.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = errors.fileHandleForReading.fileDescriptor
        _ = fcntl(outFD, F_SETFL, O_NONBLOCK)
        _ = fcntl(errFD, F_SETFL, O_NONBLOCK)
        defer { try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close() }
        var stdout = Data(), stderr = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var failure: Error?
        func drain(_ fd: Int32, into data: inout Data) {
            var bytes = [UInt8](repeating: 0, count: 8192)
            // Bound each drain so a constantly writing child cannot starve deadline checks.
            for _ in 0..<32 {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
                if data.count > 4 * 1024 * 1024 { break }
            }
        }
        while true {
            drain(outFD, into: &stdout)
            drain(errFD, into: &stderr)
            if cancellation.cancelled { failure = CancellationError() }
            else if stdout.count + stderr.count > 4 * 1024 * 1024 { failure = SSHTransportError.outputLimit }
            else if ProcessInfo.processInfo.systemUptime >= deadline { failure = SSHTransportError.timedOut }
            if failure != nil {
                // Kill only our mux client, never the externally owned master.
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                break
            }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        if let failure { throw failure }
        drain(outFD, into: &stdout)
        drain(errFD, into: &stderr)
        guard stdout.count + stderr.count <= 4 * 1024 * 1024 else { throw SSHTransportError.outputLimit }
        return CommandResult(stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self), exitCode: process.terminationStatus)
    }
}
