import AppKit
import SwiftUI

public enum Palette {
    /// Near-white popcorn body.
    public static let puffWhite = NSColor(srgbRed: 0xFF / 255, green: 0xFD / 255, blue: 0xF7 / 255, alpha: 1)
    public static let puffCream = NSColor(srgbRed: 0xFD / 255, green: 0xF7 / 255, blue: 0xEC / 255, alpha: 1)
    public static let puffLight = NSColor(srgbRed: 1.0, green: 0.995, blue: 0.97, alpha: 1)
    public static let puffUnderside = NSColor(srgbRed: 0.88, green: 0.80, blue: 0.64, alpha: 1)
    public static let puffButter = NSColor(srgbRed: 0xF2 / 255, green: 0xC1 / 255, blue: 0x4E / 255, alpha: 1)
    public static let puffShade = NSColor(srgbRed: 0xA8 / 255, green: 0x7C / 255, blue: 0x42 / 255, alpha: 1)
    public static let puffCrease = NSColor(srgbRed: 0x8A / 255, green: 0x5A / 255, blue: 0x2B / 255, alpha: 1)
    public static let hullDark = NSColor(srgbRed: 0x5B / 255, green: 0x38 / 255, blue: 0x18 / 255, alpha: 1)
    public static let hullAmber = NSColor(srgbRed: 0xA8 / 255, green: 0x67 / 255, blue: 0x2A / 255, alpha: 1)
    public static let bagRed = NSColor(srgbRed: 0xC6 / 255, green: 0x36 / 255, blue: 0x2F / 255, alpha: 1)
    public static let bagCream = NSColor(srgbRed: 0xF3 / 255, green: 0xE3 / 255, blue: 0xC3 / 255, alpha: 1)
    public static let bagInterior = NSColor(srgbRed: 0x4A / 255, green: 0x18 / 255, blue: 0x14 / 255, alpha: 1)
}

/// SwiftUI mirrors of `Palette`, allocated once. `Color(nsColor:)` is a value conversion, so a
/// cached value is indistinguishable from a fresh one — this is pixel-identical by construction.
public enum PaletteUI {
    public static let puffWhite = Color(nsColor: Palette.puffWhite)
    public static let puffCream = Color(nsColor: Palette.puffCream)
    public static let puffLight = Color(nsColor: Palette.puffLight)
    public static let puffUnderside = Color(nsColor: Palette.puffUnderside)
    public static let puffButter = Color(nsColor: Palette.puffButter)
    public static let puffShade = Color(nsColor: Palette.puffShade)
    public static let puffCrease = Color(nsColor: Palette.puffCrease)
    public static let hullDark = Color(nsColor: Palette.hullDark)
    public static let hullAmber = Color(nsColor: Palette.hullAmber)
    public static let bagRed = Color(nsColor: Palette.bagRed)
    public static let bagCream = Color(nsColor: Palette.bagCream)
    public static let bagInterior = Color(nsColor: Palette.bagInterior)

    public static let kernelBase = Gradient(colors: [puffWhite, puffCream, puffUnderside])
    public static let lobeHighlight = Gradient(colors: [.white.opacity(0.50), .clear])
    public static let hull = Gradient(colors: [hullAmber, hullDark])
}
