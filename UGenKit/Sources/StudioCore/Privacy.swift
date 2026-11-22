import CoreGraphics
import CoreImage
import Foundation

// Privacy camera: faces, licence plates and/or whole people are hidden in every frame before it is shown,
// recorded or served, so the original picture never leaves the analysis step. The idea of hailo-apps'
// `face-blur` overlay option, extended to plates (text found on vehicles), any text (signs, papers, screens)
// and people (instance masks).

/// How hidden parts look.
public enum PrivacyStyle: String, CaseIterable, Sendable {
    case blur = "Blur"
    case pixelate = "Pixelate"
    case fill = "Solid"
}

/// One part of the picture to hide.
public struct PrivacyRegion: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case face, plate, text, person
    }

    public var kind: Kind
    /// Fraction of the picture, top-left origin (the camera's own orientation, never mirrored).
    public var box: CGRect
    /// People: the instance's mask over the whole picture, so the background around them stays visible.
    public var mask: Instance?

    public init(kind: Kind, box: CGRect, mask: Instance? = nil) {
        self.kind = kind
        self.box = box
        self.mask = mask
    }
}

/// Keeps a region hidden for a while after its detector last saw it: a face missed for a frame or two
/// (head turning, motion blur) would otherwise flash into view.
public struct RegionHold: Sendable {
    private struct Held: Sendable {
        var region: PrivacyRegion
        var seen: Double
    }

    private var held: [Held] = []
    /// How long a region stays hidden after it was last found.
    public var seconds: Double

    public init(seconds: Double = 0.6) {
        self.seconds = seconds
    }

    /// The regions to hide at `time`: everything found now, plus earlier ones not found again (by kind and
    /// overlap) that are still within `seconds`.
    public mutating func update(_ found: [PrivacyRegion], time: Double) -> [PrivacyRegion] {
        var next = found.map { Held(region: $0, seen: time) }
        for old in held where time - old.seen <= seconds {
            let foundAgain = found.contains { $0.kind == old.region.kind && PostProcess.iou($0.box, old.region.box) > 0.2 }
            if !foundAgain { next.append(old) }
        }
        held = next
        return next.map(\.region)
    }

    public mutating func reset() { held = [] }
}

/// Finds what to hide in a picture with models already loaded on `device`.
public enum PrivacyScan {
    /// Face detectors in order of preference: scrfd_10g finds small, turned and partly covered faces best.
    public static let faceDetectorNames = ["scrfd_10g", "scrfd_2.5g", "retinaface_mobilenet_v1", "scrfd_500m"]
    /// Vehicles whose plates are looked for.
    public static let vehicleLabels: Set<String> = ["car", "truck", "bus", "motorcycle"]
    /// Plates are looked for on at most this many vehicles per frame (the largest), to keep the frame rate.
    public static let maxVehicles = 4

    /// Faces, each box grown so hair, ears and chin are covered too.
    public static func faces(_ image: CGImage, detector: ModelInfo, device: any InferenceEngine) async throws -> [PrivacyRegion] {
        let frame = try VisionPipeline.prepare(image, for: detector, task: .face)
        let found = PostProcess.faces(try await device.infer(inputs: [frame.rgb], model: detector.name), model: detector, frame: frame)
        return found.map { PrivacyRegion(kind: .face, box: grow($0.boundingBox, x: 0.2, top: 0.35, bottom: 0.15)) }
    }

    /// Licence plates: text found by `ocr_det` inside the vehicles' boxes (a vehicle's other lettering is
    /// hidden too). Reading the text is not needed to hide it, so the recogniser is not run.
    public static func plates(_ image: CGImage, vehicles: [CGRect], device: any InferenceEngine) async throws -> [PrivacyRegion] {
        let largest = vehicles.sorted { $0.width * $0.height > $1.width * $1.height }.prefix(maxVehicles)
        var regions: [PrivacyRegion] = []
        for vehicle in largest {
            regions += try await text(image, in: vehicle, kind: .plate, device: device)
        }
        return regions
    }

