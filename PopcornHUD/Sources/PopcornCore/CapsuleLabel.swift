import CoreGraphics
import Foundation

/// Fits a status-capsule label into a fixed width. Labels that already fit are returned
/// untouched (so the common "Recording"/"Transcribing…" paths never change); anything wider is
/// cut to the longest prefix that fits with a trailing ellipsis. Pure and renderer-agnostic:
/// `measure` supplies the text width so this can be unit-tested with a fake.
public enum CapsuleLabel {
    public static let ellipsis = "\u{2026}"

    public static func fitted(_ label: String, maxWidth: CGFloat, measure: (String) -> CGFloat) -> String {
        guard maxWidth > 0 else { return ellipsis }
        if measure(label) <= maxWidth { return label }
        let chars = Array(label)
        // Binary search the longest prefix (whitespace-trimmed) + ellipsis that fits.
        var lo = 0
        var hi = chars.count
        var best = ellipsis
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let candidate = String(chars[0..<mid]).trimmingCharacters(in: .whitespaces) + ellipsis
            if measure(candidate) <= maxWidth {
                best = candidate
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return best
    }
}
