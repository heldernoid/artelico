import CoreGraphics
import Foundation

/// Picture-in, picture-out models on whole photos: super-resolution (real_esrgan_x2, espcn x2/x3/x4), low
/// light (zero_dce, zero_dce_pp) and denoising (dncnn_color_blind, dncnn3). Each takes a fixed tile, so the
/// photo is cut into overlapping tiles and each tile's middle goes into the result (borders do not show).
///
/// Models with one channel (espcn, dncnn3) work on brightness only: the photo's luma goes in, and the
/// result's luma is put back together with the photo's colour (as the Model Zoo's ESPCN evaluation does).
public enum PictureModels {
    /// Longest side of a result. Larger photos are scaled down first.
    public static let maximumOutputSide = 4096

    public struct Shape: Sendable, Equatable {
        public let tileWidth: Int, tileHeight: Int, channels: Int, scale: Int
    }

    /// The tile, channels and scale of a picture model; nil when the model is not one.
    public static func shape(_ model: ModelInfo) -> Shape? {
        guard model.inputs.count == 1, model.outputs.count == 1,
              let input = model.inputs.first, let output = model.outputs.first, output.order == "NHWC",
              let tw = input.width, let th = input.height, let ow = output.width, let oh = output.height,
              let channels = input.features, channels == output.features, channels == 1 || channels == 3,
              tw > 16, th > 16, ow % tw == 0, oh % th == 0, ow / tw == oh / th else { return nil }
        return Shape(tileWidth: tw, tileHeight: th, channels: channels, scale: ow / tw)
    }

    /// ESPCN was trained on BT.601 studio-range luma (16...235); the others take plain pixels.
    static func studioRange(_ model: ModelInfo) -> Bool { model.name.hasPrefix("espcn") }

    /// Runs the loaded model over the whole photo; `progress` gets (tiles done, tiles).
    public static func run(_ image: CGImage, device: any InferenceEngine, progress: ((Int, Int) -> Void)? = nil) async throws -> CGImage {
        guard let model = await device.loadedModel, let shape = shape(model) else {
            throw StudioError.invalidInput("Load a picture-to-picture model first.")
        }
        // Keep the result within the size limit.
        let fit = min(1, Double(maximumOutputSide) / Double(max(image.width, image.height) * shape.scale))
        let width = max(1, Int(Double(image.width) * fit)), height = max(1, Int(Double(image.height) * fit))
        let source = try ImagePrep.prepare(image, width: width, height: height, mode: .stretch).rgb
        let studio = studioRange(model)

        // What goes in: the pixels, or one luma channel.
        let plane: [UInt8]
        if shape.channels == 3 {
            plane = source
        } else {
            plane = (0..<(width * height)).map { i in
                let r = Double(source[3 * i]), g = Double(source[3 * i + 1]), b = Double(source[3 * i + 2])
                let y = studio ? 16 + 0.25678824 * r + 0.50412941 * g + 0.09790588 * b : 0.299 * r + 0.587 * g + 0.114 * b
                return UInt8(min(255, max(0, y.rounded())))
            }
        }

        let c = shape.channels, s = shape.scale, tw = shape.tileWidth, th = shape.tileHeight
        let margin = min(16, tw / 8, th / 8)
        let stepX = tw - 2 * margin, stepY = th - 2 * margin
        let columns = max(1, Int((Double(width) / Double(stepX)).rounded(.up)))
        let rows = max(1, Int((Double(height) / Double(stepY)).rounded(.up)))
        let outWidth = width * s, outHeight = height * s, outTileWidth = tw * s
        var result = [Float](repeating: 0, count: outWidth * outHeight * c)
        var done = 0
        for row in 0..<rows {
            for column in 0..<columns {
                let coreX = column * stepX, coreY = row * stepY
                var tile = [UInt8](repeating: 0, count: tw * th * c)
                for y in 0..<th {
                    let sy = min(max(coreY - margin + y, 0), height - 1)   // outside the photo: repeat the edge
                    for x in 0..<tw {
                        let sx = min(max(coreX - margin + x, 0), width - 1)
                        for k in 0..<c { tile[(y * tw + x) * c + k] = plane[(sy * width + sx) * c + k] }
                    }
                }
                let values = try await device.infer(inputs: [tile])[0].floats()
                let coreWidth = min(stepX, width - coreX), coreHeight = min(stepY, height - coreY)
                for y in 0..<(coreHeight * s) {
                    let ty = y + margin * s, oy = coreY * s + y
                    for x in 0..<(coreWidth * s) {
                        let from = (ty * outTileWidth + x + margin * s) * c, to = (oy * outWidth + coreX * s + x) * c
                        guard from + c - 1 < values.count else { continue }
                        for k in 0..<c { result[to + k] = values[from + k] }
                    }
                }
                done += 1
                progress?(done, rows * columns)
            }
        }

        // Back to RGBA pixels.
        var pixels = [UInt8](repeating: 255, count: outWidth * outHeight * 4)
        func byte(_ v: Double) -> UInt8 { UInt8(min(255, max(0, v.rounded()))) }
        for y in 0..<outHeight {
            for x in 0..<outWidth {
                let o = y * outWidth + x, d = o * 4
                if c == 3 {
                    for k in 0..<3 { pixels[d + k] = byte(Double(min(max(result[o * 3 + k], 0), 1)) * 255) }
                    continue
                }
                // Colour from the photo (nearest pixel), brightness from the model.
                let sx = min(width - 1, x / s), sy = min(height - 1, y / s), i = (sy * width + sx) * 3
                let r = Double(source[i]), g = Double(source[i + 1]), b = Double(source[i + 2])
                let luma = Double(min(max(result[o], 0), 1)) * 255
                if studio {
                    let u = 128 - 0.14822353 * r - 0.29099216 * g + 0.43921569 * b
                    let v = 128 + 0.43921569 * r - 0.36778824 * g - 0.07142745 * b
                    let yy = 1.16438355 * (luma - 16)
                    pixels[d] = byte(yy + 1.59602715 * (v - 128))
                    pixels[d + 1] = byte(yy - 0.3917616 * (u - 128) - 0.81296805 * (v - 128))
                    pixels[d + 2] = byte(yy + 2.01723105 * (u - 128))
                } else {
                    let old = 0.299 * r + 0.587 * g + 0.114 * b
                    pixels[d] = byte(r + luma - old); pixels[d + 1] = byte(g + luma - old); pixels[d + 2] = byte(b + luma - old)
                }
            }
        }
        guard let output = VisionRenderer.makeImage(pixels, width: outWidth, height: outHeight) else {
            throw StudioError.invalidInput("Could not build the picture.")
        }
        return output
    }
}
