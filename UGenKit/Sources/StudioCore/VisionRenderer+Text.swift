import CoreGraphics
import CoreText
import Foundation

extension VisionRenderer {
    /// Draws into a context whose origin is the top-left of a `width` x `height` image.
    /// `unit` is the line-width and text scale for this image size.
    /// Each region is outlined; recognised text, if any, is shown as a label at its top-left corner.
    static func drawText(_ items: [TextRegion], in context: CGContext, width: Int, height: Int, unit: CGFloat) {
        let w = CGFloat(width), h = CGFloat(height)
        let tint = color(2)
        for region in items where region.corners.count >= 3 {
            let points = region.corners.map { CGPoint(x: $0.x * w, y: $0.y * h) }
            context.beginPath()
            context.addLines(between: points)
            context.closePath()
            context.setFillColor(color(2, alpha: 0.12))
            context.setStrokeColor(tint)
            context.setLineWidth(1.5 * unit)
            context.setLineJoin(.round)
            context.drawPath(using: .fillStroke)
        }
        for region in items where region.corners.count >= 3 && !region.text.isEmpty {
            let corner = region.corners[0]
            drawLabel(region.text, at: CGPoint(x: corner.x * w, y: corner.y * h), background: color(0), unit: unit, in: context)
        }
    }
}
