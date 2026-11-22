import Foundation

/// The classes a semantic segmentation model was trained on, with a colour per class.
public struct SegmentationClasses: Sendable {
    public let labels: [String]
    /// RGB per class.
    public let colors: [[UInt8]]
    /// The class left uncoloured in pictures ("background"), if the set has one.
    public let background: Int?
}

extension Labels {
    /// Pascal VOC 2012 (deeplab_v3_mobilenet_v2 and _wo_dilation; Model Zoo cfg/base/pascal.yaml), with
    /// the dataset's own colour map.
    public static let pascalVOC = SegmentationClasses(
        labels: ["background", "aeroplane", "bicycle", "bird", "boat", "bottle", "bus", "car", "cat", "chair", "cow",
                 "dining table", "dog", "horse", "motorbike", "person", "potted plant", "sheep", "sofa", "train", "tv monitor"],
        colors: (0..<21).map(vocColor), background: 0)

    /// Oxford-IIIT Pet trimaps as in TensorFlow's segmentation tutorial (unet_mobilenet_v2; the Model
    /// Zoo's labels_offset 1 turns the dataset's 1, 2, 3 into 0, 1, 2).
    public static let oxfordPet = SegmentationClasses(
        labels: ["pet", "background", "pet outline"],
        colors: [[255, 140, 0], [0, 0, 0], [255, 230, 80]], background: 1)

    public static let cityscapesClasses = SegmentationClasses(labels: cityscapes, colors: cityscapesColors, background: nil)

    /// The class set of a segmentation model, from the dataset its Model Zoo config names.
    public static func segmentation(for model: ModelInfo) -> SegmentationClasses {
        if model.name.hasPrefix("deeplab") { return pascalVOC }
        if model.name.hasPrefix("unet") { return oxfordPet }
        return cityscapesClasses   // fcn8_resnet_v1_18, segformer_b0_bn, stdc1 (cfg/base/fcn.yaml)
    }

    /// The Pascal VOC colour of class `index` (bits of the index spread over the high bits of R, G, B).
    private static func vocColor(_ index: Int) -> [UInt8] {
        var r = 0, g = 0, b = 0, c = index
        for shift in stride(from: 7, through: 0, by: -1) where c > 0 {
            r |= (c & 1) << shift; g |= ((c >> 1) & 1) << shift; b |= ((c >> 2) & 1) << shift
            c >>= 3
        }
        return [UInt8(r), UInt8(g), UInt8(b)]
    }
}
