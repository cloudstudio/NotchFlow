import SwiftUI

/// The MacBook notch silhouette: flush with the screen's top edge, concave
/// fillets flaring outward where the side walls meet the edge, and convex
/// rounded corners at the bottom. Quadratic curves are visually identical to
/// true arcs at these radii and keep the tangents unambiguous.
struct NotchShape: Shape {
    var topFillet: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topFillet, bottomRadius) }
        set {
            topFillet = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let fillet = min(topFillet, rect.width / 4, rect.height / 2)
        let radius = min(bottomRadius, (rect.width - fillet * 2) / 2, rect.height - fillet)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + fillet, y: rect.minY + fillet),
            control: CGPoint(x: rect.minX + fillet, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + fillet, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + fillet + radius, y: rect.maxY),
            control: CGPoint(x: rect.minX + fillet, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - fillet - radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - fillet, y: rect.maxY - radius),
            control: CGPoint(x: rect.maxX - fillet, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - fillet, y: rect.minY + fillet))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - fillet, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
