import Foundation

/// One definition of "the same speech model" for the menu, Settings, health probes, and setup.
/// The engine can report a packaged variant of a catalog model (for example
/// `parakeet-tdt-0.6b-v3-int8-prepacked` for `parakeet-tdt-0.6b-v3-int8`). Only known packaging
/// suffixes are ignored: a prefix match would wrongly treat `…-v3` as installed when only
/// `…-v3-int8` is, since quantization suffixes name different models.
public enum ModelIdentity {
    public static let packagingSuffixes = ["-prepacked"]

    public static func normalized(_ id: String) -> String {
        var out = id.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in packagingSuffixes where out.hasSuffix(suffix) {
            out.removeLast(suffix.count)
        }
        return out
    }

    public static func same(_ a: String, _ b: String) -> Bool {
        normalized(a) == normalized(b)
    }

    /// True when any installed name is `model` or a packaged variant of it (or vice versa).
    public static func isInstalled(_ model: String, in installed: some Sequence<String>) -> Bool {
        installed.contains { same($0, model) }
    }
}
