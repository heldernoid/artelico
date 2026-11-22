import CoreGraphics
import Foundation

/// Finds small objects by running a detector on overlapping tiles of the picture as well as on the
/// whole picture, then merging the boxes. This is what Hailo Studio's "Small objects (tiling)" does.
public enum Tiling {
    /// Fraction of a tile shared with its neighbour, so objects on a seam are whole in one of them.
    static let overlap: CGFloat = 0.2
    static let mergeIoU: Float = 0.5

    /// Tile rectangles in normalized image coordinates for a `columns` x `rows` grid.
    public static func tiles(columns: Int, rows: Int) -> [CGRect] {
        guard columns > 1 || rows > 1 else { return [] }
        let width = (1 + overlap * CGFloat(columns - 1)) / CGFloat(columns)
        let height = (1 + overlap * CGFloat(rows - 1)) / CGFloat(rows)
        var result: [CGRect] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x = columns == 1 ? 0 : CGFloat(column) * (1 - width) / CGFloat(columns - 1)
                let y = rows == 1 ? 0 : CGFloat(row) * (1 - height) / CGFloat(rows - 1)
                result.append(CGRect(x: x, y: y, width: width, height: height))
            }
        }
        return result
    }

    /// Runs the loaded detector on the whole image and on each tile, all in flight together, and
    /// returns the merged detections in whole-image coordinates.
    public static func detect(_ image: CGImage, device: any InferenceEngine, columns: Int, rows: Int) async throws -> [Detection] {
        guard let model = await device.loadedModel, VisionPipeline.supports(.detection, model: model) else {
            throw StudioError.invalidInput("Load a detection model before tiling.")
        }
        // The whole picture first, then the tiles.
        var regions: [CGRect] = [CGRect(x: 0, y: 0, width: 1, height: 1)]
        regions += tiles(columns: columns, rows: rows)

        var frames: [PreparedFrame] = []
        for region in regions {
            let pixels = CGRect(x: region.minX * CGFloat(image.width), y: region.minY * CGFloat(image.height),
                                width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height)).integral
            guard let crop = image.cropping(to: pixels) else { continue }
            frames.append(try VisionPipeline.prepare(crop, for: model, task: .detection))
        }

        // Submit in batches no larger than the device's queue, collecting each batch in order.
        var all: [Detection] = []
        let batch = max(1, min(await device.queueSize, 8))
        var index = 0
        while index < frames.count {
            let end = min(index + batch, frames.count)
            for i in index..<end { try await device.submit(inputs: [frames[i].rgb]) }
            for i in index..<end {
                let tensors = try await device.collect()
                guard case .detections(let found) = VisionPipeline.decode(tensors, task: .detection, model: model, frame: frames[i]) else { continue }
                let region = regions[i]
                // Map from the tile's coordinates back to the whole picture.
                all += found.map { detection in
                    let box = detection.boundingBox
                    return Detection(label: detection.label, classIndex: detection.classIndex, confidence: detection.confidence,
                                     boundingBox: CGRect(x: region.minX + box.minX * region.width, y: region.minY + box.minY * region.height,
                                                         width: box.width * region.width, height: box.height * region.height))
                }
            }
            index = end
        }
        return merge(all)
    }

    /// Class-aware non-maximum suppression across tiles. A box mostly inside a larger box of the same
    /// class is also dropped, which removes halves of objects cut by a tile edge.
    static func merge(_ detections: [Detection]) -> [Detection] {
        var kept: [Detection] = []
        for candidate in detections.sorted(by: { $0.confidence > $1.confidence }) {
            let duplicate = kept.contains { other in
                guard other.classIndex == candidate.classIndex else { return false }
                if PostProcess.iou(other.boundingBox, candidate.boundingBox) > mergeIoU { return true }
                let intersection = other.boundingBox.intersection(candidate.boundingBox)
                guard !intersection.isNull else { return false }
                let area = candidate.boundingBox.width * candidate.boundingBox.height
                return area > 0 && (intersection.width * intersection.height) / area > 0.8
            }
            if !duplicate { kept.append(candidate) }
        }
        return kept
    }
}
