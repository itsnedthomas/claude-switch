// Stopwatch + Claude-style spark, with glass finishes. Usage: swift icon-glass.swift <outdir>
import AppKit

let S: CGFloat = 1024
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: a)
}

/// The glyph: stopwatch ring with a split segment on the right, crown on top,
/// and the spark with a hollow centre. Drawn in white so it can be used as a mask.
func drawGlyph(_ ctx: CGContext) {
    let c = CGPoint(x: S / 2, y: S / 2 - 48)
    let R: CGFloat = 262, w: CGFloat = 46
    ctx.setStrokeColor(.white); ctx.setFillColor(.white)
    ctx.setLineCap(.round); ctx.setLineWidth(w)
    func arc(_ a0: CGFloat, _ a1: CGFloat) {
        ctx.addArc(center: c, radius: R, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: true)
        ctx.strokePath()
    }
    // Main ring: from 1 o'clock, round the left, to 4 o'clock
    ctx.addArc(center: c, radius: R, startAngle: 70 * .pi / 180, endAngle: 298 * .pi / 180, clockwise: false)
    ctx.strokePath()
    arc(56, 22)                                      // the split segments on the right
    arc(10, -48)
    // Crown: stem and button
    ctx.fill(CGRect(x: S / 2 - 34, y: c.y + R + w / 2 - 6, width: 62, height: 48))
    let btn = CGPath(roundedRect: CGRect(x: S / 2 - 118, y: c.y + R + 52, width: 210, height: 58), cornerWidth: 29, cornerHeight: 29, transform: nil)
    ctx.addPath(btn); ctx.fillPath()
    // Claude's spark (scripts/claude.svg), white, in the middle of the ring
    let svg = NSImage(contentsOfFile: CommandLine.arguments[0].replacingOccurrences(of: "icon-glass.swift", with: "claude.svg"))!
    let side: CGFloat = 330
    // Rasterise the vector at 2x the size it's drawn, so the edges stay smooth.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let r = NSRect(x: 0, y: 0, width: side * 2, height: side * 2)
    svg.draw(in: r)
    NSColor.white.set()
    r.fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()
    ctx.interpolationQuality = .high
    ctx.draw(rep.cgImage!, in: CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side))
}

func glyphMask() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
    drawGlyph(ctx)
    return ctx.makeImage()!
}

let tileRect = CGRect(x: 100, y: 100, width: S - 200, height: S - 200)
let tilePath = CGPath(roundedRect: tileRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

struct Finish {
    var name: String
    var tile: [CGColor]            // top to bottom
    var glyph: [CGColor]           // top to bottom
    var shadow: CGColor
    var glow: CGColor? = nil
    var frosted = false
    var flat = false
}

func render(_ f: Finish, mask: CGImage) -> NSImage {
    NSImage(size: NSSize(width: S, height: S), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        // Tile with drop shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.28))
        ctx.addPath(tilePath); ctx.setFillColor(f.tile[0]); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(tilePath); ctx.clip()
        linear(ctx, f.tile, from: CGPoint(x: 0, y: tileRect.maxY), to: CGPoint(x: 0, y: tileRect.minY))
        // Glass sheen across the top of the tile
        if f.flat {
            // Like Claude's own icon: one solid orange, a plain white glyph.
            ctx.clip(to: CGRect(x: 0, y: 0, width: S, height: S), mask: mask)
            ctx.setFillColor(f.glyph[0]); ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
            ctx.restoreGState()
            return true
        }
        // Soft light from the top left, no hard edge
        let light = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [rgb(0xFFFFFF, 0.20), rgb(0xFFFFFF, 0)] as CFArray, locations: nil)!
        ctx.drawRadialGradient(light, startCenter: CGPoint(x: 300, y: 860), startRadius: 0,
                               endCenter: CGPoint(x: 300, y: 860), endRadius: 620, options: [])
        // Glyph: shadow / glow underneath
        ctx.saveGState()
        if let glow = f.glow { ctx.setShadow(offset: .zero, blur: 46, color: glow) }
        else { ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 14, color: f.shadow) }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.clip(to: CGRect(x: 0, y: 0, width: S, height: S), mask: mask)
        ctx.setFillColor(f.glyph.last!); ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        // Glyph body: gradient, then a bright top light and a soft lower edge, like glass
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: S, height: S), mask: mask)
        linear(ctx, f.glyph, from: CGPoint(x: 0, y: 820), to: CGPoint(x: 0, y: 200))
        linear(ctx, [rgb(0xFFFFFF, f.frosted ? 0.55 : 0.35), rgb(0xFFFFFF, 0)], from: CGPoint(x: 260, y: 860), to: CGPoint(x: 560, y: 520))
        ctx.restoreGState()
        // Fine rim on the tile edge
        ctx.addPath(tilePath); ctx.setStrokeColor(rgb(0xFFFFFF, 0.28)); ctx.setLineWidth(3); ctx.strokePath()
        ctx.restoreGState()
        return true
    }
}

let finishes = [
    Finish(name: "G0-flat", tile: [rgb(0xD97757), rgb(0xD97757)], glyph: [rgb(0xFFFFFF)], shadow: rgb(0, 0), flat: true),
    Finish(name: "G1-glass", tile: [rgb(0xEC8A62), rgb(0xC9532F)], glyph: [rgb(0xFFFFFF), rgb(0xFBE7DE)], shadow: rgb(0x7A2A14, 0.45)),
    Finish(name: "G2-frosted", tile: [rgb(0xF0956E), rgb(0xD0603C)], glyph: [rgb(0xFFFFFF, 0.92), rgb(0xFFFFFF, 0.62)], shadow: rgb(0x7A2A14, 0.30), frosted: true),
    Finish(name: "G3-cream", tile: [rgb(0xFFFDF9), rgb(0xF1E9DD)], glyph: [rgb(0xEC8A62), rgb(0xC9532F)], shadow: rgb(0xB0502C, 0.35)),
    Finish(name: "G4-night", tile: [rgb(0x34302D), rgb(0x1B1917)], glyph: [rgb(0xF3A07A), rgb(0xD9673F)], shadow: rgb(0x000000, 0.5), glow: rgb(0xE8743F, 0.55)),
]

let out = CommandLine.arguments[1]
let mask = glyphMask()
var images: [(String, NSImage)] = []
for f in finishes {
    let img = render(f, mask: mask)
    try! NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/\(f.name).png"))
    images.append((f.name, img))
}
let cell: CGFloat = 340
let sheet = NSImage(size: NSSize(width: cell * 4, height: cell + 44), flipped: false) { _ in
    NSColor(white: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: cell * 4, height: cell + 44).fill()
    for (i, (name, img)) in images.enumerated() {
        img.draw(in: NSRect(x: CGFloat(i) * cell, y: 44, width: cell, height: cell))
        let l = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.darkGray])
        l.draw(at: NSPoint(x: CGFloat(i) * cell + cell / 2 - l.size().width / 2, y: 12))
    }
    // Small sizes, as in the Dock and Finder
    return true
}
try! NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "\(out)/glass-sheet.png"))
