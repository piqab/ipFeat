#!/usr/bin/swift

import AppKit
import Foundation

let resources = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources", isDirectory: true)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("IPInformer-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
var finished = false
defer { if finished { try? FileManager.default.removeItem(at: iconset) } }

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (filename, pixels) in sizes {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot create app icon bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let tile = CGPath(roundedRect: CGRect(x: 32, y: 32, width: 960, height: 960),
                      cornerWidth: 218, cornerHeight: 218, transform: nil)
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 0.08, green: 0.27, blue: 0.64, alpha: 1),
                 CGColor(red: 0.18, green: 0.62, blue: 0.87, alpha: 1)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(gradient, start: CGPoint(x: 120, y: 920),
                               end: CGPoint(x: 910, y: 90), options: [])
    let text = "IP" as NSString
    let font = NSFont.systemFont(ofSize: 465, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.white,
        .kern: -18
    ]
    let textSize = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (1024 - textSize.width) / 2,
                          y: (1024 - textSize.height) / 2 + 5), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode app icon PNG")
    }
    try png.write(to: iconset.appendingPathComponent(filename))
}

let output = resources.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fputs("Invalid iconset retained at \(iconset.path)\n", stderr)
    exit(1)
}
finished = true
print(output.path)
