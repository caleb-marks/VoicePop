import CoreGraphics
import PopcornCore
import SwiftUI

/// Calm, code-native 2.5D illustration of Nandor, separate from the snack renderer.
public enum BeagleArt {
    private enum Coat {
        static let tan = Color(red: 0.63, green: 0.35, blue: 0.18)
        static let tanLight = Color(red: 0.92, green: 0.66, blue: 0.38)
        static let saddle = Color(red: 0.16, green: 0.075, blue: 0.045)
        static let saddleHi = Color(red: 0.25, green: 0.12, blue: 0.07)
        static let white = Color(red: 0.98, green: 0.95, blue: 0.88)
        static let tick = Color(red: 0.25, green: 0.20, blue: 0.17)
        static let eye = Color(red: 0.16, green: 0.075, blue: 0.035)
        static let pupil = Color(red: 0.025, green: 0.015, blue: 0.012)
        static let nose = Color(red: 0.035, green: 0.025, blue: 0.022)
        static let tongue = Color(red: 0.86, green: 0.35, blue: 0.40)
    }

    public static func drawScene(ctx: inout GraphicsContext, cx: CGFloat, bagTop: CGFloat, bagBottom: CGFloat, scene: PopcornRenderer.SceneInput) {
        let quiet = scene.reduceMotion
        let heat = CGFloat(min(1, max(0, scene.mood ?? scene.heat)))
        let breath = quiet ? 0 : CGFloat(sin(scene.bobPhase * 2.0)) * (0.8 + heat * 0.8)
        let wag = quiet ? 0 : CGFloat(sin(scene.bobPhase * 3.4)) * (2.0 + heat * 5.0)
        let lift = quiet ? 0 : heat * 1.5
        let bodyBottom = bagBottom - 2
        let headTop = bagTop - 11 + breath * 0.25 - lift
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 48, y: bodyBottom - 4, width: 96, height: 12)), with: .radialGradient(Gradient(colors: [.black.opacity(0.18), .clear]), center: CGPoint(x: cx, y: bodyBottom), startRadius: 2, endRadius: 52))
        drawTail(ctx: &ctx, cx: cx, y: bagTop + 73, bottom: bodyBottom, wag: wag)
        drawBody(ctx: &ctx, cx: cx, top: bagTop + 45 - lift, bottom: bodyBottom)
        drawEar(ctx: &ctx, cx: cx, top: headTop + 26, side: -1, sway: quiet ? 0 : wag * 0.20)
        drawEar(ctx: &ctx, cx: cx, top: headTop + 26, side: 1, sway: quiet ? 0 : -wag * 0.16)
        drawHead(ctx: &ctx, cx: cx, top: headTop)
        drawFace(ctx: &ctx, cx: cx, top: headTop, pant: heat > 0.48 ? heat : 0)
        PopcornRenderer.drawCapsule(ctx: &ctx, cx: cx, y: bodyBottom + Tunables.capsuleH / 2 + 6, label: scene.label, bobPhase: scene.bobPhase, reduceMotion: scene.reduceMotion, showDot: scene.showRecordingDot)
        if !scene.detail.isEmpty { ctx.draw(Text(scene.detail).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(Coat.tan), at: CGPoint(x: cx, y: bodyBottom + Tunables.capsuleH + 16), anchor: .center) }
    }

    private static func drawBody(ctx: inout GraphicsContext, cx: CGFloat, top: CGFloat, bottom: CGFloat) {
        var chest = Path(); chest.move(to: CGPoint(x: cx - 33, y: top + 10)); chest.addQuadCurve(to: CGPoint(x: cx + 33, y: top + 10), control: CGPoint(x: cx, y: top - 7)); chest.addCurve(to: CGPoint(x: cx + 40, y: bottom), control1: CGPoint(x: cx + 35, y: top + 46), control2: CGPoint(x: cx + 31, y: bottom - 5)); chest.addLine(to: CGPoint(x: cx - 40, y: bottom)); chest.addCurve(to: CGPoint(x: cx - 33, y: top + 10), control1: CGPoint(x: cx - 31, y: bottom - 5), control2: CGPoint(x: cx - 35, y: top + 46)); chest.closeSubpath()
        ctx.fill(chest, with: .linearGradient(Gradient(colors: [Coat.saddleHi, Coat.saddle]), startPoint: CGPoint(x: cx - 40, y: top), endPoint: CGPoint(x: cx + 40, y: bottom)))
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 39, y: top + 24, width: 27, height: 52)), with: .radialGradient(Gradient(colors: [Coat.saddleHi.opacity(0.95), Coat.saddle.opacity(0.30)]), center: CGPoint(x: cx - 24, y: top + 39), startRadius: 1, endRadius: 28))
        ctx.fill(Path(ellipseIn: CGRect(x: cx + 12, y: top + 24, width: 27, height: 52)), with: .radialGradient(Gradient(colors: [Coat.saddleHi.opacity(0.95), Coat.saddle.opacity(0.30)]), center: CGPoint(x: cx + 24, y: top + 39), startRadius: 1, endRadius: 28))
        // White forelegs overlap the chest so the paws read as joined anatomy.
        for side in sides {
            let leg = CGRect(x: cx + side * 21 - 10, y: top + 54, width: 20, height: bottom - top - 43)
            ctx.fill(Path(roundedRect: leg, cornerRadius: 9), with: .linearGradient(Gradient(colors: [Coat.white, Coat.white.opacity(0.76)]), startPoint: CGPoint(x: leg.midX, y: leg.minY), endPoint: CGPoint(x: leg.midX, y: leg.maxY)))
            ctx.stroke(Path(roundedRect: leg, cornerRadius: 9), with: .color(Coat.saddle.opacity(0.55)), lineWidth: 1.2)
        }
        var bib = Path(); bib.move(to: CGPoint(x: cx - 23, y: top + 18)); bib.addQuadCurve(to: CGPoint(x: cx + 23, y: top + 18), control: CGPoint(x: cx, y: top + 32)); bib.addLine(to: CGPoint(x: cx + 25, y: bottom)); bib.addLine(to: CGPoint(x: cx - 25, y: bottom)); bib.closeSubpath()
        ctx.fill(bib, with: .linearGradient(Gradient(colors: [Coat.white, Coat.white.opacity(0.72)]), startPoint: CGPoint(x: cx, y: top), endPoint: CGPoint(x: cx, y: bottom)))
        drawTicks(ctx: &ctx, origin: CGPoint(x: cx, y: top + 53), spread: 24, count: 18)
        for side in sides { let paw = CGRect(x: cx + side * 21 - 10, y: bottom - 28, width: 20, height: 29); ctx.fill(Path(roundedRect: paw, cornerRadius: 8), with: .linearGradient(Gradient(colors: [Coat.white, Coat.white.opacity(0.72)]), startPoint: CGPoint(x: paw.midX, y: paw.minY), endPoint: CGPoint(x: paw.midX, y: paw.maxY))); ctx.stroke(Path(roundedRect: paw, cornerRadius: 8), with: .color(Coat.saddle.opacity(0.75)), lineWidth: 1.4) }
    }

    private static let sides: [CGFloat] = [-1, 1]
    private static let tickSpots: [(CGFloat, CGFloat)] = [(-0.7,-0.2),(0.35,0.12),(0.05,-0.55),(-0.2,0.45),(0.65,-0.35),(-0.6,0.28),(0.25,0.6),(-0.35,-0.7),(0.7,0.2),(-0.05,0.05),(0.48,-0.6),(-0.72,-0.12),(0.18,-0.25),(-0.45,0.7),(0.62,0.45),(-0.12,0.8),(0.36,0.3),(-0.55,-0.5)]

    private static func drawTail(ctx: inout GraphicsContext, cx: CGFloat, y: CGFloat, bottom: CGFloat, wag: CGFloat) {
        let root = CGPoint(x: cx + 33, y: y); var p = Path(); p.move(to: root); p.addCurve(to: CGPoint(x: cx + 61 + wag, y: bottom - 40), control1: CGPoint(x: cx + 67 + wag, y: y + 5), control2: CGPoint(x: cx + 67 + wag, y: bottom - 63)); p.addCurve(to: CGPoint(x: cx + 48, y: y + 7), control1: CGPoint(x: cx + 56, y: bottom - 25), control2: CGPoint(x: cx + 47, y: y + 28)); p.closeSubpath(); ctx.fill(p, with: .linearGradient(Gradient(colors: [Coat.saddleHi, Coat.saddle]), startPoint: root, endPoint: CGPoint(x: root.x + 35, y: bottom))); ctx.fill(Path(ellipseIn: CGRect(x: cx + 54 + wag, y: bottom - 48, width: 11, height: 14)), with: .color(Coat.white)); ctx.stroke(p, with: .color(Coat.saddle), lineWidth: 1.6)
    }

    private static func drawEar(ctx: inout GraphicsContext, cx: CGFloat, top: CGFloat, side: CGFloat, sway: CGFloat) {
        let a = CGPoint(x: cx + side * 42, y: top); var e = Path(); e.move(to: CGPoint(x: a.x - side * 7, y: a.y)); e.addCurve(to: CGPoint(x: a.x + side * 23 + sway, y: a.y + 83), control1: CGPoint(x: a.x + side * 40 + sway, y: a.y + 20), control2: CGPoint(x: a.x + side * 35 + sway, y: a.y + 70)); e.addCurve(to: CGPoint(x: a.x - side * 5, y: a.y + 88), control1: CGPoint(x: a.x + side * 9, y: a.y + 99), control2: CGPoint(x: a.x - side * 3, y: a.y + 94)); e.addCurve(to: CGPoint(x: a.x - side * 7, y: a.y), control1: CGPoint(x: a.x - side * 17, y: a.y + 45), control2: CGPoint(x: a.x - side * 18, y: a.y + 12)); e.closeSubpath(); ctx.fill(e, with: .linearGradient(Gradient(colors: [Coat.tanLight, Coat.tan]), startPoint: CGPoint(x: a.x, y: a.y), endPoint: CGPoint(x: a.x + side * 15, y: a.y + 88))); ctx.fill(Path(ellipseIn: CGRect(x: a.x + side * 4 - 10, y: a.y + 48, width: 20, height: 30)), with: .color(Coat.saddle.opacity(0.45))); ctx.stroke(e, with: .color(Coat.saddle), lineWidth: 2)
    }

    private static func drawHead(ctx: inout GraphicsContext, cx: CGFloat, top: CGFloat) {
        let skull = CGRect(x: cx - 51, y: top, width: 102, height: 88); ctx.fill(Path(ellipseIn: skull), with: .linearGradient(Gradient(colors: [Coat.tanLight, Coat.tan]), startPoint: CGPoint(x: cx - 35, y: top), endPoint: CGPoint(x: cx + 40, y: top + 90)))
        ctx.drawLayer { layer in layer.clip(to: Path(ellipseIn: skull)); layer.fill(Path(ellipseIn: CGRect(x: cx - 53, y: top - 12, width: 106, height: 48)), with: .linearGradient(Gradient(colors: [Coat.saddleHi, Coat.saddle]), startPoint: CGPoint(x: cx, y: top - 8), endPoint: CGPoint(x: cx, y: top + 38))) }
        var blaze = Path(); blaze.move(to: CGPoint(x: cx - 6, y: top - 2)); blaze.addCurve(to: CGPoint(x: cx + 6, y: top - 2), control1: CGPoint(x: cx - 1, y: top - 8), control2: CGPoint(x: cx + 2, y: top - 8)); blaze.addCurve(to: CGPoint(x: cx + 17, y: top + 54), control1: CGPoint(x: cx + 9, y: top + 18), control2: CGPoint(x: cx + 16, y: top + 35)); blaze.addCurve(to: CGPoint(x: cx - 18, y: top + 54), control1: CGPoint(x: cx + 2, y: top + 67), control2: CGPoint(x: cx - 14, y: top + 67)); blaze.addCurve(to: CGPoint(x: cx - 6, y: top - 2), control1: CGPoint(x: cx - 16, y: top + 35), control2: CGPoint(x: cx - 9, y: top + 18)); blaze.closeSubpath(); ctx.fill(blaze, with: .color(Coat.white)); ctx.stroke(Path(ellipseIn: skull), with: .color(Coat.saddle), lineWidth: 2.3)
    }

    private static func drawFace(ctx: inout GraphicsContext, cx: CGFloat, top: CGFloat, pant: CGFloat) {
        let eyeY = top + 34
        for side in sides { let ex = cx + side * 20; let eye = CGRect(x: ex - 11, y: eyeY - 7, width: 22, height: 16); ctx.fill(Path(ellipseIn: eye.insetBy(dx: -2, dy: -2)), with: .color(Coat.white.opacity(0.85))); ctx.fill(Path(ellipseIn: eye), with: .radialGradient(Gradient(colors: [Coat.eye, Coat.pupil]), center: CGPoint(x: ex - side * 3, y: eyeY - 3), startRadius: 0, endRadius: 13)); ctx.fill(Path(ellipseIn: CGRect(x: ex - 2.6, y: eyeY - 3, width: 3.2, height: 3.2)), with: .color(.white.opacity(0.98))); ctx.fill(Path(ellipseIn: CGRect(x: ex + side * 7 - 2, y: eyeY - 18, width: 13, height: 5)), with: .color(Coat.tanLight)) }
        let muzzle = CGRect(x: cx - 27, y: top + 45, width: 54, height: 47); ctx.fill(Path(ellipseIn: muzzle.offsetBy(dx: 2.5, dy: 3)), with: .color(Coat.saddle.opacity(0.34))); ctx.fill(Path(ellipseIn: muzzle), with: .linearGradient(Gradient(colors: [Coat.white, Coat.white.opacity(0.72)]), startPoint: CGPoint(x: cx - 12, y: top + 44), endPoint: CGPoint(x: cx + 17, y: top + 92))); ctx.fill(Path(ellipseIn: CGRect(x: cx - 14, y: top + 49, width: 17, height: 9)), with: .color(.white.opacity(0.28))); drawTicks(ctx: &ctx, origin: CGPoint(x: cx, y: top + 73), spread: 15, count: 12)
        let nose = CGRect(x: cx - 12, y: top + 48, width: 24, height: 17); ctx.fill(Path(ellipseIn: nose), with: .color(Coat.nose)); ctx.fill(Path(ellipseIn: CGRect(x: cx - 6, y: top + 51, width: 6, height: 3)), with: .color(.white.opacity(0.42))); ctx.stroke(Path(ellipseIn: muzzle), with: .color(Coat.saddle.opacity(0.28)), lineWidth: 1.2)
        let mouthY = top + 76; var mouth = Path(); mouth.move(to: CGPoint(x: cx - 10, y: mouthY)); mouth.addQuadCurve(to: CGPoint(x: cx, y: mouthY + 3), control: CGPoint(x: cx - 5, y: mouthY + 5)); mouth.addQuadCurve(to: CGPoint(x: cx + 10, y: mouthY), control: CGPoint(x: cx + 5, y: mouthY + 5)); ctx.stroke(mouth, with: .color(Coat.saddle), lineWidth: 1.8)
        if pant > 0 { let tongue = CGRect(x: cx - 6, y: mouthY + 2, width: 12, height: 7 + 8 * pant); ctx.fill(Path(ellipseIn: tongue), with: .color(Coat.tongue)); ctx.stroke(Path(ellipseIn: tongue), with: .color(Coat.saddle.opacity(0.65)), lineWidth: 1) }
    }

    private static func drawTicks(ctx: inout GraphicsContext, origin: CGPoint, spread: CGFloat, count: Int) { let spots = tickSpots; for i in 0..<min(count, spots.count) { let s = spots[i]; let r: CGFloat = i.isMultiple(of: 4) ? 1.5 : 1.1; ctx.fill(Path(ellipseIn: CGRect(x: origin.x + s.0 * spread - r, y: origin.y + s.1 * spread - r, width: r * 2, height: r * 1.5)), with: .color(Coat.tick.opacity(0.58))) } }
}
