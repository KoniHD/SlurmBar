import CryptoKit
import Foundation

// MARK: - Versions

public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Accepts `1.2.3` or `v1.2.3` and nothing else, matching the release tag format.
    public init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            numbers.append(value)
        }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

// MARK: - Configuration and model

public enum UpdateConfiguration {
    public static let repository = "KoniHD/SlurmBar"
    /// Base64 Ed25519 public key. The matching private key signs release disk images in CI.
    public static let publicKey = "01MF9A4G1M/Mn4Z+f/lUQL0NyFbSo6GPC0nrrOJvGs8="
    public static let diskImageName = "SlurmBar.dmg"
    public static let signatureName = "SlurmBar.dmg.sig"
    public static let appName = "SlurmBar.app"
    static let maxMetadataBytes = 1_000_000
    static let maxSignatureBytes = 4_096
    static let maxDiskImageBytes = 100_000_000
}

public struct UpdateRelease: Equatable, Sendable {
    public let version: SemanticVersion
    public let notesURL: URL
    public let diskImageURL: URL
    public let signatureURL: URL

    public init(version: SemanticVersion, notesURL: URL, diskImageURL: URL, signatureURL: URL) {
        self.version = version
        self.notesURL = notesURL
        self.diskImageURL = diskImageURL
        self.signatureURL = signatureURL
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case invalidResponse(String)
    case missingAssets
    case untrustedURL
    case tooLarge
    case badSignature
    case unsupportedInstall(String)
    case verification(String)
    case commandFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail): return "Unexpected update response: \(detail)"
        case .missingAssets: return "The release has no signed disk image yet."
        case .untrustedURL: return "The release points to an unexpected download location."
        case .tooLarge: return "The download exceeded its size limit."
        case .badSignature: return "The download's signature did not verify, so it was discarded."
        case .unsupportedInstall(let detail): return detail
        case .verification(let detail): return "The downloaded app failed verification: \(detail)"
        case .commandFailed(let detail): return "Installing the update failed: \(detail)"
        case .timedOut: return "Installing the update timed out."
        }
    }
}

// MARK: - Release lookup

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let html_url: String
    let assets: [Asset]
}

public enum UpdateReleaseParser {
    public static func parse(_ data: Data, repository: String = UpdateConfiguration.repository) throws -> UpdateRelease {
        let release: GitHubRelease
        do { release = try JSONDecoder().decode(GitHubRelease.self, from: data) }
        catch { throw UpdateError.invalidResponse("not a release document") }
        guard !release.draft, !release.prerelease else { throw UpdateError.invalidResponse("not a published release") }
        guard let version = SemanticVersion(release.tag_name) else {
            throw UpdateError.invalidResponse("tag \(release.tag_name.prefix(32)) is not vMAJOR.MINOR.PATCH")
        }
        guard let notes = URL(string: release.html_url), isTrusted(notes, repository: repository, pathPrefix: "/\(repository)/releases/") else {
            throw UpdateError.untrustedURL
        }
        func asset(_ name: String) throws -> URL {
            guard let match = release.assets.first(where: { $0.name == name }) else { throw UpdateError.missingAssets }
            // Only exact release-asset paths in this repository are acceptable download locations.
            guard let url = URL(string: match.browser_download_url),
                  isTrusted(url, repository: repository, pathPrefix: "/\(repository)/releases/download/\(release.tag_name)/")
            else { throw UpdateError.untrustedURL }
            return url
        }
        return UpdateRelease(version: version, notesURL: notes,
                             diskImageURL: try asset(UpdateConfiguration.diskImageName),
                             signatureURL: try asset(UpdateConfiguration.signatureName))
    }

    private static func isTrusted(_ url: URL, repository: String, pathPrefix: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.port == nil && url.user == nil
            && url.path.hasPrefix(pathPrefix) && !url.path.contains("..")
    }
}

