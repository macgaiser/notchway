import AppKit

func render(_ name: String, _ draw: (CGContext, CGRect) -> Void) {
    let size: CGFloat = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let tile = CGRect(x: 100, y: 100, width: size - 200, height: size - 200)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    draw(ctx, tile)
    ctx.restoreGState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: name))
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { NSColor(calibratedRed: r, green: g, blue: b, alpha: a).cgColor }

func sea(_ ctx: CGContext, _ tile: CGRect) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [rgb(0.04, 0.10, 0.26), rgb(0.05, 0.32, 0.52), rgb(0.10, 0.62, 0.68)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
}

func ripple(_ ctx: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, alpha: CGFloat = 0.3) {
    ctx.setStrokeColor(rgb(1, 1, 1, alpha)); ctx.setLineWidth(12); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + width, y: y)); ctx.strokePath()
}


func skyToSea(_ ctx: CGContext, _ tile: CGRect) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [rgb(0.05, 0.09, 0.22), rgb(0.07, 0.25, 0.47), rgb(0.10, 0.55, 0.62)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
}

func glow(_ ctx: CGContext, x: CGFloat, y: CGFloat, r: CGFloat, _ color: CGColor) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: r * 1.4, color: color.copy(alpha: 0.95)!)
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    ctx.restoreGState()
}

let amber = rgb(1, 0.82, 0.35), mint = rgb(0.55, 0.95, 0.85)

func laptop(_ ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, color: CGColor, inner: CGColor) {
    let h = w * 0.68
    let screen = CGRect(x: x, y: y + w * 0.10, width: w, height: h)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: w * 0.09, cornerHeight: w * 0.09, transform: nil)); ctx.setFillColor(color); ctx.fillPath()
    let glass = screen.insetBy(dx: w * 0.07, dy: w * 0.07)
    ctx.addPath(CGPath(roundedRect: glass, cornerWidth: w * 0.04, cornerHeight: w * 0.04, transform: nil)); ctx.setFillColor(inner); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: screen.midX - w * 0.13, y: glass.maxY - w * 0.06, width: w * 0.26, height: w * 0.10), cornerWidth: w * 0.035, cornerHeight: w * 0.035, transform: nil)); ctx.setFillColor(color); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: x - w * 0.13, y: y, width: w * 1.26, height: w * 0.12), cornerWidth: w * 0.06, cornerHeight: w * 0.06, transform: nil)); ctx.setFillColor(color); ctx.fillPath()
}

func phone(_ ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, color: CGColor, inner: CGColor) {
    let body = CGRect(x: x, y: y, width: w, height: w * 1.78)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: w * 0.22, cornerHeight: w * 0.22, transform: nil)); ctx.setFillColor(color); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: w * 0.10, dy: w * 0.10), cornerWidth: w * 0.13, cornerHeight: w * 0.13, transform: nil)); ctx.setFillColor(inner); ctx.fillPath()
    ctx.setFillColor(color); ctx.fillEllipse(in: CGRect(x: body.midX - w * 0.06, y: body.maxY - w * 0.30, width: w * 0.12, height: w * 0.12))
}

/// The opened island: a large black shape hanging from the top edge.
func island(_ ctx: CGContext, _ tile: CGRect, width: CGFloat, height: CGFloat, radius: CGFloat) -> CGRect {
    let rect = CGRect(x: 512 - width / 2, y: tile.maxY - height, width: width, height: height + radius)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    return CGRect(x: rect.minX, y: rect.minY, width: width, height: height)
}

// D: the opened island holds both devices, joined by a way with two lights.
render("icon-d.png") { ctx, tile in
    skyToSea(ctx, tile)
    let area = island(ctx, tile, width: 660, height: 400, radius: 96)
    let white = rgb(1, 1, 1), dark = rgb(0.07, 0.07, 0.09)
    let baseline = area.minY + 120
    laptop(ctx, x: area.minX + 80, y: baseline, w: 180, color: white, inner: dark)
    phone(ctx, x: area.maxX - 160, y: baseline, w: 100, color: white, inner: dark)
    // The way between them.
    let wayY = baseline + 62
    ctx.setStrokeColor(rgb(1, 1, 1, 0.35)); ctx.setLineWidth(12); ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [2, 30])
    ctx.move(to: CGPoint(x: area.minX + 305, y: wayY)); ctx.addLine(to: CGPoint(x: area.maxX - 185, y: wayY)); ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    glow(ctx, x: area.minX + 348, y: wayY, r: 20, amber)
    glow(ctx, x: area.maxX - 228, y: wayY, r: 20, mint)
    // Water below.
    for (x, y, width) in [(CGFloat(250), CGFloat(330), CGFloat(524)), (350, 255, 324), (430, 185, 164)] { ripple(ctx, x: x, y: y, width: width, alpha: 0.28) }
}

// E: big island above; below it the causeway from A's water joins laptop and phone.
render("icon-e.png") { ctx, tile in
    skyToSea(ctx, tile)
    let area = island(ctx, tile, width: 560, height: 210, radius: 84)
    // Inside the island: the two lights, as a hint of live content.
    glow(ctx, x: area.midX - 150, y: area.minY + 118, r: 30, amber)
    glow(ctx, x: area.midX + 150, y: area.minY + 118, r: 30, mint)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.9)); ctx.setLineWidth(16); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: area.midX - 80, y: area.minY + 118)); ctx.addLine(to: CGPoint(x: area.midX + 80, y: area.minY + 118)); ctx.strokePath()

    let white = rgb(1, 1, 1), inner = rgb(0.06, 0.16, 0.36)
    let baseline: CGFloat = 330
    // Causeway: one clean white deck between the devices.
    ctx.setFillColor(white); ctx.fill(CGRect(x: 380, y: baseline + 26, width: 330, height: 30))
    laptop(ctx, x: 175, y: baseline, w: 230, color: white, inner: inner)
    phone(ctx, x: 700, y: baseline, w: 130, color: white, inner: inner)
    for (x, y, width) in [(CGFloat(300), CGFloat(250), CGFloat(424)), (400, 185, 224)] { ripple(ctx, x: x, y: y, width: width, alpha: 0.28) }
}
