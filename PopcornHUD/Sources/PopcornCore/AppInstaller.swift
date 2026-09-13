import Foundation

/// Stage-verify-swap installer for replacing an app bundle in place (first install from a DMG
/// or Downloads, and upgrades over an existing copy). Pure file work with injected `verify` and
/// `launch` steps so every failure path is unit-testable against fake bundles in a temp
/// directory.
///
/// Guarantees, in order:
/// 1. The replacement is copied to a hidden staging bundle *beside* `destination` (same volume,
///    so the final step is a rename) and verified there. Until verification passes, nothing at
///    `destination` is touched.
/// 2. An existing copy is moved to `backupDirectory` before the staged copy is renamed into
///    place. If that rename fails, the previous copy is put back.
/// 3. `launch` runs against the installed copy. If it throws and a previous copy exists, the
///    previous copy is restored and the failed copy is kept under `backupDirectory` for
///    inspection. Without a previous copy the new bundle is left installed so the user can open
///    it by hand.
/// 4. Only the most recent backup is retained.
///
/// Every thrown `Failure.message` says what state the Mac was left in and what to do next.
public struct AppInstaller {
    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public struct Outcome: Equatable {
        /// The bundle now installed at `destination`.
        public let installed: URL
        /// Where the previous copy was moved, if there was one.
        public let previousBackup: URL?
    }

    /// Verifies a staged copy before anything at the destination changes. Throw to abort.
    public var verify: (URL) throws -> Void
    /// Launches the installed copy and returns only once it is running. Throw if it did not start.
    public var launch: (URL) throws -> Void
    public var fileManager: FileManager = .default
    public var now: () -> Date = Date.init

    public init(verify: @escaping (URL) throws -> Void, launch: @escaping (URL) throws -> Void) {
        self.verify = verify
        self.launch = launch
    }

    public func install(source: URL, destination: URL, backupDirectory: URL) throws -> Outcome {
        let fm = fileManager
        let appName = destination.lastPathComponent
        let folder = destination.deletingLastPathComponent()
        let folderName = folder.lastPathComponent

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure("The copy of \(appName) to install could not be found at \(source.path). Nothing was changed.")
        }

        // 1. Stage beside the destination so the final step is an atomic same-volume rename.
        let staging = folder.appendingPathComponent(".\(appName).staging-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: source, to: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw Failure("Couldn’t copy \(appName) into \(folderName): \(describe(error)). Nothing was changed. Check free disk space and that you can write to \(folder.path), then try again.")
        }

        // 2. Verify the staged copy before anything existing is touched.
        do {
            try verify(staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw Failure("The copied \(appName) failed verification: \(describe(error)). It was discarded and nothing was changed. Download \(appName) again and retry.")
        }

        // 3. Move any existing copy aside, then rename the staged copy into place.
        var backup: URL?
        if fm.fileExists(atPath: destination.path) {
            let target = backupURL(for: destination, in: backupDirectory, suffix: nil)
            do {
                try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: destination, to: target)
                backup = target
            } catch {
                try? fm.removeItem(at: staging)
                throw Failure("Couldn’t move the existing \(appName) aside: \(describe(error)). Nothing was changed. Quit any running copy of \(appName), then try again.")
            }
        }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            let swapError = describe(error)
            try? fm.removeItem(at: staging)
            if let backup {
                if (try? fm.moveItem(at: backup, to: destination)) != nil {
                    throw Failure("Couldn’t put the new \(appName) in \(folderName): \(swapError). The previous version was put back at \(destination.path) and is unchanged.")
                }
                throw Failure("Couldn’t put the new \(appName) in \(folderName): \(swapError). The previous version could not be put back either; it is at \(backup.path). Drag it back into \(folderName), or drag the downloaded \(appName) there yourself.")
            }
            throw Failure("Couldn’t put the new \(appName) in \(folderName): \(swapError). Nothing is installed there. Drag \(appName) into \(folderName) yourself, then open it.")
        }

        // 4. Launch. A copy that does not start is rolled back when there is something to roll
        //    back to.
        do {
            try launch(destination)
        } catch {
            let launchError = describe(error)
            guard let backup else {
                throw Failure("\(appName) was installed at \(destination.path) but did not start: \(launchError). Open it from \(folderName) yourself. If it still won’t open, download it again.")
            }
            let failed = backupURL(for: destination, in: backupDirectory, suffix: "failed")
            if fm.fileExists(atPath: failed.path) { try? fm.removeItem(at: failed) }
            let movedFailedAside = (try? fm.moveItem(at: destination, to: failed)) != nil
            if movedFailedAside, (try? fm.moveItem(at: backup, to: destination)) != nil {
                throw Failure("The new \(appName) did not start: \(launchError). The previous version was put back at \(destination.path); open it from \(folderName). The copy that didn’t start is at \(failed.path).")
            }
            throw Failure("The new \(appName) did not start: \(launchError). The previous version is at \(backup.path) and could not be put back automatically. Drag it into \(folderName) to recover.")
        }

        if let backup { pruneBackups(in: backupDirectory, keeping: backup, appName: appName) }
        return Outcome(installed: destination, previousBackup: backup)
    }

    // MARK: - Helpers

    /// `VoicePop-1.2.0.app`, `VoicePop-1.2.0-failed.app`, or a timestamp when the bundle has no
    /// readable version, so a backup name says which build it holds.
    func backupURL(for bundle: URL, in directory: URL, suffix: String?) -> URL {
        let base = bundle.deletingPathExtension().lastPathComponent
        let ext = bundle.pathExtension
        var tag = bundleVersion(bundle) ?? String(Int(now().timeIntervalSince1970))
        if let suffix { tag += "-\(suffix)" }
        let name = ext.isEmpty ? "\(base)-\(tag)" : "\(base)-\(tag).\(ext)"
        return directory.appendingPathComponent(name)
    }

    func bundleVersion(_ bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = dict["CFBundleShortVersionString"] as? String,
              !version.isEmpty, !version.contains("/")
        else { return nil }
        return version
    }

    /// Keeps `keeping` and deletes other `<AppName>-*.app` backups (including old `-failed`
    /// copies) so the backup folder never grows without bound.
    func pruneBackups(in directory: URL, keeping: URL, appName: String) {
        let base = (appName as NSString).deletingPathExtension + "-"
        let ext = (appName as NSString).pathExtension
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix(base) && item.pathExtension == ext {
            if item.standardizedFileURL == keeping.standardizedFileURL { continue }
            try? fileManager.removeItem(at: item)
        }
    }

    private func describe(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.message }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, !underlying.localizedDescription.isEmpty,
           ns.domain == NSCocoaErrorDomain {
            return "\(ns.localizedDescription) (\(underlying.localizedDescription))"
        }
        return ns.localizedDescription
    }
}
