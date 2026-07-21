#!/usr/bin/env swift
// Renders Resources/Ghost Writer.iconset from code — no binary asset to keep in sync.
// macOS icons are a rounded "squircle" with the mark inset; drawing straight to
// the edges is the classic way to make an app look unfinished in the Dock.
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Ghost Writer.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    // Squircle plate, inset like Apple's own icons.
    let inset = size * 0.085
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let plate = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)

    NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.42, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.24, green: 0.24, blue: 0.62, alpha: 1),
    ])!.draw(in: plate, angle: -90)

    // The mark: the same pencil used in the menu bar, knocked out in white so
    // the icon reads at 16pt as well as 1024.
    let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .medium)
    if let glyph = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: glyph.size, flipped: false) { r in
            glyph.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let g = tinted.size
        tinted.draw(in: NSRect(
            x: (size - g.width) / 2,
            y: (size - g.height) / 2,
            width: g.width,
            height: g.height
        ))
    }

    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
}

for px in sizes {
    let data = render(px)
    // iconutil wants both @1x and @2x names; the @2x of one size is the @1x
    // bitmap of the next one up.
    try! data.write(to: URL(fileURLWithPath: "\(out)/icon_\(px)x\(px).png"))
    if px > 16 {
        try! data.write(to: URL(fileURLWithPath: "\(out)/icon_\(px / 2)x\(px / 2)@2x.png"))
    }
}
print("wrote \(out)")
