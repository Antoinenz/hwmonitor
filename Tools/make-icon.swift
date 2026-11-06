#!/usr/bin/env swift
// Renders the Hardware Monitor app icon at every size macOS needs.
//
// Usage:  swift Tools/make-icon.swift
//
// Writes the PNGs and Contents.json into the app's AppIcon.appiconset, and a
// large preview into docs/images/icon.png. Everything is drawn with
// CoreGraphics so the icon can be tweaked and regenerated without a design tool.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let iconSet = root.appendingPathComponent("Hardware Monitor/Assets.xcassets/AppIcon.appiconset")
let previewDir = root.appendingPathComponent("docs/images")

// MARK: - Palette (matches the app's data colours)

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}

let blue = rgb(0.25, 0.56, 1.0)
let purple = rgb(0.62, 0.40, 1.0)
let pink = rgb(1.0, 0.36, 0.64)
let orange = rgb(1.0, 0.62, 0.22)

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

// MARK: - Shapes

/// Apple-style continuous-corner square (a superellipse), centred in `rect`.
func squircle(_ rect: CGRect, exponent n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 360
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Smooth curve through `points` (Catmull-Rom converted to Béziers).
func smoothPath(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard points.count > 1 else { return path }
    path.move(to: points[0])
    for i in 0..<points.count - 1 {
        let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: c1, control2: c2)
    }
    return path
}

// MARK: - Drawing (1024 × 1024 design space)

func draw(in ctx: CGContext) {
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let body = canvas.insetBy(dx: 100, dy: 100) // macOS icon grid: 824 pt tile on a 1024 canvas
    let tile = squircle(body)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(rgb(0.1, 0.11, 0.14))
    ctx.fillPath()
    ctx.restoreGState()

    // Tile background.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(0.20, 0.22, 0.29), rgb(0.07, 0.08, 0.11)]),
        start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    // Soft coloured bloom behind the chip.
    ctx.drawRadialGradient(
        gradient([rgb(0.40, 0.36, 0.95, 0.30), rgb(0.40, 0.36, 0.95, 0)]),
        startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 500), endRadius: 420, options: [])
    // Top-edge sheen.
    ctx.drawLinearGradient(
        gradient([rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0)]),
        start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.maxY - 220), options: [])
    ctx.restoreGState()

    // Hairline rim on the tile.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // Chip.
    let chip = CGRect(x: 512 - 225, y: 512 - 225, width: 450, height: 450)
    let chipRadius: CGFloat = 82

    // Pins (drawn first so the body overlaps their roots).
    let pinCount = 4
    let pinW: CGFloat = 30, pinL: CGFloat = 58
    let pitch = chip.width / CGFloat(pinCount + 1) * 1.0
    ctx.saveGState()
    for i in 1...pinCount {
        let offset = CGFloat(i) * pitch
        let pins = [
            CGRect(x: chip.minX + offset - pinW / 2, y: chip.maxY - 6, width: pinW, height: pinL + 6),
            CGRect(x: chip.minX + offset - pinW / 2, y: chip.minY - pinL, width: pinW, height: pinL + 6),
            CGRect(x: chip.minX - pinL, y: chip.minY + offset - pinW / 2, width: pinL + 6, height: pinW),
            CGRect(x: chip.maxX - 6, y: chip.minY + offset - pinW / 2, width: pinL + 6, height: pinW),
        ]
        for pin in pins {
            ctx.addPath(roundedRect(pin, 9))
            ctx.setFillColor(rgb(0.78, 0.81, 0.90, 0.55))
            ctx.fillPath()
        }
    }
    ctx.restoreGState()

    // Chip body with a lift shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(0, 0, 0, 0.5))
    ctx.addPath(roundedRect(chip, chipRadius))
    ctx.setFillColor(rgb(0.08, 0.09, 0.13))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(roundedRect(chip, chipRadius))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(0.13, 0.15, 0.21), rgb(0.06, 0.07, 0.10)]),
        start: CGPoint(x: 512, y: chip.maxY), end: CGPoint(x: 512, y: chip.minY), options: [])
    ctx.restoreGState()

    // Gradient rim around the chip.
    ctx.saveGState()
    ctx.addPath(roundedRect(chip.insetBy(dx: 5, dy: 5), chipRadius - 5))
    ctx.setLineWidth(10)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([blue, purple, pink, orange], [0, 0.4, 0.72, 1]),
        start: CGPoint(x: chip.minX, y: chip.maxY), end: CGPoint(x: chip.maxX, y: chip.minY), options: [])
    ctx.restoreGState()

    // Graph inside the chip.
    let inner = chip.insetBy(dx: 52, dy: 62)
    let values: [Double] = [0.30, 0.36, 0.28, 0.52, 0.42, 0.66, 0.50, 0.58, 0.88, 0.62, 0.74]
    let points = values.enumerated().map { index, v in
        CGPoint(x: inner.minX + inner.width * CGFloat(index) / CGFloat(values.count - 1),
                y: inner.minY + inner.height * CGFloat(v))
    }
    let curve = smoothPath(points)
    let lineGradient = gradient([blue, purple, pink, orange], [0, 0.4, 0.72, 1])
    let lineStart = CGPoint(x: inner.minX, y: 0), lineEnd = CGPoint(x: inner.maxX, y: 0)

    // Faint baseline grid.
    ctx.saveGState()
    ctx.setStrokeColor(rgb(1, 1, 1, 0.07))
    ctx.setLineWidth(3)
    for i in 0...3 {
        let y = inner.minY + inner.height * CGFloat(i) / 3
        ctx.move(to: CGPoint(x: inner.minX, y: y))
        ctx.addLine(to: CGPoint(x: inner.maxX, y: y))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // Area fill under the curve.
    ctx.saveGState()
    let area = CGMutablePath()
    area.addPath(curve)
    area.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
    area.addLine(to: CGPoint(x: inner.minX, y: inner.minY))
    area.closeSubpath()
    ctx.addPath(area)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(0.62, 0.40, 1.0, 0.38), rgb(0.62, 0.40, 1.0, 0)]),
        start: CGPoint(x: 0, y: inner.maxY), end: CGPoint(x: 0, y: inner.minY), options: [])
    ctx.restoreGState()

    // Glow, then the crisp line.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22, color: rgb(0.7, 0.45, 1.0, 0.85))
    ctx.addPath(curve)
    ctx.setLineWidth(24)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(lineGradient, start: lineStart, end: lineEnd, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Live dot on the latest value.
    if let last = points.last {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 24, color: rgb(1, 0.62, 0.22, 0.95))
        ctx.setFillColor(rgb(1, 1, 1))
        ctx.fillEllipse(in: CGRect(x: last.x - 21, y: last.y - 21, width: 42, height: 42))
        ctx.restoreGState()
        ctx.setFillColor(orange)
        ctx.fillEllipse(in: CGRect(x: last.x - 11, y: last.y - 11, width: 22, height: 22))
    }
}

// MARK: - Output

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(in: ctx)
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
}

// macOS app icon slots: point size × scale.
let slots: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

var images: [[String: String]] = []
for slot in slots {
    let name = "icon_\(slot.points)x\(slot.points)@\(slot.scale)x.png"
    write(render(pixels: slot.points * slot.scale), to: iconSet.appendingPathComponent(name))
    images.append([
        "filename": name,
        "idiom": "mac",
        "scale": "\(slot.scale)x",
        "size": "\(slot.points)x\(slot.points)",
    ])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appendingPathComponent("Contents.json"))

write(render(pixels: 1024), to: previewDir.appendingPathComponent("icon.png"))
print("Wrote \(slots.count) icon sizes to \(iconSet.path)")
