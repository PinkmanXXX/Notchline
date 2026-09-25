import AppKit
import CoreImage

/// The shared look of the promo images: silk ribbons of pink, magenta, violet
/// and peach on a deep purple, softly blurred, with film grain and a vignette.
enum Backdrop {
    static let context = CIContext()

    static func cg(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: a)
    }

    static func make(width: Int, height: Int, seed: UInt64 = 7) -> CGImage {
        let w = CGFloat(width), h = CGFloat(height)
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        // base: deep purple, lighter towards the top
        let base = CGGradient(colorsSpace: space, colors: [cg(0x2A0B3D), cg(0x0E0418)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(base, start: CGPoint(x: w * 0.3, y: h), end: CGPoint(x: w * 0.7, y: 0), options: [])

        // blooms of colour
        for (hex, x, y, r, a) in [(0xFF3CAC, 0.15, 0.85, 0.55, 0.85), (0x8E2DE2, 0.9, 0.75, 0.6, 0.8),
                                  (0xFF7A59, 0.85, 0.12, 0.5, 0.55), (0x5B3CF0, 0.1, 0.2, 0.55, 0.7),
                                  (0xFF5FCB, 0.55, 0.45, 0.35, 0.35)] as [(Int, CGFloat, CGFloat, CGFloat, CGFloat)] {
            let g = CGGradient(colorsSpace: space, colors: [cg(hex, a), cg(hex, 0)] as CFArray, locations: [0, 1])!
            let c = CGPoint(x: x * w, y: y * h)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r * max(w, h), options: [])
        }

        // silk: wide ribbons that will be blurred into folds of light
        var rng = SplitMix(seed: seed)
        let ribbons: [(Int, CGFloat)] = [(0xFF7AD9, 0.55), (0xB06CFF, 0.5), (0xFFB199, 0.35), (0xFF3CAC, 0.45), (0x7C5CFF, 0.4)]
        for (i, (hex, a)) in ribbons.enumerated() {
            let path = CGMutablePath()
            let y0 = h * (0.15 + 0.17 * CGFloat(i)) + rng.next(-40, 40)
            path.move(to: CGPoint(x: -100, y: y0))
            path.addCurve(to: CGPoint(x: w + 100, y: y0 + rng.next(-200, 200)),
                          control1: CGPoint(x: w * 0.35, y: y0 + rng.next(150, 380)),
                          control2: CGPoint(x: w * 0.65, y: y0 - rng.next(150, 380)))
            ctx.addPath(path)
            ctx.setStrokeColor(cg(hex, a))
            ctx.setLineWidth(rng.next(50, 110))
            ctx.setLineCap(.round)
            ctx.strokePath()
            // a thin bright edge along each ribbon, the sheen of silk
            ctx.addPath(path)
            ctx.setStrokeColor(cg(0xFFFFFF, 0.28))
            ctx.setLineWidth(6)
            ctx.strokePath()
        }
        var image = CIImage(cgImage: ctx.makeImage()!)
        let extent = image.extent

        // soften everything into light
        image = image.clampedToExtent()
            .applyingGaussianBlur(sigma: 38)
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.15, kCIInputContrastKey: 1.05])

        // film grain
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.07)])
            .cropped(to: extent)
        image = noise.composited(over: image)

        // vignette
        image = image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.9, kCIInputRadiusKey: 1.6])

        return context.createCGImage(image, from: extent)!
    }
}

/// Deterministic randomness, so a backdrop comes out the same every time.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        lo + (hi - lo) * CGFloat(next() % 10_000) / 10_000
    }
}
