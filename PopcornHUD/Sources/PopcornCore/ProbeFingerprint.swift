import Foundation

/// Cheap change detector for a set of filesystem paths: modification time and size of each, or a
/// marker when the path is missing. Two equal fingerprints mean none of the inputs changed in a way
/// a stat can see, so a result derived only from those inputs can be reused without re-reading them.
public struct ProbeFingerprint: Equatable, Sendable {
    public let entries: [String]

    public init(paths: [String], fileManager: FileManager = .default) {
        entries = paths.map { path in
            guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return "\(path)|missing" }
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            return "\(path)|\(mtime)|\(size)"
        }
    }
}
