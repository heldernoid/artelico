import CoreGraphics
import Foundation

/// Raises the resolution of a whole photo with real_esrgan_x2 or espcn (see PictureModels).
/// The photo is cut into overlapping 512x512 tiles; each tile is upscaled on the stick and the middle
/// of every result is stitched into the output, so tile borders do not show.
public enum SuperResolution {
    /// Pixels of context kept around each tile and thrown away after upscaling.
    static let margin = 16
    /// Longest side accepted. A 2048-pixel side means up to 25 tiles at about 0.4 s each.
    public static let maximumSide = 2048

    public static func upscale(_ image: CGImage, device: any InferenceEngine) async throws -> (image: CGImage, tiles: Int) {
        guard let model = await device.loadedModel, let shape = PictureModels.shape(model), shape.scale > 1 else {
            throw StudioError.invalidInput("Load a super-resolution model (real_esrgan_x2 or espcn) before upscaling.")
        }
        var tiles = 0
        let result = try await PictureModels.run(image, device: device) { _, total in tiles = total }
        return (result, tiles)
    }
}
