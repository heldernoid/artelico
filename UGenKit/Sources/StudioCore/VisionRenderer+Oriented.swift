import CoreGraphics
import CoreText
import Foundation

extension VisionRenderer {
    /// Draws into a context whose origin is the top-left of a `width` x `height` image.
    /// `unit` is the line-width and text scale for this image size.
    /// Each box is a quadrilateral in its class colour; labels are left out of crowded pictures.
    static func drawOriented(_ items: [OrientedDetection], in context: CGContext, width: Int, height: Int, unit: CGFloat) {
        let showLabels = items.count <= 60
        context.setLineJoin(.round)
        context.setLineWidth((showLabels ? 2.5 : 1.5) * unit)
        for item in items.reversed() where item.corners.count >= 3 {
            let points = item.corners.map { CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height)) }
            context.setStrokeColor(color(item.classIndex))
            context.addLines(between: points)
            context.closePath()
            context.strokePath()
        }
        guard showLabels else { return }
        for item in items.reversed() {
            guard let first = item.corners.first else { continue }
            drawLabel("\(item.label) \(String(format: "%.2f", item.confidence))",
                      at: CGPoint(x: first.x * CGFloat(width), y: first.y * CGFloat(height)),
                      background: color(item.classIndex), unit: unit * 0.7, in: context)
        }
    }
}
