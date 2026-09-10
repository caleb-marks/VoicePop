#!/usr/bin/env swift
import AppKit
import Foundation

/// App icon is the popcorn emoji (not the menu-bar template glyph).
func renderPNG(size: Int, url: URL) {
    let px = CGFloat(size)
    let image = NSImage(size: NSSize(width: px, height: px), flipped: false) { rect in
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        let emoji = "🍿"
        // Match StatusItemIcon.emojiScale. Apple Color Emoji bitmaps cap ~160 px;
        // 512/1024 tiles are upscaled and can look soft in Finder Get Info.
        let emojiScale: CGFloat = 0.92
        let font = NSFont(name: "Apple Color Emoji", size: rect.width * emojiScale)
            ?? NSFont.systemFont(ofSize: rect.width * emojiScale)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let str = NSAttributedString(string: emoji, attributes: [
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
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:])
    else {
        fputs("failed to encode PNG \(size)\n", stderr)
        exit(1)
    }
    try! data.write(to: url)
}

let outDir = CommandLine.arguments.dropFirst().first
    ?? FileManager.default.currentDirectoryPath + "/dist/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let dir = URL(fileURLWithPath: outDir)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for (name, px) in specs {
    renderPNG(size: px, url: dir.appendingPathComponent(name))
}
print("iconset \(outDir)")
