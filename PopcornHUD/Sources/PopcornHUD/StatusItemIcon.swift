import AppKit
import PopcornCore

/// Same 🍿 used for the app icon, Dock, and menu bar. Menu bar follows `Mascot`.
enum StatusItemIcon {
    static let emoji = "🍿"
    /// Shared with `scripts/generate-app-icon.swift`. Apple Color Emoji bitmaps cap ~160 px.
    static let emojiScale: CGFloat = 0.92

    static func glyph(for mascot: Mascot) -> String {
        switch mascot {
        case .popcorn: return "🍿"
        case .beagle: return "🐶"
        }
    }

    static func image(pointSize: CGFloat, mascot: Mascot = .popcorn) -> NSImage {
        let glyph = glyph(for: mascot)
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            let fontSize = rect.width * emojiScale
            let font = NSFont(name: "Apple Color Emoji", size: fontSize)
                ?? NSFont.systemFont(ofSize: fontSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let str = NSAttributedString(string: glyph, attributes: [
                .font: font,
                .paragraphStyle: paragraph,
            ])
            let textSize = str.size()
            str.draw(at: CGPoint(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2
            ))
            return true
        }
        image.isTemplate = false
        return image
    }

    static func dockImage() -> NSImage {
        if let named = NSImage(named: "AppIcon"), named.size.width > 0 {
            return named
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icns = NSImage(contentsOf: url) {
            return icns
        }
        return image(pointSize: 128)
    }
}
