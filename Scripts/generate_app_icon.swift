// Run on macOS: swift Scripts/generate_app_icon.swift
// Original provisional artwork, drawn with CoreGraphics; no fonts or external assets.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appendingPathComponent("App/Assets.xcassets")
let output = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let indigo = CGColor(srgbRed: 0.32, green: 0.30, blue: 0.84, alpha: 1)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    // A full opaque square: the operating system supplies the iOS icon mask.
    context.setFillColor(indigo)
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let page = CGMutablePath()
    page.move(to: CGPoint(x: 204, y: 698))
    page.addCurve(to: CGPoint(x: 488, y: 650), control1: CGPoint(x: 298, y: 742), control2: CGPoint(x: 402, y: 725))
    page.addLine(to: CGPoint(x: 488, y: 306))
    page.addCurve(to: CGPoint(x: 204, y: 354), control1: CGPoint(x: 402, y: 381), control2: CGPoint(x: 298, y: 398))
    page.closeSubpath()
    for rightPage in [false, true] {
        context.saveGState()
        if rightPage { context.translateBy(x: 1024, y: 0); context.scaleBy(x: -1, y: 1) }
        context.setFillColor(white)
        context.addPath(page)
        context.fillPath()
        context.setStrokeColor(indigo)
        context.setLineWidth(14)
        context.setLineCap(.round)
        for y: CGFloat in [610, 539, 468] {
            context.move(to: CGPoint(x: 260, y: y))
            context.addCurve(to: CGPoint(x: 432, y: y - 23), control1: CGPoint(x: 315, y: y + 12), control2: CGPoint(x: 378, y: y + 7))
            context.strokePath()
        }
        context.restoreGState()
    }
    let image = context.makeImage()!
    let file = output.appendingPathComponent("AppIcon-\(size).png")
    let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(file.path)") }
}

var images: [[String: String]] = [
    ["filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]
]
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        images.append(["filename": "AppIcon-\(points * scale).png", "idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x"])
    }
}
func writeJSON(_ value: [String: Any], to url: URL) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0a)
    try data.write(to: url)
}
try writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], to: output.appendingPathComponent("Contents.json"))
try writeJSON(["info": ["author": "xcode", "version": 1]], to: catalog.appendingPathComponent("Contents.json"))
print("Generated opaque RGB icons in \(output.path)")
