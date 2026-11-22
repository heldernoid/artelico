import CoreGraphics
import CoreText
import Foundation

extension VisionRenderer {
    /// Draws into a context whose origin is the top-left of a `width` x `height` image.
    /// `unit` is the line-width and text scale for this image size.
    /// Each face gets its box, five landmark dots and a label: the name if known, otherwise the confidence.
    static func drawFaces(_ items: [Face], in context: CGContext, width: Int, height: Int, unit: CGFloat) {
        let w = CGFloat(width), h = CGFloat(height)
        for (index, face) in items.enumerated().reversed() {
            let tint = color(index)
            let box = face.boundingBox
            let rect = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h)
            context.setStrokeColor(tint)
            context.setLineWidth(2 * unit)
            context.stroke(rect)

            // Small faces get small dots so the landmarks do not cover the face.
            let radius = min(max(min(rect.width, rect.height) * 0.04, 1.5), 3.5 * unit)
            for point in face.landmarks {
                let dot = CGRect(x: point.x * w - radius, y: point.y * h - radius, width: 2 * radius, height: 2 * radius)
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                context.fillEllipse(in: dot)
                context.setStrokeColor(tint)
                context.setLineWidth(max(radius * 0.4, 0.75))
                context.strokeEllipse(in: dot)
            }

            let label = face.name ?? String(format: "%.2f", face.confidence)
            drawLabel(label, at: CGPoint(x: rect.minX, y: rect.minY), background: tint, unit: unit, in: context)
        }
    }
}
