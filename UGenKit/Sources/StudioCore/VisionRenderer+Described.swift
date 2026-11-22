import CoreGraphics
import Foundation

extension VisionRenderer {
    /// Attributes shown under each box (in smaller tags, so neighbours overlap less); the result list has them all.
    static let attributesDrawn = 3

    /// Faces or people with their attributes or re-identified names: the box, the name (or the score)
    /// above it and the most certain attributes stacked under it. Objects matched against prompts (`ObjectCLIP`)
    /// show what the detector calls them above and only their best prompt under them.
    static func drawDescribed(_ items: [DescribedObject], in context: CGContext, width: Int, height: Int, unit: CGFloat) {
        let w = CGFloat(width), h = CGFloat(height)
        for (index, item) in items.enumerated().reversed() {
            // The same person keeps the same colour across frames: colour by the number in the name.
            let number = item.name.flatMap { Int($0.split(separator: " ").last ?? "") } ?? index
            let tint = color(number)
            let rect = CGRect(x: item.boundingBox.minX * w, y: item.boundingBox.minY * h, width: item.boundingBox.width * w, height: item.boundingBox.height * h)
            context.setStrokeColor(tint)
            context.setLineWidth(2 * unit)
            context.stroke(rect)
            let title = item.name.map { name in item.similarity.map { String(format: "%@ %.2f", name, $0) } ?? name }
                ?? item.label.map { String(format: "%@ %.2f", $0, item.confidence) }
                ?? String(format: "%.2f", item.confidence)
            drawLabel(title, at: CGPoint(x: rect.minX, y: rect.minY), background: tint, unit: unit, in: context)
            let small = 0.85 * unit, step = 19 * small
            let shown = Array(item.attributes.prefix(item.label == nil ? attributesDrawn : 1))
            // A box reaching the bottom of the picture gets its tags moved up into it.
            let lift = max(0, rect.maxY + step * CGFloat(shown.count) - h)
            for (row, attribute) in shown.enumerated() {
                drawLabel(String(format: "%@ %.0f%%", attribute.label, attribute.probability * 100),
                          at: CGPoint(x: rect.minX, y: rect.maxY + step * CGFloat(row + 1) - lift), background: color(number, alpha: 0.75), unit: small, in: context)
            }
        }
    }

    /// The iBUG 300-W groups of 3DDFA's 68 points, drawn as lines: jaw, brows, nose bridge and base,
    /// eyes and lips (the last four closed).
    static let landmarkLines: [(range: ClosedRange<Int>, closed: Bool)] = [
        (0...16, false), (17...21, false), (22...26, false), (27...30, false), (31...35, false),
        (36...41, true), (42...47, true), (48...59, true), (60...67, true),
    ]

    /// Dense face landmarks: 3DDFA's 68 as lines and dots with the head pose, the face mesh's 468 as dots.
    static func drawFaceLandmarks(_ items: [FaceLandmarks], in context: CGContext, width: Int, height: Int, unit: CGFloat) {
        let w = CGFloat(width), h = CGFloat(height)
        for (index, face) in items.enumerated().reversed() {
            let tint = color(index)
            let rect = CGRect(x: face.boundingBox.minX * w, y: face.boundingBox.minY * h, width: face.boundingBox.width * w, height: face.boundingBox.height * h)
            let points = face.points.map { CGPoint(x: $0.x * w, y: $0.y * h) }
            // Dots scale with the face so a small face is not covered.
            let faceSize = max(rect.width, rect.height)
            if points.count == 68 {
                context.setStrokeColor(tint)
                context.setLineWidth(max(min(faceSize * 0.012, 2 * unit), 1))
                for line in landmarkLines {
                    context.addLines(between: line.range.map { points[$0] })
                    if line.closed { context.closePath() }
                    context.strokePath()
                }
            }
            let radius = points.count > 100 ? max(min(faceSize * 0.006, 1.5 * unit), 0.6) : max(min(faceSize * 0.015, 2.5 * unit), 1)
            context.setFillColor(points.count > 100 ? tint : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            for p in points { context.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)) }
            let label = face.headPose.map { String(format: "yaw %.0f° pitch %.0f° roll %.0f°", $0.yaw, $0.pitch, $0.roll) }
                ?? String(format: "%.2f", face.confidence)
            drawLabel(label, at: CGPoint(x: rect.minX, y: rect.minY), background: tint, unit: unit, in: context)
        }
    }
}
