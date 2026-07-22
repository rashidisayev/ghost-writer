#!/usr/bin/env swift
// Renders the DMG background from code — no binary asset to keep in sync, the
// same approach as Scripts/make-icon.swift.
//
// The window that shows this is 660×410 points. Finder draws the real app icon
// and the Applications folder on top, at the positions Scripts/make-dmg.sh sets;
// this image supplies everything around them — the wordmark, the arrow, and the
// "drag" instruction. Coordinates here are expressed as distance FROM THE TOP so
// they line up with Finder's icon coordinates, which also originate top-left.
import AppKit

let W: CGFloat = 660
let H: CGFloat = 410
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"

// Brand palette, shared in spirit with the app icon's blue.
let ink = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.28, alpha: 1)
let brand = NSColor(srgbRed: 0.31, green: 0.36, blue: 0.91, alpha: 1)
let muted = NSColor(srgbRed: 0.42, green: 0.45, blue: 0.58, alpha: 1)

/// AppKit's image context is bottom-left origin; Finder is top-left. Convert
/// once here so every placement below can be written the way Finder sees it.
func fromTop(_ d: CGFloat) -> CGFloat { H - d }

func render(scale: CGFloat) -> Data {
    let pw = Int(W * scale), ph = Int(H * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: scale, y: scale)
    ctx.cgContext.setShouldAntialias(true)

    // Soft vertical gradient. Kept light: Finder draws icon labels in dark text
    // with a light halo, and they have to stay legible on top of this.
    NSGradient(colors: [
        NSColor(srgbRed: 0.97, green: 0.98, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.89, green: 0.91, blue: 0.99, alpha: 1),
    ])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    drawCentered("Ghost Writer", cx: W / 2, fromTopCenter: 58,
                 font: .systemFont(ofSize: 34, weight: .bold), color: ink)
    drawCentered("Rewrite your words in any app", cx: W / 2, fromTopCenter: 96,
                 font: .systemFont(ofSize: 14, weight: .regular), color: muted)

    drawArrow()

    // The instruction demonstrates the product: a struck-through typo with the
    // fix beside it, exactly what Ghost Writer does to your text — and the word
    // it "corrects" is the install action itself.
    drawTypoLine(cx: W / 2, fromTopCenter: 322)

    // The build is not notarized, so the very first launch is blocked. Baking
    // the fix into the background means it is on screen at exactly the moment
    // the user hits the wall, without a text file they have to think to open.
    drawCentered("First launch is blocked — open  System Settings ▸ Privacy & Security ▸ Open Anyway",
                 cx: W / 2, fromTopCenter: 386,
                 font: .systemFont(ofSize: 11, weight: .regular), color: muted)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func drawCentered(_ s: String, cx: CGFloat, fromTopCenter d: CGFloat,
                  font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: attrs)
    let size = str.size()
    str.draw(at: NSPoint(x: cx - size.width / 2, y: fromTop(d) - size.height / 2))
}

/// "Drag to Applications to ~instal~ install" — the misspelling struck out in
/// red, the correction in brand blue, so the line performs the rewrite it is
/// describing.
func drawTypoLine(cx: CGFloat, fromTopCenter d: CGFloat) {
    let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let red = NSColor(srgbRed: 0.85, green: 0.28, blue: 0.30, alpha: 1)

    let line = NSMutableAttributedString()
    line.append(NSAttributedString(string: "Drag to Applications to ",
        attributes: [.font: font, .foregroundColor: muted]))
    line.append(NSAttributedString(string: "instal",
        attributes: [.font: font, .foregroundColor: red,
                     .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                     .strikethroughColor: red]))
    line.append(NSAttributedString(string: " install",
        attributes: [.font: font, .foregroundColor: brand]))

    let size = line.size()
    line.draw(at: NSPoint(x: cx - size.width / 2, y: fromTop(d) - size.height / 2))
}

/// Sits in the gap between the two icons (centres at x 180 and 480, so their
/// facing edges are ~244 and ~416). A rounded shaft plus a filled head.
func drawArrow() {
    let cy = fromTop(210)
    brand.setFill()

    NSBezierPath(roundedRect: NSRect(x: 264, y: cy - 6, width: 104, height: 12),
                 xRadius: 6, yRadius: 6).fill()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: 366, y: cy - 21))
    head.line(to: NSPoint(x: 406, y: cy))
    head.line(to: NSPoint(x: 366, y: cy + 21))
    head.close()
    head.fill()
}

let scales: [(CGFloat, String)] = [(1, "dmg-background.png"), (2, "dmg-background@2x.png")]
for (scale, name) in scales {
    let url = URL(fileURLWithPath: "\(outDir)/\(name)")
    try! render(scale: scale).write(to: url)
    print("wrote \(url.path)")
}
