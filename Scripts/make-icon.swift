// Draws the app icon, a stylised surface burst: a starburst on the ground inside two shock
// fronts, beside a building, on a dark tile.
// Writes Support/AppIcon.icns.
//
//     swift Scripts/make-icon.swift
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func draw(size: Int) -> CGImage {
    let s = CGFloat(size)
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: s / 1024, y: s / 1024)

    // The tile, inset and rounded as macOS icons are.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: colour(0x000000, 0.35))
    context.addPath(tilePath)
    context.setFillColor(colour(0x1c2230))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let background = CGGradient(
        colorsSpace: nil, colors: [colour(0x2b3446), colour(0x141821)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    let centre = CGPoint(x: 430, y: 252)
    // A warm glow behind everything.
    let glow = CGGradient(
        colorsSpace: nil, colors: [colour(0xff8a2a, 0.55), colour(0xff8a2a, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(
        glow, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 460, options: [])

    // Two shock fronts, the outer one fainter.
    for (radius, alpha, width) in [(CGFloat(500), CGFloat(0.3), CGFloat(16)), (390, 0.65, 20)] {
        context.setStrokeColor(colour(0xffc56b, alpha))
        context.setLineWidth(width)
        context.strokeEllipse(
            in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
    }

    // The burst: a twelve-pointed star with uneven points, filled from yellow to orange.
    func star(points: Int, outer: [CGFloat], inner: CGFloat, turn: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for n in 0..<(2 * points) {
            let angle = turn + CGFloat(n) * .pi / CGFloat(points)
            let r = n % 2 == 0 ? outer[(n / 2) % outer.count] : inner
            let p = CGPoint(x: centre.x + r * cos(angle), y: centre.y + r * sin(angle))
            if n == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
    let outerBurst = star(points: 12, outer: [300, 220, 265, 205], inner: 120, turn: .pi / 2)
    context.saveGState()
    context.addPath(outerBurst)
    context.clip()
    let fire = CGGradient(
        colorsSpace: nil, colors: [colour(0xfff1b8), colour(0xffb02e), colour(0xf2541b)] as CFArray,
        locations: [0, 0.45, 1])!
    context.drawRadialGradient(
        fire, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 300, options: [])
    context.restoreGState()
    // A bright core.
    let core = CGGradient(
        colorsSpace: nil, colors: [colour(0xfffdf2), colour(0xfffdf2, 0.9), colour(0xfff1b8, 0)] as CFArray,
        locations: [0, 0.55, 1])!
    context.drawRadialGradient(
        core, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 130, options: [])

    // A building beside it, lit on the face towards the blast.
    let building = CGRect(x: 738, y: 252, width: 120, height: 210)
    context.setFillColor(colour(0x0e1118))
    context.fill(building)
    context.setFillColor(colour(0xffb02e, 0.9))
    context.fill(CGRect(x: building.minX, y: building.minY, width: 12, height: building.height))
    context.setFillColor(colour(0x2b3446))
    for row in 0..<3 {
        for column in 0..<2 {
            context.fill(
                CGRect(
                    x: building.minX + 34 + CGFloat(column) * 46, y: building.minY + 40 + CGFloat(row) * 56,
                    width: 26, height: 30))
        }
    }

    // The ground the blast sits on.
    context.setFillColor(colour(0x0e1118))
    context.fill(CGRect(x: 100, y: 100, width: 824, height: 150))
    context.setFillColor(colour(0xffc56b, 0.6))
    context.fill(CGRect(x: 100, y: 246, width: 824, height: 6))
    context.restoreGState()
    return context.makeImage()!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: draw(size: base * scale))
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let support = root.appendingPathComponent("Support")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", support.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote Support/AppIcon.icns" : "iconutil failed")
