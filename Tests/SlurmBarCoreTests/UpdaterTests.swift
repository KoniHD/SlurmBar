import CryptoKit
import Foundation
import XCTest
@testable import SlurmBarCore

final class UpdaterTests: XCTestCase {
    private let repo = "KoniHD/SlurmBar"
    private func releaseJSON(tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false,
                             dmg: String? = nil, sig: String? = nil, notes: String? = nil) -> Data {
        let base = "https://github.com/\(repo)/releases/download/\(tag)"
        let json: [String: Any] = [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "html_url": notes ?? "https://github.com/\(repo)/releases/tag/\(tag)",
            "assets": [["name": "SlurmBar.dmg", "browser_download_url": dmg ?? "\(base)/SlurmBar.dmg"],
                       ["name": "SlurmBar.dmg.sig", "browser_download_url": sig ?? "\(base)/SlurmBar.dmg.sig"]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testVersionParsingAndOrdering() {
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion(1, 2, 3))
        XCTAssertEqual(SemanticVersion("0.10.0")?.description, "0.10.0")
        XCTAssertTrue(SemanticVersion("0.10.0")! > SemanticVersion("0.9.9")!)
        XCTAssertTrue(SemanticVersion("1.0.0")! > SemanticVersion("0.99.99")!)
        for bad in ["", "1.2", "1.2.3.4", "1.2.x", "v", "1..3", "-1.2.3", "1.2.3-beta", "１.2.3"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
    }

    func testParsesTrustedRelease() throws {
        let release = try UpdateReleaseParser.parse(releaseJSON(), repository: repo)
        XCTAssertEqual(release.version, SemanticVersion(0, 2, 0))
        XCTAssertEqual(release.diskImageURL.lastPathComponent, "SlurmBar.dmg")
        XCTAssertEqual(release.signatureURL.lastPathComponent, "SlurmBar.dmg.sig")
    }

    func testRejectsUntrustedOrIncompleteReleases() {
        let hostile = "https://evil.example/\(repo)/releases/download/v0.2.0/SlurmBar.dmg"
        let otherRepo = "https://github.com/someone/else/releases/download/v0.2.0/SlurmBar.dmg"
        let wrongTag = "https://github.com/\(repo)/releases/download/v9.9.9/SlurmBar.dmg"
        let plain = "http://github.com/\(repo)/releases/download/v0.2.0/SlurmBar.dmg"
        let traversal = "https://github.com/\(repo)/releases/download/v0.2.0/../../../x/SlurmBar.dmg"
        for url in [hostile, otherRepo, wrongTag, plain, traversal] {
            XCTAssertThrowsError(try UpdateReleaseParser.parse(releaseJSON(dmg: url), repository: repo), url) {
                XCTAssertEqual($0 as? UpdateError, .untrustedURL)
            }
        }
        XCTAssertThrowsError(try UpdateReleaseParser.parse(releaseJSON(draft: true), repository: repo))
        XCTAssertThrowsError(try UpdateReleaseParser.parse(releaseJSON(prerelease: true), repository: repo))
        XCTAssertThrowsError(try UpdateReleaseParser.parse(releaseJSON(tag: "nightly"), repository: repo))
        XCTAssertThrowsError(try UpdateReleaseParser.parse(Data("{}".utf8), repository: repo))
        let noAssets = try! JSONSerialization.data(withJSONObject: [
            "tag_name": "v0.2.0", "draft": false, "prerelease": false,
            "html_url": "https://github.com/\(repo)/releases/tag/v0.2.0", "assets": []] as [String: Any])
        XCTAssertThrowsError(try UpdateReleaseParser.parse(noAssets, repository: repo)) {
            XCTAssertEqual($0 as? UpdateError, .missingAssets)
        }
    }

    func testCheckerReturnsOnlyNewerReleases() async throws {
        let data = releaseJSON(tag: "v0.2.0")
        let expected = "https://api.github.com/repos/\(repo)/releases/latest"
        let checker = UpdateChecker(repository: repo) { url, _ in
            XCTAssertEqual(url.absoluteString, expected)
            return data
        }
        let newer = try await checker.check(current: SemanticVersion(0, 1, 6))
        XCTAssertEqual(newer?.version, SemanticVersion(0, 2, 0))
        let same = try await checker.check(current: SemanticVersion(0, 2, 0))
        XCTAssertNil(same)
        let older = try await checker.check(current: SemanticVersion(0, 3, 0))
        XCTAssertNil(older)
    }

    func testSignatureVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let payload = Data("disk image".utf8)
        let signature = Data(try key.signature(for: payload).base64EncodedString().utf8)
        XCTAssertNoThrow(try UpdateVerifier.verify(payload, signature: signature, publicKey: publicKey))
        XCTAssertThrowsError(try UpdateVerifier.verify(Data("tampered".utf8), signature: signature, publicKey: publicKey))
        XCTAssertThrowsError(try UpdateVerifier.verify(payload, signature: Data("garbage".utf8), publicKey: publicKey))
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try UpdateVerifier.verify(payload, signature: signature, publicKey: other))
    }

    // MARK: Installation with a real disk image

    private func makeFixture(version: String, bundleID: String = "io.github.slurmbar.app") throws -> (root: URL, dmg: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("slurmbar-update-test-\(UUID().uuidString)")
        let app = root.appendingPathComponent("src/SlurmBar.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/SlurmBar"))
        let plist: [String: Any] = ["CFBundleExecutable": "SlurmBar", "CFBundleIdentifier": bundleID,
                                    "CFBundleShortVersionString": version, "CFBundleVersion": version,
                                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try shell("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        let dmg = root.appendingPathComponent("SlurmBar.dmg")
        try shell("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", root.appendingPathComponent("src").path,
                                       "-volname", "SlurmBar", "-format", "UDZO", dmg.path])
        return (root, dmg)
    }

    private func shell(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(exe) \(args)")
    }

    private func release(_ version: String) -> UpdateRelease {
        let base = "https://github.com/\(repo)/releases/download/v\(version)"
        return UpdateRelease(version: SemanticVersion(version)!,
                             notesURL: URL(string: "https://github.com/\(repo)/releases/tag/v\(version)")!,
                             diskImageURL: URL(string: "\(base)/SlurmBar.dmg")!,
                             signatureURL: URL(string: "\(base)/SlurmBar.dmg.sig")!)
    }

    private func installer(dmg: Data, signedBy key: Curve25519.Signing.PrivateKey, signing payload: Data? = nil) throws -> UpdateInstaller {
        let signature = Data(try key.signature(for: payload ?? dmg).base64EncodedString().utf8)
        return UpdateInstaller(bundleIdentifier: "io.github.slurmbar.app",
                               publicKey: key.publicKey.rawRepresentation.base64EncodedString()) { url, _ in
            url.lastPathComponent.hasSuffix(".sig") ? signature : dmg
        }
    }

    func testStagesVerifiedUpdateAndSwapsBundles() async throws {
        let fixture = try makeFixture(version: "0.2.0")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installDir = fixture.root.appendingPathComponent("Applications")
        let installed = installDir.appendingPathComponent("SlurmBar.app")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("marker"))

        let key = Curve25519.Signing.PrivateKey()
        let staged = try await installer(dmg: Data(contentsOf: fixture.dmg), signedBy: key)
            .stage(release("0.2.0"), replacing: installed)
        XCTAssertEqual(staged.stagingDirectory.deletingLastPathComponent().path, installDir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.stagedApp.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("marker").path),
                      "staging must not touch the installed app")

