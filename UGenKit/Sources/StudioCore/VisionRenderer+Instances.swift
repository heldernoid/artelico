import CoreGraphics
import CoreText
import Foundation

extension VisionRenderer {
    /// Draws into a context whose origin is the top-left of a `width` x `height` image.
    /// `unit` is the line-width and text scale for this image size.
    /// Each instance gets its own colour: a translucent mask, then its box and label on top.
    /// Class-less segments (segment everything, often dozens) are drawn as masks only, largest first so
    /// small parts stay visible on top of the regions around them.
    static func drawInstances(_ items: [Instance], in context: CGContext, width: Int, height: Int, unit: CGFloat) {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let classless = !items.isEmpty && items.allSatisfy { $0.detection.classIndex < 0 }
        let order = classless
            ? Array(items.enumerated()).sorted { $0.element.detection.boundingBox.width * $0.element.detection.boundingBox.height
                                                 > $1.element.detection.boundingBox.width * $1.element.detection.boundingBox.height }
            : Array(items.enumerated().reversed())

        // Masks first, so no box or label is hidden under a later mask.
        for (index, item) in order {
            guard let overlay = maskImage(item, colorIndex: index, alpha: 0.5) else { continue }
            context.saveGState()
            // Images draw bottom-up; flip locally so the mask's first row lands at the top.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .medium
            context.draw(overlay, in: bounds)
            context.restoreGState()
        }

        guard !classless else { return }
        for (index, item) in items.enumerated().reversed() {
            let box = item.detection.boundingBox
            let rect = CGRect(x: box.minX * CGFloat(width), y: box.minY * CGFloat(height),
                              width: box.width * CGFloat(width), height: box.height * CGFloat(height))
            context.setStrokeColor(color(index))
            context.setLineWidth(2 * unit)
            context.stroke(rect)
            drawLabel("\(item.detection.label) \(String(format: "%.2f", item.detection.confidence))", at: CGPoint(x: rect.minX, y: rect.minY),
                      background: color(index), unit: unit, in: context)
        }
    }

    /// The instance's mask as an image at the mask's resolution: its colour where the mask is set, clear elsewhere.
    static func maskImage(_ item: Instance, colorIndex: Int, alpha: CGFloat) -> CGImage? {
        let count = item.maskWidth * item.maskHeight
        guard count > 0, item.mask.count >= count else { return nil }
        let c = palette[abs(colorIndex) % palette.count]
        // Premultiplied RGBA.
        let r = UInt8(c.0 * alpha * 255), g = UInt8(c.1 * alpha * 255), b = UInt8(c.2 * alpha * 255), a = UInt8(alpha * 255)
        var pixels = [UInt8](repeating: 0, count: count * 4)
        for i in 0..<count where item.mask[i] != 0 {
            pixels[4 * i] = r
            pixels[4 * i + 1] = g
            pixels[4 * i + 2] = b
            pixels[4 * i + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: item.maskWidth, height: item.maskHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: item.maskWidth * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