/// Downloads at most `maxBytes` from an HTTPS URL. Injected so tests never touch the network.
public typealias UpdateFetch = @Sendable (URL, Int) async throws -> Data

public enum UpdateNetwork {
    public static let fetch: UpdateFetch = { url, maxBytes in
        guard url.scheme == "https" else { throw UpdateError.untrustedURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpAdditionalHeaders = ["Accept": "application/vnd.github+json, application/octet-stream",
                                              "User-Agent": "SlurmBar-Updater"]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        // Files fetched by the app itself are not quarantined, so Gatekeeper never prompts for updates.
        let (file, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.invalidResponse("HTTP status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? Int.max
        guard size <= maxBytes else { throw UpdateError.tooLarge }
        return try Data(contentsOf: file)
    }
}

public struct UpdateChecker: Sendable {
    public var repository: String
    public var fetch: UpdateFetch

    public init(repository: String = UpdateConfiguration.repository, fetch: @escaping UpdateFetch = UpdateNetwork.fetch) {
        self.repository = repository
        self.fetch = fetch
    }

    /// Returns the latest published release only when it is newer than `current`.
    public func check(current: SemanticVersion) async throws -> UpdateRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError.untrustedURL
        }
        let data = try await fetch(url, UpdateConfiguration.maxMetadataBytes)
        let release = try UpdateReleaseParser.parse(data, repository: repository)
        return release.version > current ? release : nil
    }
}

// MARK: - Verification

public enum UpdateVerifier {
    public static func verify(_ data: Data, signature: Data, publicKey: String = UpdateConfiguration.publicKey) throws {
        guard let text = String(data: signature, encoding: .utf8),
              let signatureBytes = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let keyBytes = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              key.isValidSignature(signatureBytes, for: data)
        else { throw UpdateError.badSignature }
    }
}

// MARK: - Installation

public struct StagedUpdate: Equatable, Sendable {
    /// Hidden directory beside the installed app (same volume, so swaps are atomic renames).
    public let stagingDirectory: URL
    public let stagedApp: URL
    public let destination: URL

    public init(stagingDirectory: URL, stagedApp: URL, destination: URL) {
        self.stagingDirectory = stagingDirectory
        self.stagedApp = stagedApp
        self.destination = destination
    }
}

public struct UpdateInstaller: Sendable {
    public var publicKey: String
    public var fetch: UpdateFetch
    public var bundleIdentifier: String

    public init(bundleIdentifier: String, publicKey: String = UpdateConfiguration.publicKey,
                fetch: @escaping UpdateFetch = UpdateNetwork.fetch) {
        self.bundleIdentifier = bundleIdentifier
        self.publicKey = publicKey
        self.fetch = fetch
    }

