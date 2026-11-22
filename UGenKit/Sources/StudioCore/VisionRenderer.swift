import CoreGraphics
import CoreText
import Foundation

/// Draws results over the source image with CoreGraphics (works on iPadOS and macOS).
public enum VisionRenderer {
    /// Distinct colours for classes and instances.
    public static let palette: [(CGFloat, CGFloat, CGFloat)] = [
        (0.20, 0.60, 1.00), (1.00, 0.42, 0.21), (0.30, 0.85, 0.39), (1.00, 0.80, 0.00), (0.69, 0.32, 0.87),
        (1.00, 0.18, 0.33), (0.35, 0.78, 0.98), (1.00, 0.58, 0.00), (0.64, 0.52, 0.37), (0.00, 0.78, 0.75),
    ]

    public static func color(_ index: Int, alpha: CGFloat = 1) -> CGColor {
        let c = palette[abs(index) % palette.count]
        return CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
    }

    /// Returns `image` with `result` drawn on it, at the image's own resolution.
    public static func render(_ result: VisionResult, over image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: bounds)
        // Switch to a top-left origin for everything drawn on top.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let unit = max(CGFloat(max(width, height)) / 640, 1)

        func pixelRect(_ normalized: CGRect) -> CGRect {
            CGRect(x: normalized.minX * CGFloat(width), y: normalized.minY * CGFloat(height),
                   width: normalized.width * CGFloat(width), height: normalized.height * CGFloat(height))
        }

