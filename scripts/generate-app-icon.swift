#!/usr/bin/swift

import AppKit
import Foundation

let resources = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources", isDirectory: true)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("ipFeat-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func bitmap(size: Int, draw: (CGContext) -> Void) -> Data {
    guard let image = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: image) else {
        fatalError("Cannot create icon bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = image.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode icon PNG")
    }
    return png
}

func drawRoute(_ context: CGContext, color: CGColor) {
    context.setStrokeColor(color)
    context.setFillColor(color)
    context.setLineWidth(76)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 272, y: 512))
    context.addLine(to: CGPoint(x: 506, y: 512))
    context.addCurve(to: CGPoint(x: 754, y: 720), control1: CGPoint(x: 618, y: 512),
                     control2: CGPoint(x: 642, y: 720))
    context.strokePath()
    context.move(to: CGPoint(x: 506, y: 512))
    context.addCurve(to: CGPoint(x: 754, y: 304), control1: CGPoint(x: 618, y: 512),
                     control2: CGPoint(x: 642, y: 304))
    context.strokePath()
    for point in [CGPoint(x: 272, y: 512), CGPoint(x: 754, y: 720), CGPoint(x: 754, y: 304)] {
        context.fillEllipse(in: CGRect(x: point.x - 67, y: point.y - 67, width: 134, height: 134))
    }
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (filename, pixels) in sizes {
    let png = bitmap(size: pixels) { context in
        let tile = CGPath(roundedRect: CGRect(x: 32, y: 32, width: 960, height: 960),
                          cornerWidth: 218, cornerHeight: 218, transform: nil)
        context.addPath(tile)
        context.clip()
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [CGColor(gray: 0.97, alpha: 1), CGColor(gray: 0.80, alpha: 1)] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(gradient, start: CGPoint(x: 180, y: 950),
                                   end: CGPoint(x: 850, y: 50), options: [])
        let highlight = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: [CGColor(gray: 1, alpha: 0.35),
                                            CGColor(gray: 1, alpha: 0)] as CFArray,
                                   locations: [0, 1])!
        context.drawRadialGradient(highlight, startCenter: CGPoint(x: 280, y: 820), startRadius: 0,
                                   endCenter: CGPoint(x: 280, y: 820), endRadius: 690, options: [])
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 18,
                          color: CGColor(gray: 0, alpha: 0.22))
        drawRoute(context, color: CGColor(gray: 0.15, alpha: 1))
        context.restoreGState()
    }
    try png.write(to: iconset.appendingPathComponent(filename))
}

let statusPNG = bitmap(size: 72) { context in
    drawRoute(context, color: CGColor(gray: 0, alpha: 1))
}
try statusPNG.write(to: resources.appendingPathComponent("StatusIcon.png"), options: .atomic)

let types: [String: String] = [
    "icon_16x16.png": "ic04", "icon_16x16@2x.png": "ic11",
    "icon_32x32.png": "ic05", "icon_32x32@2x.png": "ic12",
    "icon_128x128.png": "ic07", "icon_128x128@2x.png": "ic13",
    "icon_256x256.png": "ic08", "icon_256x256@2x.png": "ic14",
    "icon_512x512.png": "ic09", "icon_512x512@2x.png": "ic10"
]
var chunks = Data()
for (filename, _) in sizes {
    guard let type = types[filename] else { fatalError("Missing icon type") }
    let png = try Data(contentsOf: iconset.appendingPathComponent(filename))
    chunks.append(contentsOf: type.utf8)
    var length = UInt32(png.count + 8).bigEndian
    withUnsafeBytes(of: &length) { chunks.append(contentsOf: $0) }
    chunks.append(png)
}
var outputData = Data("icns".utf8)
var totalLength = UInt32(chunks.count + 8).bigEndian
withUnsafeBytes(of: &totalLength) { outputData.append(contentsOf: $0) }
outputData.append(chunks)
let output = resources.appendingPathComponent("AppIcon.icns")
try outputData.write(to: output, options: .atomic)
print(output.path)
