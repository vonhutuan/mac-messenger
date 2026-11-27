#!/usr/bin/env swift
import AppKit

// Generates a spec-compliant macOS AppIcon.icns directly from vector-rendered PNGs.
guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-icon.swift <output-icns-path>\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

func renderIconPNG(pixels: Int) -> Data? {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil,
              width: pixels,
              height: pixels,
              bitsPerComponent: 8,
              bytesPerRow: pixels * 4,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else {
        return nil
    }

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx

    let scale = CGFloat(pixels) / 1024.0
    ctx.scaleBy(x: scale, y: scale)

    let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let insetRect = rect.insetBy(dx: 84, dy: 84)
    let bgPath = NSBezierPath(roundedRect: insetRect, xRadius: 196, yRadius: 196)

    // Blue-to-violet-to-pink Messenger-inspired gradient
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.00, green: 0.56, blue: 1.00, alpha: 1.0),
        NSColor(srgbRed: 0.50, green: 0.25, blue: 0.98, alpha: 1.0),
        NSColor(srgbRed: 0.95, green: 0.28, blue: 0.55, alpha: 1.0)
    ])
    gradient?.draw(in: bgPath, angle: 45)

    // White chat bubble
    NSColor.white.setFill()
    let bubbleRect = CGRect(x: 244, y: 296, width: 536, height: 472)
    NSBezierPath(ovalIn: bubbleRect).fill()

    // Chat bubble tail
    let tail = NSBezierPath()
    tail.move(to: CGPoint(x: 342, y: 344))
    tail.line(to: CGPoint(x: 306, y: 228))
    tail.line(to: CGPoint(x: 438, y: 304))
    tail.close()
    tail.fill()

    // Gradient lightning bolt inside bubble
    let bolt = NSBezierPath()
    bolt.move(to: CGPoint(x: 358, y: 456))
    bolt.line(to: CGPoint(x: 484, y: 604))
    bolt.line(to: CGPoint(x: 544, y: 538))
    bolt.line(to: CGPoint(x: 666, y: 606))
    bolt.line(to: CGPoint(x: 540, y: 458))
    bolt.line(to: CGPoint(x: 480, y: 524))
    bolt.close()
    gradient?.draw(in: bolt, angle: 45)

    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: pixels, height: pixels)
    return rep.representation(using: .png, properties: [:])
}

func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
}

// Standard PNG-backed Apple ICNS chunk types
let chunks: [(String, Int)] = [
    ("icp4", 16),
    ("ic11", 32),
    ("icp5", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024)
]

var body = Data()
var cache: [Int: Data] = [:]

for (tag, px) in chunks {
    let png: Data
    if let cached = cache[px] {
        png = cached
    } else {
        guard let rendered = renderIconPNG(pixels: px) else {
            fputs("Failed to render \(px)px icon\n", stderr)
            exit(1)
        }
        cache[px] = rendered
        png = rendered
    }
    body.append(contentsOf: tag.utf8)
    appendUInt32BE(&body, UInt32(8 + png.count))
    body.append(png)
}

var icns = Data()
icns.append(contentsOf: "icns".utf8)
appendUInt32BE(&icns, UInt32(8 + body.count))
icns.append(body)

try icns.write(to: outputURL)
