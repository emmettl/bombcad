// Draws RoomCAD's icon: a room in plan on a dark tile, with a source sending out wavefronts and one
// path reflecting off a wall to a listener.
// Writes RoomCAD/Support/AppIcon.icns, and with --preview FILE.png also a 1024-pixel preview.
//
//     swift RoomCAD/Scripts/make-icon.swift
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
    context.setFillColor(colour(0x10202b))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let background = CGGradient(
        colorsSpace: nil, colors: [colour(0x214257), colour(0x0b151d)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // The room's interior and walls.
    let room = CGRect(x: 214, y: 254, width: 596, height: 516)
    let roomPath = CGPath(roundedRect: room, cornerWidth: 14, cornerHeight: 14, transform: nil)
    context.addPath(roomPath)
    context.setFillColor(colour(0x0d1a23, 0.85))
    context.fillPath()

    let source = CGPoint(x: 372, y: 462)
    let listener = CGPoint(x: 668, y: 392)

    // Wavefronts spreading from the source, fading with distance, inside the walls.
    context.saveGState()
    context.addPath(roomPath)
    context.clip()
    let glow = CGGradient(
        colorsSpace: nil, colors: [colour(0xff9a3c, 0.45), colour(0xff9a3c, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(
        glow, startCenter: source, startRadius: 0, endCenter: source, endRadius: 260, options: [])
    for (index, radius) in [CGFloat(105), 180, 255, 330, 405, 480].enumerated() {
        context.setStrokeColor(colour(0x7fd8ff, 0.75 - CGFloat(index) * 0.12))
        context.setLineWidth(13 - CGFloat(index))
        context.strokeEllipse(
            in: CGRect(x: source.x - radius, y: source.y - radius, width: 2 * radius, height: 2 * radius))
    }
    context.restoreGState()

    // The walls over the wavefronts.
    context.addPath(roomPath)
    context.setStrokeColor(colour(0xe6eef4))
    context.setLineWidth(26)
    context.strokePath()

    // The direct path, faint and dashed, and one path reflected from the far wall, found from the
    // source's image in that wall.
    let wall = room.maxY - 13
    let image = CGPoint(x: source.x, y: 2 * wall - source.y)
    let t = (image.y - wall) / (image.y - listener.y)
    let bounce = CGPoint(x: image.x + (listener.x - image.x) * t, y: wall)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(colour(0xffffff, 0.35))
    context.setLineWidth(8)
    context.setLineDash(phase: 0, lengths: [18, 18])
    context.move(to: source)
    context.addLine(to: listener)
    context.strokePath()
    context.setLineDash(phase: 0, lengths: [])
    context.setStrokeColor(colour(0xffffff, 0.95))
    context.setLineWidth(12)
    context.move(to: source)
    context.addLine(to: bounce)
    context.addLine(to: listener)
    context.strokePath()

    // The source, warm, and the listener, cool, each with a light ring.
    func dot(_ centre: CGPoint, radius: CGFloat, inner: UInt32, outer: UInt32) {
        context.setFillColor(colour(0xffffff))
        context.fillEllipse(
            in: CGRect(
                x: centre.x - radius - 9, y: centre.y - radius - 9, width: 2 * radius + 18,
                height: 2 * radius + 18))
        context.saveGState()
        context.addEllipse(
            in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
        context.clip()
        let fill = CGGradient(
            colorsSpace: nil, colors: [colour(inner), colour(outer)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(
            fill, startCenter: CGPoint(x: centre.x - radius / 3, y: centre.y + radius / 3), startRadius: 0,
            endCenter: centre, endRadius: radius, options: [.drawsAfterEndLocation])
        context.restoreGState()
    }
    dot(source, radius: 40, inner: 0xffd27a, outer: 0xf26a1b)
    dot(listener, radius: 34, inner: 0x9fd4ff, outer: 0x2f7fe0)
    context.restoreGState()
    return context.makeImage()!
}

func png(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--preview"), flag + 1 < arguments.count {
    try png(draw(size: 1024)).write(to: URL(fileURLWithPath: arguments[flag + 1]))
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("RoomCADIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png(draw(size: base * scale)).write(to: iconset.appendingPathComponent(name))
    }
}
let support = root.appendingPathComponent("Support")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", support.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote RoomCAD/Support/AppIcon.icns" : "iconutil failed")
