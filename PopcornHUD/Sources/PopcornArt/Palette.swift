import AppKit
import SwiftUI

public enum Palette {
    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    // Legacy kernel and bag tokens. The beagle's status capsule still draws with `bagCream`,
    // `bagRed`, and `puffUnderside`, so these keep their original values; the popcorn kernels
    // use the `kernel*` tokens below.
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

    // Popcorn paperware tokens are intentionally separate from the legacy bag/beagle capsule
    // colors.  The mascot can evolve without changing the dog's established status chrome.
    // Popcorn paperware: rich cinema red on warm ivory.
    public static let popcornPaper = NSColor(srgbRed: 0xF5 / 255, green: 0xED / 255, blue: 0xDC / 255, alpha: 1)
    public static let popcornPaperLight = NSColor(srgbRed: 0xFF / 255, green: 0xF9 / 255, blue: 0xEC / 255, alpha: 1)
    public static let popcornPaperShade = NSColor(srgbRed: 0xD9 / 255, green: 0xC8 / 255, blue: 0xAA / 255, alpha: 1)
    public static let popcornInk = srgb(0xC43037)
    public static let popcornInkShade = srgb(0x7E1F26)
    public static let popcornInterior = srgb(0x5A3A30)
    public static let popcornFineEdge = NSColor(srgbRed: 0xBB / 255, green: 0xA7 / 255, blue: 0x8A / 255, alpha: 1)
    public static let popcornStatusSurface = NSColor(srgbRed: 0xFA / 255, green: 0xF7 / 255, blue: 0xF1 / 255, alpha: 1)
    public static let popcornStatusText = NSColor(srgbRed: 0x34 / 255, green: 0x2F / 255, blue: 0x2C / 255, alpha: 1)
    /// Cinema red, a shade deeper than the tub ink: 5.3:1 against the capsule (was #B44846, 5.0:1).
    public static let popcornRecordingDot = srgb(0xBF2F36)

    // Buttered movie-theater kernels. Creamy lobe highlights, golden midtones where lobes meet,
    // saturated butter glaze, and warm amber undersides; folds are soft golden-brown, not ink.
    public static let kernelHighlight = srgb(0xFFFAEE)
    public static let kernelCream = srgb(0xFAEBCB)
    public static let kernelGolden = srgb(0xEBC47E)
    public static let kernelAmber = srgb(0xC98A3E)
    public static let kernelFold = srgb(0xB47838)
    public static let kernelButter = srgb(0xF0B040)
    public static let kernelButterGlaze = srgb(0xF2BE52)
    public static let kernelButterDeep = srgb(0xDF9320)
    public static let kernelToast = srgb(0xE0AC62)
    public static let kernelHullLight = srgb(0xA86A2E)
    public static let kernelHullDark = srgb(0x6A4221)
    public static let kernelEdge = srgb(0xB0793C)
    public static let kernelShadow = srgb(0x3E230F)
}

/// SwiftUI mirrors of `Palette`, allocated once. `Color(nsColor:)` is a value conversion, so a
/// cached value is indistinguishable from a fresh one - this is pixel-identical by construction.
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
    // Popcorn paperware: rich cinema red on warm ivory.
    public static let popcornPaper = Color(nsColor: Palette.popcornPaper)
    public static let popcornPaperLight = Color(nsColor: Palette.popcornPaperLight)
    public static let popcornPaperShade = Color(nsColor: Palette.popcornPaperShade)
    public static let popcornInk = Color(nsColor: Palette.popcornInk)
    public static let popcornInkShade = Color(nsColor: Palette.popcornInkShade)
    public static let popcornInterior = Color(nsColor: Palette.popcornInterior)
    public static let popcornFineEdge = Color(nsColor: Palette.popcornFineEdge)
    public static let popcornStatusSurface = Color(nsColor: Palette.popcornStatusSurface)
    public static let popcornStatusText = Color(nsColor: Palette.popcornStatusText)
    public static let popcornRecordingDot = Color(nsColor: Palette.popcornRecordingDot)

    /// Scene-space light laid over every kernel silhouette: creamy upper-left, amber underside.
    public static let kernelLight = Gradient(stops: [
        .init(color: Color(nsColor: Palette.kernelHighlight).opacity(0.50), location: 0),
        .init(color: Color(nsColor: Palette.kernelHighlight).opacity(0.0), location: 0.42),
        .init(color: Color(nsColor: Palette.kernelAmber).opacity(0.0), location: 0.55),
        .init(color: Color(nsColor: Palette.kernelAmber).opacity(0.40), location: 1),
    ])
    public static let kernelBase = Gradient(colors: [puffWhite, puffCream, puffUnderside])
    public static let lobeHighlight = Gradient(colors: [.white.opacity(0.50), .clear])
    public static let hull = Gradient(colors: [hullAmber, hullDark])
}
