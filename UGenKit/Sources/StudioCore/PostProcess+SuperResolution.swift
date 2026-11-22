import CoreGraphics
import Foundation

extension PostProcess {
    /// real_esrgan_x2: one RGB image at twice the input size; values are 0...1 after de-quantization.
    public static func superResolved(_ tensor: Tensor) -> OutputImage? {
        guard tensor.features == 3 else { return nil }
        let values = tensor.floats()
        var pixels = [UInt8](repeating: 255, count: tensor.width * tensor.height * 4)
        for i in 0..<(tensor.width * tensor.height) {
            for channel in 0..<3 {
                pixels[4 * i + channel] = UInt8(min(max(values[3 * i + channel], 0), 1) * 255 + 0.5)
            }
        }
        return VisionRenderer.makeImage(pixels, width: tensor.width, height: tensor.height).map(OutputImage.init)
    }
}