        // Use a finished process id so the helper proceeds immediately; `true` stands in for `open`.
        let done = Process()
        done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try done.run(); done.waitUntilExit()
        let helper = try UpdateInstaller.launchSwap(staged, waitingFor: done.processIdentifier, opener: "/usr/bin/true")
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appendingPathComponent("marker").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.stagingDirectory.path), "staging directory is cleaned up")
    }

    func testRejectsBadSignatureWithoutStaging() async throws {
        let fixture = try makeFixture(version: "0.2.0")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installed = fixture.root.appendingPathComponent("Applications/SlurmBar.app")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let key = Curve25519.Signing.PrivateKey()
        let sut = try installer(dmg: Data(contentsOf: fixture.dmg), signedBy: key, signing: Data("other".utf8))
        do {
            _ = try await sut.stage(release("0.2.0"), replacing: installed)
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? UpdateError, .badSignature) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["SlurmBar.app"])
    }

    func testRejectsReplayedOlderImageAndWrongBundleIdentifier() async throws {
        let old = try makeFixture(version: "0.1.0")
        let foreign = try makeFixture(version: "0.2.0", bundleID: "com.example.other")
        defer { for f in [old, foreign] { try? FileManager.default.removeItem(at: f.root) } }
        let installed = old.root.appendingPathComponent("Applications/SlurmBar.app")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let key = Curve25519.Signing.PrivateKey()
        for fixture in [old, foreign] {
            // Both images carry a valid signature; the app inside must still match the release.
            let sut = try installer(dmg: Data(contentsOf: fixture.dmg), signedBy: key)
            do {
                _ = try await sut.stage(release("0.2.0"), replacing: installed)
                XCTFail("expected verification failure")
            } catch {
                guard case .verification = error as? UpdateError else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path), ["SlurmBar.app"])
    }

    func testRefusesToUpdateWhenNotAnAppBundle() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let sut = try installer(dmg: Data(), signedBy: key)
        do {
            _ = try await sut.stage(release("0.2.0"), replacing: URL(fileURLWithPath: "/tmp/SlurmBar"))
            XCTFail("expected failure")
        } catch { guard case .unsupportedInstall = error as? UpdateError else { return XCTFail("\(error)") } }
    }

    func testSwapScriptNeverInstallsPartialAppWhenRenameFails() throws {
        // A failed first rename must leave nothing installed and still clean up staging.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("slurmbar-swap-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let stage = root.appendingPathComponent("stage")
        try fm.createDirectory(at: stage.appendingPathComponent("SlurmBar.app"), withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("Missing.app")  // first rename fails
        let staged = StagedUpdate(stagingDirectory: stage, stagedApp: stage.appendingPathComponent("SlurmBar.app"), destination: missing)
        let done = Process()
        done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try done.run(); done.waitUntilExit()
        let helper = try UpdateInstaller.launchSwap(staged, waitingFor: done.processIdentifier, opener: "/usr/bin/true")
        helper.waitUntilExit()
        XCTAssertFalse(fm.fileExists(atPath: missing.path), "a failed swap must not install a partial app")
        XCTAssertFalse(fm.fileExists(atPath: stage.path))
    }
}
