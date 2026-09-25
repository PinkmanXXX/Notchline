// Promo images for social posts, composed from the real interface.
//
//   make promo    (renders the snapshots, then runs this)
//
// usage: promo <snapshot dir> <app icon png> <out dir>

import AppKit
import CoreImage

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: promo <snapshots> <icon.png> <out dir>\n".utf8))
    exit(64)
}
let snaps = URL(fileURLWithPath: args[1])
let icon = NSImage(contentsOfFile: args[2])!
let out = URL(fileURLWithPath: args[3])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let space = CGColorSpaceCreateDeviceRGB()
func cg(_ hex: Int, _ a: CGFloat = 1) -> CGColor { Backdrop.cg(hex, a) }

func canvas(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func save(_ image: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    print("wrote \(name)")
}

/// A snapshot with its transparent margins trimmed away.
func trimmed(_ name: String) -> CGImage {
    let rep = NSBitmapImageRep(data: try! Data(contentsOf: snaps.appendingPathComponent(name)))!
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = 0, maxY = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.6 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return rep.cgImage!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 2, height: maxY - minY + 2))!
}

/// Text with a soft coloured glow behind it.
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor = .white,
          glow: NSColor? = nil, kern: CGFloat = 0) -> NSAttributedString {
    var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .kern: kern]
    if let glow {
        let sh = NSShadow(); sh.shadowColor = glow; sh.shadowBlurRadius = size * 0.6
        attrs[.shadow] = sh
    }
    return NSAttributedString(string: s, attributes: attrs)
}

func centred(_ str: NSAttributedString, width: CGFloat, y: CGFloat) {
    str.draw(at: CGPoint(x: (width - str.size().width) / 2, y: y))
}

/// A frosted pill with the app icon and name, like a product badge.
func badge(_ ctx: CGContext, width: CGFloat, y: CGFloat) {
    let name = text("Notchline", size: 30, weight: .semibold)
    let iconSize: CGFloat = 46
    let w = iconSize + 14 + name.size().width + 44, h: CGFloat = 66
    let rect = CGRect(x: (width - w) / 2, y: y, width: w, height: h)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
    ctx.setFillColor(cg(0xFFFFFF, 0.12)); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
    ctx.setStrokeColor(cg(0xFFFFFF, 0.22)); ctx.setLineWidth(1.5); ctx.strokePath()
    icon.draw(in: CGRect(x: rect.minX + 12, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize))
    name.draw(at: CGPoint(x: rect.minX + 12 + iconSize + 12, y: rect.midY - name.size().height / 2))
}

// MARK: - hero: the panel growing out of a MacBook's notch