    /// Text anywhere in `area` of the picture (the whole picture by default): signs, papers, screens, badges.
    public static func text(_ image: CGImage, in area: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), kind: PrivacyRegion.Kind = .text,
                            device: any InferenceEngine) async throws -> [PrivacyRegion] {
        guard let detector = ModelCatalog.model(named: TextReader.detectorName) else { return [] }
        let region = area.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixels = CGRect(x: region.minX * CGFloat(image.width), y: region.minY * CGFloat(image.height),
                            width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height)).integral
        guard pixels.width >= 16, pixels.height >= 16, let crop = image.cropping(to: pixels) else { return [] }
        let frame = try VisionPipeline.prepare(crop, for: detector, task: .textDetection)
        let tensors = try await device.infer(inputs: [frame.rgb], model: detector.name)
        return PostProcess.textRegions(tensors[0], frame: frame).compactMap { text in
            let xs = text.corners.map(\.x), ys = text.corners.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
            let box = CGRect(x: region.minX + minX * region.width, y: region.minY + minY * region.height,
                             width: (maxX - minX) * region.width, height: (maxY - minY) * region.height)
            return PrivacyRegion(kind: kind, box: grow(box, x: 0.15, top: 0.3, bottom: 0.3))
        }
    }

    /// People from an instance-segmentation result, with their masks.
    public static func people(_ instances: [Instance]) -> [PrivacyRegion] {
        instances.filter { $0.detection.label == "person" }.map { PrivacyRegion(kind: .person, box: $0.detection.boundingBox, mask: $0) }
    }

    /// Vehicle boxes from an instance-segmentation result.
    public static func vehicles(_ instances: [Instance]) -> [CGRect] {
        instances.filter { vehicleLabels.contains($0.detection.label) }.map(\.detection.boundingBox)
    }

    /// `box` grown by fractions of its own size (left and right by `x`), kept inside the picture.
    static func grow(_ box: CGRect, x: CGFloat, top: CGFloat, bottom: CGFloat) -> CGRect {
        CGRect(x: box.minX - box.width * x, y: box.minY - box.height * top,
               width: box.width * (1 + 2 * x), height: box.height * (1 + top + bottom))
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

/// Hides regions of a picture with Core Image (on the GPU).
public enum PrivacyFilter {
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])

    /// The picture with `regions` hidden in `style`. Blur and pixel size follow the picture's size, strong
    /// enough that a face cannot be recognised. nil when Core Image fails: callers then show nothing rather
    /// than the original.
    public static func apply(_ image: CGImage, regions: [PrivacyRegion], style: PrivacyStyle) -> CGImage? {
        guard !regions.isEmpty else { return image }
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let unit = max(extent.width, extent.height) / 40

        let hidden: CIImage
        switch style {
        case .blur:
            hidden = input.clampedToExtent().applyingGaussianBlur(sigma: Double(unit)).cropped(to: extent)
        case .pixelate:
            hidden = input.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: unit, kCIInputCenterKey: CIVector(x: 0, y: 0),
            ]).cropped(to: extent)
        case .fill:
            hidden = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.14)).cropped(to: extent)
        }

        var mask = CIImage(color: .black).cropped(to: extent)
        for region in regions {
            mask = maskImage(region, extent: extent).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        }
        let output = hidden.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: input, kCIInputMaskImageKey: mask.cropped(to: extent),
        ])
        return context.createCGImage(output, from: extent)
    }

    /// White where `region` is hidden, over `extent` (Core Image's origin is bottom-left).
    static func maskImage(_ region: PrivacyRegion, extent: CGRect) -> CIImage {
        if let instance = region.mask, let cg = maskCGImage(instance) {
            // The mask covers the whole picture at the model's resolution: scale it up and widen it a little,
            // so the edges of a moving person are covered too.
            let scaled = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(instance.maskWidth),
                                                                                y: extent.height / CGFloat(instance.maskHeight)))
            return scaled.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(extent.width, extent.height) / 90])
                .cropped(to: extent)
        }
        let r = CGRect(x: region.box.minX * extent.width, y: (1 - region.box.maxY) * extent.height,
                       width: region.box.width * extent.width, height: region.box.height * extent.height)
        return CIImage(color: .white).cropped(to: r)
    }

    private static func maskCGImage(_ instance: Instance) -> CGImage? {
        guard instance.maskWidth > 0, instance.maskHeight > 0, instance.mask.count == instance.maskWidth * instance.maskHeight,
              let provider = CGDataProvider(data: Data(instance.mask) as CFData) else { return nil }
        return CGImage(width: instance.maskWidth, height: instance.maskHeight, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: instance.maskWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