        switch result {
        case .detections(let detections):
            for detection in detections.reversed() {
                let rect = pixelRect(detection.boundingBox)
                context.setStrokeColor(color(detection.classIndex))
                context.setLineWidth(2.5 * unit)
                context.stroke(rect)
                drawLabel("\(detection.label) \(String(format: "%.2f", detection.confidence))", at: CGPoint(x: rect.minX, y: rect.minY),
                          background: color(detection.classIndex), unit: unit, in: context)
            }
        case .poses(let poses):
            for (index, pose) in poses.enumerated() {
                let tint = color(index)
                context.setStrokeColor(tint)
                context.setLineWidth(2.5 * unit)
                for (a, b) in Pose.skeleton where pose.keypoints[a].confidence > 0.5 && pose.keypoints[b].confidence > 0.5 {
                    let p = pose.keypoints[a].position, q = pose.keypoints[b].position
                    context.move(to: CGPoint(x: p.x * CGFloat(width), y: p.y * CGFloat(height)))
                    context.addLine(to: CGPoint(x: q.x * CGFloat(width), y: q.y * CGFloat(height)))
                    context.strokePath()
                }
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                for keypoint in pose.keypoints where keypoint.confidence > 0.5 {
                    let r = 3.5 * unit
                    context.fillEllipse(in: CGRect(x: keypoint.position.x * CGFloat(width) - r, y: keypoint.position.y * CGFloat(height) - r, width: 2 * r, height: 2 * r))
                }
                let rect = pixelRect(pose.boundingBox)
                context.setLineWidth(1.5 * unit)
                context.stroke(rect)
                drawLabel(pose.trackID.map { "person #\($0)" } ?? String(format: "person %.2f", pose.confidence), at: CGPoint(x: rect.minX, y: rect.minY), background: tint, unit: unit, in: context)
            }
        case .classifications(let classes):
            var y: CGFloat = 8 * unit
            for (index, item) in classes.prefix(5).enumerated() {
                let name = item.label.split(separator: ",").first.map(String.init) ?? item.label
                drawLabel(String(format: "%@  %.1f%%", name, item.probability * 100), at: CGPoint(x: 8 * unit, y: y + 22 * unit),
                          background: color(index == 0 ? 2 : 0, alpha: index == 0 ? 1 : 0.75), unit: unit * 1.3, in: context)
                y += 26 * unit
            }
        case .depth(let map):
            if let overlay = depthImage(map) {
                context.saveGState()
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .medium
                context.draw(overlay, in: bounds)
                context.restoreGState()
            }
        case .instances(let items):
            drawInstances(items, in: context, width: width, height: height, unit: unit)
        case .orientedDetections(let items):
            drawOriented(items, in: context, width: width, height: height, unit: unit)
        case .lanes(let items):
            drawLanes(items, in: context, width: width, height: height, unit: unit)
        case .faces(let items):
            drawFaces(items, in: context, width: width, height: height, unit: unit)
        case .text(let items):
            drawText(items, in: context, width: width, height: height, unit: unit)
        case .described(let items):
            drawDescribed(items, in: context, width: width, height: height, unit: unit)
        case .faceLandmarks(let items):
            drawFaceLandmarks(items, in: context, width: width, height: height, unit: unit)
        case .image(let output):
            // The model's picture replaces the source; it may have a different size.
            return output.image
        case .segmentation(let map):
            if let overlay = segmentationImage(map) {
                context.saveGState()
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .none
                context.setAlpha(0.6)
                context.draw(overlay, in: bounds)
                context.restoreGState()
            }
        }
        return context.makeImage()
    }

    /// Depth as a colour image at the map's resolution: near is warm, far is cool.
    public static func depthImage(_ map: DepthMap) -> CGImage? {
        guard let low = map.values.min(), let high = map.values.max(), high > low else { return nil }
        var pixels = [UInt8](repeating: 255, count: map.width * map.height * 4)
        for i in 0..<(map.width * map.height) {
            let t = (map.values[i] - low) / (high - low)  // 0 near, 1 far
            let (r, g, b) = turbo(1 - t)
            pixels[4 * i] = r
            pixels[4 * i + 1] = g
            pixels[4 * i + 2] = b
        }
        return makeImage(pixels, width: map.width, height: map.height)
    }

    /// Class map as a colour image at the map's resolution, in the class set's colours. The background
    /// class (if the set has one) stays transparent, so only the found things are tinted.
    public static func segmentationImage(_ map: SegmentationMap) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: map.width * map.height * 4)
        for i in 0..<min(map.classes.count, map.width * map.height) {
            let index = Int(map.classes[i])
            guard index != map.background else { continue }
            let color = index < map.colors.count ? map.colors[index] : [0, 0, 0]
            pixels[4 * i] = color[0]
            pixels[4 * i + 1] = color[1]
            pixels[4 * i + 2] = color[2]
            pixels[4 * i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: map.width, height: map.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: map.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    public static func makeImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Compact approximation of the "turbo" colour map. `t` runs from 0 (blue) to 1 (red).
    static func turbo(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let x = min(max(t, 0), 1)
        let r = 0.1357 + x * (4.5974 - x * (42.3277 - x * (130.5887 - x * (150.5666 - x * 58.1375))))
        let g = 0.0914 + x * (2.1856 + x * (4.8052 - x * (14.0195 - x * (4.2109 + x * 2.7747))))
        let b = 0.1067 + x * (12.5925 - x * (60.1097 - x * (109.0745 - x * (88.5066 - x * 26.8183))))
        func byte(_ v: Float) -> UInt8 { UInt8(min(max(v, 0), 1) * 255) }
        return (byte(r), byte(g), byte(b))
    }

    /// Draws white text on a filled tag whose bottom-left corner is at `point` (top-left origin context).
    static func drawLabel(_ text: String, at point: CGPoint, background: CGColor, unit: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 12 * unit, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let textBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padding = 3 * unit
        let tagHeight = textBounds.height + 2 * padding
        let top = max(point.y - tagHeight, 0)
        let tag = CGRect(x: max(point.x, 0), y: top, width: textBounds.width + 2 * padding, height: tagHeight)
        context.setFillColor(background)
        context.fill(tag)
        context.saveGState()
        // Text needs an unflipped matrix.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: tag.minX + padding, y: tag.maxY - padding - textBounds.minY.magnitude)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