    /// Downloads, verifies and unpacks `release` next to `destination`. Nothing is replaced yet.
    public func stage(_ release: UpdateRelease, replacing destination: URL) async throws -> StagedUpdate {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        guard destination.pathExtension == "app", fileManager.isWritableFile(atPath: parent.path) else {
            throw UpdateError.unsupportedInstall("SlurmBar can only update itself when it is an app in a folder you can write to.")
        }
        let signature = try await fetch(release.signatureURL, UpdateConfiguration.maxSignatureBytes)
        let image = try await fetch(release.diskImageURL, UpdateConfiguration.maxDiskImageBytes)
        try UpdateVerifier.verify(image, signature: signature, publicKey: publicKey)

        let work = fileManager.temporaryDirectory.appendingPathComponent("SlurmBarUpdate-\(UUID().uuidString)")
        let staging = parent.appendingPathComponent(".SlurmBar-update-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mnt")
        let imageFile = work.appendingPathComponent(UpdateConfiguration.diskImageName)
        let log = work.appendingPathComponent("commands.log")
        defer { try? fileManager.removeItem(at: work) }
        var succeeded = false
        defer { if !succeeded { try? fileManager.removeItem(at: staging) } }
        try fileManager.createDirectory(at: mount, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try image.write(to: imageFile)

        try await UpdateSubprocess.run("/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, imageFile.path],
            log: log, timeout: 120)
        let stagedApp = staging.appendingPathComponent(UpdateConfiguration.appName)
        do {
            try await UpdateSubprocess.run("/usr/bin/ditto",
                [mount.appendingPathComponent(UpdateConfiguration.appName).path, stagedApp.path], log: log, timeout: 120)
        } catch {
            try? await UpdateSubprocess.run("/usr/bin/hdiutil", ["detach", "-force", mount.path], log: log, timeout: 60)
            throw error
        }
        try? await UpdateSubprocess.run("/usr/bin/hdiutil", ["detach", "-force", mount.path], log: log, timeout: 60)

        try validate(stagedApp, expecting: release.version)
        try await UpdateSubprocess.run("/usr/bin/codesign",
            ["--verify", "--deep", "--strict", stagedApp.path], log: log, timeout: 60)
        succeeded = true
        return StagedUpdate(stagingDirectory: staging, stagedApp: stagedApp, destination: destination)
    }

    /// The signature authenticates the image, but a replayed old signed image must also not pass for a new tag.
    func validate(_ app: URL, expecting version: SemanticVersion) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw UpdateError.verification("missing Info.plist") }
        guard plist["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError.verification("unexpected bundle identifier")
        }
        guard let text = plist["CFBundleShortVersionString"] as? String, SemanticVersion(text) == version else {
            throw UpdateError.verification("version does not match the release")
        }
        let executable = app.appendingPathComponent("Contents/MacOS/SlurmBar").path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw UpdateError.verification("missing executable")
        }
    }

    // The helper outlives this process: it waits for the app to exit, swaps bundles with
    // same-volume renames, restores the old app if anything fails, and relaunches.
    static let swapScript = """
    pid="$1"; dest="$2"; stage="$3"; opener="$4"
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
        waited=$((waited + 1))
        if [ "$waited" -gt 300 ]; then rm -rf "$stage"; exit 1; fi
        sleep 0.1
    done
    if mv "$dest" "$stage/Previous.app"; then
        if ! mv "$stage/SlurmBar.app" "$dest"; then mv "$stage/Previous.app" "$dest"; fi
    fi
    "$opener" "$dest"
    rm -rf "$stage"
    """

    /// Starts the detached swap helper. The caller must quit the app afterwards.
    @discardableResult
    public static func launchSwap(_ staged: StagedUpdate, waitingFor pid: Int32, opener: String = "/usr/bin/open") throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", swapScript, "slurmbar-update", String(pid), staged.destination.path,
                             staged.stagingDirectory.path, opener]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin"]
        try process.run()
        return process
    }
}

private final class UpdateCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Fixed system tools only, no shell, bounded by a deadline. Output goes to a log file so a
/// chatty child can never block on a full pipe.
enum UpdateSubprocess {
    static func run(_ executable: String, _ arguments: [String], log: URL, timeout: TimeInterval) async throws {
        let cancellation = UpdateCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do { try execute(executable, arguments, log: log, timeout: timeout, cancellation: cancellation); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func execute(_ executable: String, _ arguments: [String], log: URL, timeout: TimeInterval,
                                cancellation: UpdateCancellation) throws {
        guard !cancellation.cancelled else { throw CancellationError() }
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var failure: Error?
        while process.isRunning {
            if cancellation.cancelled { failure = CancellationError() }
            else if ProcessInfo.processInfo.systemUptime >= deadline { failure = UpdateError.timedOut }
            if failure != nil { _ = Darwin.kill(process.processIdentifier, SIGKILL); break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        if let failure { throw failure }
        guard process.terminationStatus == 0 else {
            let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
            throw UpdateError.commandFailed("\((executable as NSString).lastPathComponent) exited with \(process.terminationStatus). \(detail)")
        }
    }
}
