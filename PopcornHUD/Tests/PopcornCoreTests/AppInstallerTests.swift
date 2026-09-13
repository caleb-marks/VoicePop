import XCTest
@testable import PopcornCore

/// Exercises every `AppInstaller` path against fake `.app` bundles in a temp directory: the
/// happy paths, and each failure (copy, verify, swap, launch) with the state Applications must be
/// left in afterwards.
final class AppInstallerTests: XCTestCase {
    private var root: URL!
    private var applications: URL!
    private var backups: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicepop-installer-\(UUID().uuidString)", isDirectory: true)
        applications = root.appendingPathComponent("Applications", isDirectory: true)
        backups = root.appendingPathComponent("Previous Versions", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// A minimal bundle: Info.plist with a version and a "binary" whose contents identify it.
    @discardableResult
    private func makeBundle(at url: URL, version: String, marker: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleIdentifier": "com.example.fake"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(marker.utf8).write(to: url.appendingPathComponent("Contents/MacOS/VoicePop"))
        return url
    }

    private func marker(of bundle: URL) -> String? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/MacOS/VoicePop")) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private var destination: URL { applications.appendingPathComponent("VoicePop.app") }

    private func stagingLeftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: applications.path).filter { $0.contains(".staging-") }
    }

    private func installer(
        verify: @escaping (URL) throws -> Void = { _ in },
        launch: @escaping (URL) throws -> Void = { _ in }
    ) -> AppInstaller {
        AppInstaller(verify: verify, launch: launch)
    }

    // MARK: - Happy paths

    func testFirstInstallCopiesVerifiesAndLaunchesWithoutBackup() throws {
        let source = try makeBundle(at: root.appendingPathComponent("Downloads/VoicePop.app"), version: "1.3.0", marker: "new")
        var verified: URL?
        var launched: URL?
        let outcome = try installer(
            verify: { url in
                verified = url
                // Verification must see the staged copy, not the source and not the destination.
                XCTAssertTrue(url.lastPathComponent.contains(".staging-"))
                XCTAssertEqual(url.deletingLastPathComponent().path, self.applications.path)
            },
            launch: { launched = $0 }
        ).install(source: source, destination: destination, backupDirectory: backups)

        XCTAssertEqual(outcome.installed.path, destination.path)
        XCTAssertNil(outcome.previousBackup)
        XCTAssertNotNil(verified)
        XCTAssertEqual(launched?.path, destination.path)
        XCTAssertEqual(marker(of: destination), "new")
        XCTAssertEqual(marker(of: source), "new", "the source is copied, never moved")
        XCTAssertEqual(try stagingLeftovers(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path), "no backup folder without a previous copy")
    }

    func testUpgradeKeepsPreviousVersionAndPrunesOlderBackups() throws {
        try makeBundle(at: destination, version: "1.2.1", marker: "old")
        let source = try makeBundle(at: root.appendingPathComponent("VoicePop.app"), version: "1.3.0", marker: "new")
        // An older backup and an old failed copy from an earlier attempt must be pruned.
        try makeBundle(at: backups.appendingPathComponent("VoicePop-1.1.3.app"), version: "1.1.3", marker: "older")
        try makeBundle(at: backups.appendingPathComponent("VoicePop-1.2.0-failed.app"), version: "1.2.0", marker: "failed")
        try Data("keep".utf8).write(to: backups.appendingPathComponent("notes.txt"))

        let outcome = try installer().install(source: source, destination: destination, backupDirectory: backups)

        let expectedBackup = backups.appendingPathComponent("VoicePop-1.2.1.app")
        XCTAssertEqual(outcome.previousBackup?.path, expectedBackup.path)
        XCTAssertEqual(marker(of: destination), "new")
        XCTAssertEqual(marker(of: expectedBackup), "old", "the replaced copy is kept intact")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        XCTAssertEqual(remaining, ["VoicePop-1.2.1.app", "notes.txt"], "only the newest backup survives; unrelated files are untouched")
        XCTAssertEqual(try stagingLeftovers(), [])
    }

    func testUpgradeOverExistingBackupOfSameVersionReplacesIt() throws {
        try makeBundle(at: destination, version: "1.2.1", marker: "old")
        try makeBundle(at: backups.appendingPathComponent("VoicePop-1.2.1.app"), version: "1.2.1", marker: "stale-backup")
        let source = try makeBundle(at: root.appendingPathComponent("VoicePop.app"), version: "1.2.1", marker: "reinstall")

        _ = try installer().install(source: source, destination: destination, backupDirectory: backups)

        XCTAssertEqual(marker(of: destination), "reinstall")
        XCTAssertEqual(marker(of: backups.appendingPathComponent("VoicePop-1.2.1.app")), "old")
    }

    func testBackupNameFallsBackToTimestampWithoutReadableVersion() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("Contents/MacOS/VoicePop"))
        let source = try makeBundle(at: root.appendingPathComponent("VoicePop.app"), version: "1.3.0", marker: "new")
        var i = installer()
        i.now = { Date(timeIntervalSince1970: 1_700_000_000) }

        let outcome = try i.install(source: source, destination: destination, backupDirectory: backups)

        XCTAssertEqual(outcome.previousBackup?.lastPathComponent, "VoicePop-1700000000.app")
        XCTAssertEqual(marker(of: outcome.previousBackup!), "old")
    }

    // MARK: - Failure paths

    func testMissingSourceChangesNothing() throws {
        try makeBundle(at: destination, version: "1.2.1", marker: "old")
        let source = root.appendingPathComponent("nowhere/VoicePop.app")
        var launched = false

        XCTAssertThrowsError(try installer(launch: { _ in launched = true })
            .install(source: source, destination: destination, backupDirectory: backups)) { error in
            let message = (error as? AppInstaller.Failure)?.message ?? ""
            XCTAssertTrue(message.contains("Nothing was changed"), message)
        }
        XCTAssertEqual(marker(of: destination), "old")
        XCTAssertFalse(launched)
        XCTAssertEqual(try stagingLeftovers(), [])
    }

    func testCopyFailureLeavesExistingCopyAndNoStagingBehind() throws {
        try makeBundle(at: destination, version: "1.2.1", marker: "old")
        let source = try makeBundle(at: root.appendingPathComponent("VoicePop.app"), version: "1.3.0", marker: "new")
        // A read-only Applications folder makes the staging copy fail before anything else runs.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: applications.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: applications.path) }
        var verified = false

        XCTAssertThrowsError(try installer(verify: { _ in verified = true })
            .install(source: source, destination: destination, backupDirectory: backups)) { error in
            let message = (error as? AppInstaller.Failure)?.message ?? ""
            XCTAssertTrue(message.hasPrefix("Couldn’t copy VoicePop.app into Applications"), message)
            XCTAssertTrue(message.contains("Nothing was changed"), message)
        }
        XCTAssertFalse(verified, "verification never runs on a copy that failed")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: applications.path)
        XCTAssertEqual(marker(of: destination), "old")
        XCTAssertEqual(try stagingLeftovers(), [])
    }

    func testVerificationFailureDiscardsStagedCopyAndKeepsExisting() throws {
        try makeBundle(at: destination, version: "1.2.1", marker: "old")
        let source = try makeBundle(at: root.appendingPathComponent("VoicePop.app"), version: "1.3.0", marker: "new")
        var launched = false

        XCTAssertThrowsError(try installer(
            verify: { _ in throw AppInstaller.Failure("code signature is invalid") },
            launch: { _ in launched = true }
        ).install(source: source, destination: destination, backupDirectory: backups)) { error in
            let message = (error as? AppInstaller.Failure)?.message ?? ""
            XCTAssertTrue(message.contains("failed verification: code signature is invalid"), message)
            XCTAssertTrue(message.contains("nothing was changed"), message)
        }
        XCTAssertEqual(marker(of: destination), "old")
        XCTAssertFalse(launched)
        XCTAssertEqual(try stagingLeftovers(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path), "the previous copy is never moved when verification fails")
    }

    func testSwapFailureRestoresPreviousCopy() throws {
        try makeBundle(at: destination, version: "1.2.1", marker: "old")
        let source = try makeBundle(at: root.appendingPathComponent("VoicePop.app"), version: "1.3.0", marker: "new")
        var launched = false
        // Verification passes but the staged bundle disappears before the rename (simulating a
        // volume or permissions problem between the two steps), so the swap itself fails.
        XCTAssertThrowsError(try installer(
            verify: { url in try FileManager.default.removeItem(at: url) },
            launch: { _ in launched = true }
        ).install(source: source, destination: destination, backupDirectory: backups)) { error in
            let message = (error as? AppInstaller.Failure)?.message ?? ""
            XCTAssertTrue(message.contains("previous version was put back at \(self.destination.path)"), message)
        }
        XCTAssertEqual(marker(of: destination), "old", "the previous copy is back in place")
        XCTAssertFalse(launched)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path), [], "the backup was moved back, not duplicated")
        XCTAssertEqual(try stagingLeftovers(), [])
    }

    func testLaunchFailureWithPreviousCopyRollsBackAndKeepsFailedCopy() throws {
        try makeBundle(at: destination, version: "1.2.1", marker: "old")
        let source = try makeBundle(at: root.appendingPathComponent("VoicePop.app"), version: "1.3.0", marker: "new")

        XCTAssertThrowsError(try installer(
            launch: { _ in throw AppInstaller.Failure("no VoicePop process appeared within 5 seconds") }
        ).install(source: source, destination: destination, backupDirectory: backups)) { error in
            let message = (error as? AppInstaller.Failure)?.message ?? ""
            XCTAssertTrue(message.contains("did not start: no VoicePop process appeared"), message)
            XCTAssertTrue(message.contains("previous version was put back at \(self.destination.path)"), message)
            XCTAssertTrue(message.contains("VoicePop-1.3.0-failed.app"), message)
        }
        XCTAssertEqual(marker(of: destination), "old")
        XCTAssertEqual(marker(of: backups.appendingPathComponent("VoicePop-1.3.0-failed.app")), "new", "the copy that didn't start is kept for inspection")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.appendingPathComponent("VoicePop-1.2.1.app").path), "the backup was moved back, not left as a duplicate")
        XCTAssertEqual(try stagingLeftovers(), [])
    }

    func testLaunchFailureOnFirstInstallLeavesNewCopyInstalled() throws {
        let source = try makeBundle(at: root.appendingPathComponent("VoicePop.app"), version: "1.3.0", marker: "new")

        XCTAssertThrowsError(try installer(
            launch: { _ in throw AppInstaller.Failure("timed out") }
        ).install(source: source, destination: destination, backupDirectory: backups)) { error in
            let message = (error as? AppInstaller.Failure)?.message ?? ""
            XCTAssertTrue(message.contains("was installed at \(self.destination.path) but did not start"), message)
            XCTAssertTrue(message.contains("Open it from Applications yourself"), message)
        }
        XCTAssertEqual(marker(of: destination), "new", "with nothing to roll back to, the installed copy stays for a manual open")
        XCTAssertEqual(try stagingLeftovers(), [])
    }

    func testFailureMessagesAreUserFacing() {
        let failure = AppInstaller.Failure("Couldn’t copy VoicePop.app into Applications: disk full. Nothing was changed.")
        XCTAssertEqual(failure.localizedDescription, failure.message)
    }
}
