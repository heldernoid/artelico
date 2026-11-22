import CoreGraphics
import Foundation

/// Picture-in, picture-out models on whole photos (the PhotoRestore demo: brighten with zero_dce,
/// denoise with dncnn_color_blind, upscale with real_esrgan_x2). Each model takes a fixed size, so the
/// photo is cut into overlapping tiles; each tile's middle goes into the result, so borders do not show.
public enum PhotoRestore {
    public enum Step: String, CaseIterable, Sendable {
        case brighten, denoise, upscale

        public var modelName: String {
            switch self {
            case .brighten: return "zero_dce"
            case .denoise: return "dncnn_color_blind"
            case .upscale: return "real_esrgan_x2"
            }
        }

        public var title: String {
            switch self {
            case .brighten: return "Brighten"
            case .denoise: return "Remove noise"
            case .upscale: return "Upscale ×2"
            }
        }
    }

    /// Tile origins covering `length` with tiles of `tile`, `overlap` shared; the last one flush with the
    /// end (as the demo's plan_tiles). A side shorter than the tile gets one tile at 0.
    public static func tileStarts(_ length: Int, tile: Int, overlap: Int = 16) -> [Int] {
        guard length > tile else { return [0] }
        let step = max(1, tile - overlap)
        var starts = Array(stride(from: 0, to: length - tile, by: step))
        starts.append(length - tile)
        return Array(Set(starts)).sorted()
    }

    /// Zero-DCE brightens even pictures that are not dark; cap the strength by the mean brightness
    /// (as the demo): mean < 40 -> up to 0.9, about 90 -> 0.45, above 150 -> 0.15.
    public static func brightenStrength(meanBrightness: Double, user: Double = 1) -> Double {
        min(user, max(0.15, min(0.9, (150 - meanBrightness) / 125)))
    }

    /// Mean brightness (0-255) of RGB888 pixels, as OpenCV's grey conversion.
    public static func meanBrightness(_ rgb: [UInt8]) -> Double {
        guard rgb.count >= 3 else { return 0 }
        var sum = 0.0
        var i = 0
        while i + 2 < rgb.count {
            sum += 0.299 * Double(rgb[i]) + 0.587 * Double(rgb[i + 1]) + 0.114 * Double(rgb[i + 2])
            i += 3
        }
        return sum / Double(rgb.count / 3)
    }

    /// Runs `model` (input tile w x h, output `scale` times larger, NHWC floats 0...1) over the whole
    /// picture. `progress` gets (done, total).
    public static func run(_ rgb: [UInt8], width: Int, height: Int, model: ModelInfo, device: any InferenceEngine,
                           progress: ((Int, Int) -> Void)? = nil) async throws -> (rgb: [UInt8], width: Int, height: Int) {
        guard let input = model.inputs.first, let tileW = input.width, let tileH = input.height,
              let outW = model.outputs.first?.width, outW % tileW == 0 else {
            throw StudioError.invalidInput("\(model.name) is not a picture-to-picture model.")
        }
        let scale = outW / tileW
        let margin = 16
        let stepX = max(1, tileW - 2 * margin), stepY = max(1, tileH - 2 * margin)
        let columns = max(1, Int((Double(width) / Double(stepX)).rounded(.up)))
        let rows = max(1, Int((Double(height) / Double(stepY)).rounded(.up)))
        let outWidth = width * scale, outHeight = height * scale
        var output = [UInt8](repeating: 0, count: outWidth * outHeight * 3)
        var done = 0
        for row in 0..<rows {
            for column in 0..<columns {
                let coreX = column * stepX, coreY = row * stepY
                // The tile around this core; outside the picture repeats the edge pixels.
                var tile = [UInt8](repeating: 0, count: tileW * tileH * 3)
                for y in 0..<tileH {
                    let sy = min(max(coreY - margin + y, 0), height - 1)
                    for x in 0..<tileW {
                        let sx = min(max(coreX - margin + x, 0), width - 1)
                        let s = (sy * width + sx) * 3, d = (y * tileW + x) * 3
                        tile[d] = rgb[s]; tile[d + 1] = rgb[s + 1]; tile[d + 2] = rgb[s + 2]
                    }
                }
                let values = try await device.infer(inputs: [tile], model: model.name)[0].floats()
                let coreWidth = min(stepX, width - coreX), coreHeight = min(stepY, height - coreY)
                let outTileW = tileW * scale
                for y in 0..<(coreHeight * scale) {
                    let ty = y + margin * scale, oy = coreY * scale + y
                    for x in 0..<(coreWidth * scale) {
                        let tx = x + margin * scale
                        let s = (ty * outTileW + tx) * 3, d = (oy * outWidth + coreX * scale + x) * 3
                        guard s + 2 < values.count else { continue }
                        for c in 0..<3 { output[d + c] = UInt8(min(max(values[s + c], 0), 1) * 255 + 0.5) }
                    }
                }
                done += 1
                progress?(done, rows * columns)
            }
        }
        return (output, outWidth, outHeight)
    }

    /// strength 0 = original, 1 = processed (the original is scaled when the sizes differ).
    public static func blend(original: [UInt8], width: Int, height: Int, processed: [UInt8], outWidth: Int, outHeight: Int,
                             strength: Double) -> [UInt8] {
        guard strength < 1 else { return processed }
        var out = processed
        for y in 0..<outHeight {
            let sy = min(height - 1, y * height / outHeight)
            for x in 0..<outWidth {
                let sx = min(width - 1, x * width / outWidth)
                let s = (sy * width + sx) * 3, d = (y * outWidth + x) * 3
                for c in 0..<3 {
                    out[d + c] = UInt8(min(255, max(0, Double(processed[d + c]) * strength + Double(original[s + c]) * (1 - strength)).rounded()))
                }
            }
        }
        return out
    }
}
