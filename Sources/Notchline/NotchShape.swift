import SwiftUI

/// The silhouette of a MacBook notch: flat against the screen edge, rounded
/// corners on the free side, small concave fillets where it meets the edge.
/// The rect it is given already includes the fillet margins.
///
/// Both radii animate, so the notch-sized pill can grow into the panel with its
/// corners opening up instead of snapping.
struct NotchShape: Shape {
    var edge: Edge
    var fillet: CGFloat = 6
    var corner: CGFloat = 10

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(fillet, corner) }
        set { fillet = newValue.first; corner = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = min(fillet, edge.isVertical ? h / 2 - 1 : w / 2 - 1)
        // the free side's corners share its length with the fillets
        let c = max(0, min(corner, (edge.isVertical ? (h - 2 * r) / 2 : (w - 2 * r) / 2) - 1,
                           (edge.isVertical ? w : h) - 1))
        var p = Path()

        switch edge {
        case .top:
            p.move(to: .init(x: 0, y: 0))
            quarter(&p, to: .init(x: r, y: r), center: .init(x: 0, y: r))
            p.addLine(to: .init(x: r, y: h - c))
            quarter(&p, to: .init(x: r + c, y: h), center: .init(x: r + c, y: h - c))
            p.addLine(to: .init(x: w - r - c, y: h))
            quarter(&p, to: .init(x: w - r, y: h - c), center: .init(x: w - r - c, y: h - c))
            p.addLine(to: .init(x: w - r, y: r))
            quarter(&p, to: .init(x: w, y: 0), center: .init(x: w, y: r))

        case .bottom:
            p.move(to: .init(x: 0, y: h))
            quarter(&p, to: .init(x: r, y: h - r), center: .init(x: 0, y: h - r))
            p.addLine(to: .init(x: r, y: c))
            quarter(&p, to: .init(x: r + c, y: 0), center: .init(x: r + c, y: c))
            p.addLine(to: .init(x: w - r - c, y: 0))
            quarter(&p, to: .init(x: w - r, y: c), center: .init(x: w - r - c, y: c))
            p.addLine(to: .init(x: w - r, y: h - r))
            quarter(&p, to: .init(x: w, y: h), center: .init(x: w, y: h - r))

        case .left:
            p.move(to: .init(x: 0, y: 0))
            quarter(&p, to: .init(x: r, y: r), center: .init(x: r, y: 0))
            p.addLine(to: .init(x: w - c, y: r))
            quarter(&p, to: .init(x: w, y: r + c), center: .init(x: w - c, y: r + c))
            p.addLine(to: .init(x: w, y: h - r - c))
            quarter(&p, to: .init(x: w - c, y: h - r), center: .init(x: w - c, y: h - r - c))
            p.addLine(to: .init(x: r, y: h - r))
            quarter(&p, to: .init(x: 0, y: h), center: .init(x: r, y: h))

        case .right:
            p.move(to: .init(x: w, y: 0))
            quarter(&p, to: .init(x: w - r, y: r), center: .init(x: w - r, y: 0))
            p.addLine(to: .init(x: c, y: r))
            quarter(&p, to: .init(x: 0, y: r + c), center: .init(x: c, y: r + c))
            p.addLine(to: .init(x: 0, y: h - r - c))
            quarter(&p, to: .init(x: c, y: h - r), center: .init(x: c, y: h - r - c))
            p.addLine(to: .init(x: w - r, y: h - r))
            quarter(&p, to: .init(x: w, y: h), center: .init(x: w - r, y: h))
        }

        p.closeSubpath()
        return p
    }

    /// Quarter circle as a cubic Bézier, driven purely by geometry so that the
    /// convex corners and the concave fillets both come out right without
    /// having to reason about which way `clockwise` points today.
    private func quarter(_ p: inout Path, to b: CGPoint, center c: CGPoint) {
        let a = p.currentPoint ?? b
        let k: CGFloat = 0.5522847498
        func tangent(at point: CGPoint) -> CGPoint {
            let radius = CGPoint(x: point.x - c.x, y: point.y - c.y)
            var t = CGPoint(x: -radius.y, y: radius.x)
            if t.x * (b.x - a.x) + t.y * (b.y - a.y) < 0 { t = CGPoint(x: radius.y, y: -radius.x) }
            return t
        }
        let t1 = tangent(at: a), t2 = tangent(at: b)
        p.addCurve(to: b,
                   control1: .init(x: a.x + t1.x * k, y: a.y + t1.y * k),
                   control2: .init(x: b.x - t2.x * k, y: b.y - t2.y * k))
    }
}
