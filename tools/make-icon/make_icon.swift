// SPDX-License-Identifier: GPL-3.0-or-later
// Renders the MacFrame app icon (all macOS iconset sizes) with CoreGraphics.
// usage: swift tools/make-icon/make_icon.swift <out.iconset> [preview.png]
//        iconutil -c icns <out.iconset> -o app/Resources/AppIcon.icns

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(size px: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024.0
    ctx.scaleBy(x: s, y: s)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS icon grid: 824×824 body centred in a 1024 canvas
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = roundedRect(body, 185)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x1E1B4B))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient (indigo → cyan)
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: cs,
                        colors: [color(0x312E81), color(0x4338CA), color(0x0891B2)] as CFArray,
                        locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 160, y: 924), end: CGPoint(x: 880, y: 100), options: [])
    // Soft highlight glow
    let glow = CGGradient(colorsSpace: cs,
                          colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 800), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 800), endRadius: 520, options: [])
    ctx.restoreGState()

    // Three video frames moving diagonally: past → interpolated → current
    let fw: CGFloat = 380, fh: CGFloat = 260, fr: CGFloat = 52
    let centers: [CGPoint] = [CGPoint(x: 384, y: 420), CGPoint(x: 512, y: 500), CGPoint(x: 640, y: 580)]
    func frameRect(_ c: CGPoint) -> CGRect { CGRect(x: c.x - fw / 2, y: c.y - fh / 2, width: fw, height: fh) }

    // Past frame (outline)
    let past = frameRect(centers[0])
    ctx.addPath(roundedRect(past, fr))
    ctx.setFillColor(color(0xFFFFFF, 0.06))
    ctx.fillPath()
    ctx.addPath(roundedRect(past.insetBy(dx: 10, dy: 10), fr - 10))
    ctx.setStrokeColor(color(0xFFFFFF, 0.38))
    ctx.setLineWidth(20)
    ctx.strokePath()

    // Interpolated frame (cyan, dashed)
    let mid = frameRect(centers[1])
    ctx.addPath(roundedRect(mid, fr))
    ctx.setFillColor(color(0x67E8F9, 0.22))
    ctx.fillPath()
    ctx.saveGState()
    ctx.addPath(roundedRect(mid.insetBy(dx: 10, dy: 10), fr - 10))
    ctx.setStrokeColor(color(0xA5F3FC, 0.9))
    ctx.setLineWidth(20)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [44, 30])
    ctx.strokePath()
    ctx.restoreGState()

    // Current frame (solid white) with a gradient play glyph
    let cur = frameRect(centers[2])
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x0C0A3E, 0.45))
    ctx.addPath(roundedRect(cur, fr))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    let tc = CGPoint(x: cur.midX + 12, y: cur.midY)
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: tc.x - 46, y: tc.y + 64))
    tri.addLine(to: CGPoint(x: tc.x + 66, y: tc.y))
    tri.addLine(to: CGPoint(x: tc.x - 46, y: tc.y - 64))
    tri.closeSubpath()
    ctx.saveGState()
    ctx.addPath(tri)
    ctx.clip()
    let triGrad = CGGradient(colorsSpace: cs, colors: [color(0x4F46E5), color(0x06B6D4)] as CFArray,
                             locations: [0, 1])!
    ctx.drawLinearGradient(triGrad, start: CGPoint(x: tc.x - 46, y: tc.y + 64),
                           end: CGPoint(x: tc.x + 66, y: tc.y - 64), options: [])
    ctx.restoreGState()

    // Sparkle (top-right)
    func sparkle(_ c: CGPoint, _ r: CGFloat, _ alpha: CGFloat) {
        let p = CGMutablePath()
        let k = r * 0.22
        p.move(to: CGPoint(x: c.x, y: c.y + r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + k, y: c.y - k))
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y - k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - k, y: c.y + k))
        ctx.addPath(p)
        ctx.setFillColor(color(0xFFFFFF, alpha))
        ctx.fillPath()
    }
    sparkle(CGPoint(x: 300, y: 760), 58, 0.95)
    sparkle(CGPoint(x: 384, y: 822), 24, 0.7)

    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dst = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: make_icon.swift <out.iconset> [preview.png]")
    exit(2)
}
let outDir = args[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in specs {
    writePNG(render(size: px), outDir + "/" + name)
}
if args.count >= 3 {
    writePNG(render(size: 1024), args[2])
}
print("Wrote iconset to \(outDir)")
