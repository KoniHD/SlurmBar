import Foundation
import Darwin

/// Lists existing Unix domain sockets owned by the current user, so one can be picked as a ControlPath.
///
/// `NSOpenPanel` (like Finder) never lists sockets, so the picker scans directories itself. Scanning only reads
/// directory entries with `lstat`: it never follows symlinks, connects to a socket, or runs `ssh`. A listed socket
/// still goes through `SSHTransport.validatedSocketPath` before it is used.
public enum ControlSocketScanner {
    /// Default places to look: `~/.ssh` and its subdirectories (for example `~/.ssh/control` or `~/.ssh/sockets`).
    public static var defaultDirectories: [URL] {
        [URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh", isDirectory: true)]
    }

    /// Returns sorted absolute socket paths in `directories`, descending into real (non-symlink) subdirectories
    /// up to `depth` levels below each directory, stopping after `limit` entries per directory examined.
    public static func sockets(in directories: [URL] = defaultDirectories, depth: Int = 2,
                               limit: Int = 500, uid: uid_t = getuid()) -> [String] {
        var found = Set<String>()
        for directory in directories {
            scan(directory.standardizedFileURL.path, remainingDepth: depth, limit: limit, uid: uid, into: &found)
        }
        return found.sorted()
    }

    /// OpenSSH 10.1+ keeps ssh-agent sockets as `~/.ssh/agent/s.<random>.agent.<random>`; they are never ControlPaths.
    static func isAgentSocket(_ name: String) -> Bool {
        name.hasPrefix("s.") && name.contains(".agent.")
    }

    private static func scan(_ directory: String, remainingDepth: Int, limit: Int, uid: uid_t, into found: inout Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names.sorted().prefix(limit) {
            let path = (directory as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFSOCK where info.st_uid == uid && !isAgentSocket(name):
                found.insert(path)
            case S_IFDIR where remainingDepth > 0:
                scan(path, remainingDepth: remainingDepth - 1, limit: limit, uid: uid, into: &found)
            default:
                continue
            }
        }
    }
}
