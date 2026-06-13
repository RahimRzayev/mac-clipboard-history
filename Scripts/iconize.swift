import AppKit
import CoreGraphics

// Turns a square icon export that sits on an opaque (white-ish) background into a native
// macOS app-icon master: crops away the background margin, then re-masks the artwork to the
// standard rounded-square ("squircle") with TRANSPARENT corners + margin. Interior pixels are
// never touched (so the bright shield/translucent cards survive), unlike naive white-removal.
//
// Usage: swift iconize.swift <input.png> <output.png>

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: iconize.swift <in> <out>\n".utf8)); exit(2)
}
let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let src = NSImage(contentsOf: inputURL),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("could not load image\n".utf8)); exit(1)
}
let w = cg.width, h = cg.height

// Draw into an RGBA8 buffer for pixel scanning.
var pixels = [UInt8](repeating: 0, count: w * h * 4)
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("ctx failed\n".utf8)); exit(1)
}
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

@inline(__always) func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
    let i = (y * w + x) * 4
    return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
}

// Background = the corner color (sampled a few px in). Content = pixels that differ from it.
let bg = px(8, 8)
let tol = 22
func isContent(_ x: Int, _ y: Int) -> Bool {
    let p = px(x, y)
    if p.3 < 10 { return false } // already transparent
    return abs(Int(p.0) - Int(bg.0)) > tol
        || abs(Int(p.1) - Int(bg.1)) > tol
        || abs(Int(p.2) - Int(bg.2)) > tol
}

var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w where isContent(x, y) {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    }
}
guard maxX >= minX, maxY >= minY else {
    FileHandle.standardError.write(Data("no content detected\n".utf8)); exit(1)
}
print("background rgb=(\(bg.0),\(bg.1),\(bg.2))  contentBBox=(\(minX),\(minY))-(\(maxX),\(maxY))")

// cropping(to:) uses a top-left-origin pixel rect, matching our scan coordinates.
let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
guard let cropped = cg.cropping(to: cropRect) else {
    FileHandle.standardError.write(Data("crop failed\n".utf8)); exit(1)
}

// Compose the 1024 master: 824 squircle centered (100px transparent margin), Apple's
// ~0.2237 corner-radius ratio. Slightly over-radius vs the source tile so no white remains.
let canvas = 1024.0, inset = 100.0, side = canvas - inset * 2
let radius = side * 0.2237

let out = NSImage(size: NSSize(width: canvas, height: canvas))
out.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
let tile = NSRect(x: inset, y: inset, width: side, height: side)
NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).addClip()
NSImage(cgImage: cropped, size: tile.size).draw(in: tile)
out.unlockFocus()

guard let tiff = out.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("png encode failed\n".utf8)); exit(1)
}
try png.write(to: outputURL)
print("wrote \(outputURL.path)")
