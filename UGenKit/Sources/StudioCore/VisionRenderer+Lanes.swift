import CoreGraphics
import CoreText
import Foundation

extension VisionRenderer {
    /// Draws into a context whose origin is the top-left of a `width` x `height` image.
    /// `unit` is the line-width and text scale for this image size.
    /// Each lane is a thick line in its own colour with a white-rimmed dot at every point.
    static func drawLanes(_ items: [Lane], in context: CGContext, width: Int, height: Int, unit: CGFloat) {
        context.saveGState()
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for (index, lane) in items.enumerated() where !lane.points.isEmpty {
            let points = lane.points.map { CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height)) }
            context.setStrokeColor(color(index, alpha: 0.85))
            context.setLineWidth(4 * unit)
            context.addLines(between: points)
            context.strokePath()
            let radius = 3 * unit
            context.setFillColor(color(index))
            context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.setLineWidth(1 * unit)
            for point in points {
                let dot = CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)
                context.fillEllipse(in: dot)
                context.strokeEllipse(in: dot)
            }
        }
        context.restoreGState()
    }
}
