import CoreGraphics
import Foundation

extension PostProcess {
    /// Reads HailoRT's NMS_WITH_BYTE_MASK output (the YOLOv5-seg "hpp" models: Hailo's post-processing
    /// runs on the device and returns finished instances). Layout, little-endian and packed:
    /// a UInt16 count, then per detection a 46-byte header (y_min, x_min, y_max, x_max normalized to the
    /// input, score as Float32; class as UInt16; mask size, an unused pointer and the mask's offset from
    /// the buffer start, each UInt64) followed by its mask: one byte (0 or 1) per input pixel over the box,
    /// from floor(x_min * width) to ceil(x_max * width), rows likewise (hailort.h, nms_post_process.hpp).
    static func byteMaskInstances(_ tensor: Tensor, frame: PreparedFrame, minimumConfidence: Float = 0.3) -> [Instance] {
        let headerSize = 46
        let bytes = tensor.bytes
        guard bytes.count >= 2 else { return [] }
        let labels = Labels.coco
        // Masks cover the picture's part of the input (the rest is letterbox padding), at input resolution.
        let content = frame.contentRect.integral.intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        let originX = Int(content.minX), originY = Int(content.minY)
        let maskWidth = Int(content.width), maskHeight = Int(content.height)
        guard maskWidth > 0, maskHeight > 0 else { return [] }

        return bytes.withUnsafeBytes { raw -> [Instance] in
            let count = Int(raw.loadUnaligned(as: UInt16.self))
            var instances: [Instance] = []
            var offset = 2
            for _ in 0..<count {
                guard offset + headerSize <= raw.count else { break }
                func float(_ field: Int) -> Float { raw.loadUnaligned(fromByteOffset: offset + 4 * field, as: Float.self) }
                let yMin = float(0), xMin = float(1), yMax = float(2), xMax = float(3), score = float(4)
                let classIndex = Int(raw.loadUnaligned(fromByteOffset: offset + 20, as: UInt16.self))
                let maskSize = Int(raw.loadUnaligned(fromByteOffset: offset + 22, as: UInt64.self))
                let maskOffset = Int(raw.loadUnaligned(fromByteOffset: offset + 38, as: UInt64.self))
                guard maskOffset + maskSize <= raw.count else { break }
                offset = maskOffset + maskSize

                guard score >= minimumConfidence else { continue }
                let width = Float(frame.width), height = Float(frame.height)
                let left = max(Int((xMin * width).rounded(.down)), 0), right = min(Int((xMax * width).rounded(.up)), frame.width)
                let top = max(Int((yMin * height).rounded(.down)), 0), bottom = min(Int((yMax * height).rounded(.up)), frame.height)
                let boxWidth = right - left
                guard boxWidth > 0, bottom > top, boxWidth * (bottom - top) == maskSize else { continue }

                var mask = [UInt8](repeating: 0, count: maskWidth * maskHeight)
                let rows = max(top, originY)..<max(min(bottom, originY + maskHeight), max(top, originY))
                let columns = max(left, originX)..<max(min(right, originX + maskWidth), max(left, originX))
                for y in rows {
                    let source = maskOffset + (y - top) * boxWidth - left
                    let target = (y - originY) * maskWidth - originX
                    for x in columns where raw[source + x] != 0 { mask[target + x] = 255 }
                }
                let box = CGRect(x: CGFloat(xMin * width), y: CGFloat(yMin * height),
                                 width: CGFloat((xMax - xMin) * width), height: CGFloat((yMax - yMin) * height))
                let detection = Detection(label: classIndex < labels.count ? labels[classIndex] : "class \(classIndex)", classIndex: classIndex,
                                          confidence: score, boundingBox: frame.toSource(box))
                instances.append(Instance(detection: detection, maskWidth: maskWidth, maskHeight: maskHeight, mask: mask))
            }
            return instances
        }
    }
}
