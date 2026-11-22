import CoreGraphics
import Foundation

/// How an image is fitted to a model's input size.
public enum ResizeMode: Sendable {
    /// Scale to fit and pad the rest with grey, keeping the aspect ratio. What YOLO models expect.
    case letterbox
    /// Scale each axis independently to fill the input.
    case stretch
}

/// An image converted to a model's RGB888 input, with what is needed to map results back.
public struct PreparedFrame: Sendable {
    public init(rgb: [UInt8], width: Int, height: Int, sourceWidth: Int, sourceHeight: Int, contentRect: CGRect,
                sourceRegion: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
        self.rgb = rgb
        self.width = width
        self.height = height
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.contentRect = contentRect
        self.sourceRegion = sourceRegion
    }

    public let rgb: [UInt8]
    public let width: Int
    public let height: Int
    public let sourceWidth: Int
    public let sourceHeight: Int
    /// The part of the model input covered by the image, in input pixels.
    public let contentRect: CGRect
    /// The part of the source image that was given to the model, normalized (the whole image by default).
    public let sourceRegion: CGRect

    /// Maps a point in model-input pixels to normalized source-image coordinates (0...1, origin top-left).
    public func toSource(x: CGFloat, y: CGFloat) -> CGPoint {
        let inRegion = CGPoint(x: (x - contentRect.minX) / contentRect.width, y: (y - contentRect.minY) / contentRect.height)
        return CGPoint(x: sourceRegion.minX + inRegion.x * sourceRegion.width, y: sourceRegion.minY + inRegion.y * sourceRegion.height)
    }

    /// Maps a rectangle in model-input pixels to normalized source-image coordinates, clamped to the image.
    public func toSource(_ rect: CGRect) -> CGRect {
        let a = toSource(x: rect.minX, y: rect.minY)
        let b = toSource(x: rect.maxX, y: rect.maxY)
        let x0 = min(max(a.x, 0), 1), y0 = min(max(a.y, 0), 1)
        let x1 = min(max(b.x, 0), 1), y1 = min(max(b.y, 0), 1)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}

public enum ImagePrep {
    public static let padGrey: CGFloat = 114.0 / 255.0

    /// Draws `image`, or the normalized `region` of it, into a `width` x `height` RGB888 buffer.
    public static func prepare(_ source: CGImage, width: Int, height: Int, mode: ResizeMode,
                               region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), pad: CGFloat = padGrey) throws -> PreparedFrame {
        var image = source
        if region != CGRect(x: 0, y: 0, width: 1, height: 1) {
            let pixels = CGRect(x: region.minX * CGFloat(source.width), y: region.minY * CGFloat(source.height),
                                width: region.width * CGFloat(source.width), height: region.height * CGFloat(source.height)).integral
            guard let cropped = source.cropping(to: pixels) else { throw StudioError.invalidInput("Could not crop the image.") }
            image = cropped
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var content = CGRect(x: 0, y: 0, width: width, height: height)
        if mode == .letterbox {
            let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
            let w = (CGFloat(image.width) * scale).rounded()
            let h = (CGFloat(image.height) * scale).rounded()
            content = CGRect(x: ((CGFloat(width) - w) / 2).rounded(.down), y: ((CGFloat(height) - h) / 2).rounded(.down), width: w, height: h)
        }
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.setFillColor(red: pad, green: pad, blue: pad, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .medium
            // CoreGraphics has its origin at the bottom-left; the buffer's first row is the top.
            let flipped = CGRect(x: content.minX, y: CGFloat(height) - content.maxY, width: content.width, height: content.height)
            context.draw(image, in: flipped)
            return true
        }
        guard drawn else { throw StudioError.invalidInput("Could not create a bitmap context for the image.") }

        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        rgba.withUnsafeBytes { source in
            rgb.withUnsafeMutableBytes { destination in
                var s = 0, d = 0
                let count = width * height
                for _ in 0..<count {
                    destination[d] = source[s]
                    destination[d + 1] = source[s + 1]
                    destination[d + 2] = source[s + 2]
                    s += 4
                    d += 3
                }
            }
        }
        return PreparedFrame(rgb: rgb, width: width, height: height, sourceWidth: source.width, sourceHeight: source.height,
                             contentRect: content, sourceRegion: region)
    }

    /// Cuts a rotated rectangle out of `image` and returns it upright. `quad` holds the corners in the
    /// order top-left, top-right, bottom-right, bottom-left, normalized to the image.
    public static func crop(_ image: CGImage, quad: [CGPoint]) -> CGImage? {
        guard quad.count == 4 else { return nil }
        let points = quad.map { CGPoint(x: $0.x * CGFloat(image.width), y: $0.y * CGFloat(image.height)) }
        let width = Int(hypot(points[1].x - points[0].x, points[1].y - points[0].y).rounded())
        let height = Int(hypot(points[3].x - points[0].x, points[3].y - points[0].y).rounded())
        guard width >= 2, height >= 2 else { return nil }
        let angle = atan2(points[1].y - points[0].y, points[1].x - points[0].x)
        // Maps the quad's top-left corner to the origin and its top edge onto the x axis.
        let transform = CGAffineTransform(rotationAngle: -angle).translatedBy(x: -points[0].x, y: -points[0].y)
        return draw(image, into: CGSize(width: width, height: height), transform: transform)
    }

    /// Draws `image` through `transform` (source pixels to destination pixels, both with a top-left
    /// origin) into a new image of `size`.
    public static func draw(_ image: CGImage, into size: CGSize, transform: CGAffineTransform) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // Top-left origin for the destination, then the caller's transform, then the source drawn the right way up.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.concatenate(transform)
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