func hero() {
    let W = 1080, H = 1350
    let bg = Backdrop.make(width: W, height: H, seed: 11)

    // the screen, drawn flat first, then tilted with a perspective transform
    let SW = 1400, SH = 900
    let panel = trimmed("panel.png")
    let screen = canvas(SW, SH) { ctx in
        let body = CGRect(x: 0, y: 0, width: SW, height: SH)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 54, cornerHeight: 54, transform: nil))
        ctx.setFillColor(cg(0x0A090D)); ctx.fillPath()
        let glass = body.insetBy(dx: 22, dy: 22)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: glass, cornerWidth: 34, cornerHeight: 34, transform: nil)); ctx.clip()
        // a dark wallpaper with the backdrop's colours bleeding in
        ctx.draw(Backdrop.make(width: SW, height: SH, seed: 3), in: glass)
        ctx.setFillColor(cg(0x07030D, 0.62)); ctx.fill(glass)
        // menu bar
        let bar = CGRect(x: glass.minX, y: glass.maxY - 44, width: glass.width, height: 44)
        ctx.setFillColor(cg(0xFFFFFF, 0.08)); ctx.fill(bar)
        ctx.setFillColor(cg(0xFFFFFF, 0.5))
        for (i, w) in [44.0, 62, 54, 70].enumerated() {
            ctx.addPath(CGPath(roundedRect: CGRect(x: glass.minX + 34 + Double(i) * 88, y: bar.midY - 7, width: w, height: 14),
                               cornerWidth: 7, cornerHeight: 7, transform: nil))
        }
        for i in 0..<5 {
            ctx.addPath(CGPath(roundedRect: CGRect(x: glass.maxX - 56 - Double(i) * 46, y: bar.midY - 9, width: 22, height: 18),
                               cornerWidth: 5, cornerHeight: 5, transform: nil))
        }
        ctx.fillPath()
        // a green glow spilling out under the island
        let glow = CGGradient(colorsSpace: space, colors: [cg(0x8BF0BE, 0.35), cg(0x8BF0BE, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: glass.midX, y: glass.maxY - 380), startRadius: 0,
                               endCenter: CGPoint(x: glass.midX, y: glass.maxY - 380), endRadius: 560, options: [])
        // the island, hanging from the top of the glass
        let pw: CGFloat = 860, ph = pw * CGFloat(panel.height) / CGFloat(panel.width)
        ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 60, color: cg(0x000000, 0.7))
        ctx.draw(panel, in: CGRect(x: glass.midX - pw / 2, y: glass.maxY - ph + 1, width: pw, height: ph))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        // the notch on top: the island reads as coming out of it
        let nw: CGFloat = 240, nh: CGFloat = 40, top = glass.maxY
        let notch = CGMutablePath()
        notch.move(to: CGPoint(x: glass.midX - nw / 2 - 10, y: top))
        notch.addQuadCurve(to: CGPoint(x: glass.midX - nw / 2, y: top - 10), control: CGPoint(x: glass.midX - nw / 2, y: top))
        notch.addLine(to: CGPoint(x: glass.midX - nw / 2, y: top - nh + 14))
        notch.addQuadCurve(to: CGPoint(x: glass.midX - nw / 2 + 14, y: top - nh), control: CGPoint(x: glass.midX - nw / 2, y: top - nh))
        notch.addLine(to: CGPoint(x: glass.midX + nw / 2 - 14, y: top - nh))
        notch.addQuadCurve(to: CGPoint(x: glass.midX + nw / 2, y: top - nh + 14), control: CGPoint(x: glass.midX + nw / 2, y: top - nh))
        notch.addLine(to: CGPoint(x: glass.midX + nw / 2, y: top - 10))
        notch.addQuadCurve(to: CGPoint(x: glass.midX + nw / 2 + 10, y: top), control: CGPoint(x: glass.midX + nw / 2, y: top))
        notch.closeSubpath()
        ctx.addPath(notch); ctx.setFillColor(cg(0x000000)); ctx.fillPath()
        ctx.restoreGState()
        // a sheen across the glass
        let sheen = CGGradient(colorsSpace: space, colors: [cg(0xFFFFFF, 0.07), cg(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: glass, cornerWidth: 34, cornerHeight: 34, transform: nil)); ctx.clip()
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: CGFloat(SH)), end: CGPoint(x: CGFloat(SW) * 0.6, y: 0), options: [])
        ctx.restoreGState()
    }

    // tilt it: the top leans away, the right side a little closer
    let tilted = CIImage(cgImage: screen).applyingFilter("CIPerspectiveTransform", parameters: [
        "inputTopLeft": CIVector(x: 150, y: 860), "inputTopRight": CIVector(x: 1280, y: 900),
        "inputBottomLeft": CIVector(x: 0, y: 0), "inputBottomRight": CIVector(x: 1400, y: 40)])
    let tiltedCG = Backdrop.context.createCGImage(tilted, from: tilted.extent)!

    let image = canvas(W, H) { ctx in
        ctx.draw(bg, in: CGRect(x: 0, y: 0, width: W, height: H))

        badge(ctx, width: CGFloat(W), y: 1178)
        let pink = NSColor(red: 1, green: 0.35, blue: 0.75, alpha: 0.9)
        centred(text("Терминал", size: 104, weight: .heavy, glow: pink, kern: -2), width: CGFloat(W), y: 1036)
        centred(text("в вырезе Mac", size: 104, weight: .heavy, glow: pink, kern: -2), width: CGFloat(W), y: 920)
        centred(text("Сборки, деплои и ИИ-агенты — видно, что идёт и чем закончилось",
                     size: 27, weight: .medium, color: NSColor(white: 1, alpha: 0.78)), width: CGFloat(W), y: 866)

        // the screen runs off the bottom edge, as if the laptop were right there
        let sw: CGFloat = 1180, sh = sw * CGFloat(tiltedCG.height) / CGFloat(tiltedCG.width)
        ctx.setShadow(offset: CGSize(width: 0, height: -30), blur: 80, color: cg(0x000000, 0.6))
        ctx.draw(tiltedCG, in: CGRect(x: (CGFloat(W) - sw) / 2, y: -150, width: sw, height: sh))
    }
    save(image, "threads-hero.png")
}

// MARK: - moments: three states of the island

func moments() {
    let W = 1080, H = 1350
    let bg = Backdrop.make(width: W, height: H, seed: 29)
    let rows: [(String, String, String)] = [
        ("running.png", "Идёт сборка", "таймер тикает, пока вы в браузере"),
        ("agent-waiting.png", "Агент ждёт ответа", "Claude Code, Cursor, Codex, Gemini"),
        ("prod.png", "Терминал в проде", "вырез краснеет — не перепутаете"),
    ]
    let image = canvas(W, H) { ctx in
        ctx.draw(bg, in: CGRect(x: 0, y: 0, width: W, height: H))
        badge(ctx, width: CGFloat(W), y: 1190)
        centred(text("Одного взгляда хватит", size: 64, weight: .heavy,
                     glow: NSColor(red: 1, green: 0.35, blue: 0.75, alpha: 0.9), kern: -1),
                width: CGFloat(W), y: 1080)

        var top: CGFloat = 1000
        for (file, title, sub) in rows {
            // a frosted card behind each state
            let card = CGRect(x: 60, y: top - 290, width: CGFloat(W) - 120, height: 290)
            ctx.addPath(CGPath(roundedRect: card, cornerWidth: 36, cornerHeight: 36, transform: nil))
            ctx.setFillColor(cg(0xFFFFFF, 0.08)); ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: card.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 36, cornerHeight: 36, transform: nil))
            ctx.setStrokeColor(cg(0xFFFFFF, 0.16)); ctx.setLineWidth(1.5); ctx.strokePath()

            let t = text(title, size: 38, weight: .bold)
            t.draw(at: CGPoint(x: card.minX + 44, y: card.maxY - 76))
            let s = text(sub, size: 24, weight: .medium, color: NSColor(white: 1, alpha: 0.7))
            s.draw(at: CGPoint(x: card.minX + 44, y: card.maxY - 112))

            let pic = trimmed(file)
            let pw = card.width - 88, ph = pw * CGFloat(pic.height) / CGFloat(pic.width)
            ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: cg(0x000000, 0.55))
            ctx.draw(pic, in: CGRect(x: card.minX + 44, y: card.minY + 44, width: pw, height: ph))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            top = card.minY - 34
        }
    }
    save(image, "threads-moments.png")
}

hero()
moments()
