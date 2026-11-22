import Foundation

// Decoders for the models that describe one face or person crop (`CropTasks`): attributes and
// re-identification embeddings.

extension PostProcess {
    /// CelebA's 40 face attributes in the order of list_attr_celeba.txt, in plain words. "Attractive"
    /// (index 2) is a judgement, not something visible, so it is never shown.
    public static let celebaAttributes = [
        "stubble", "arched eyebrows", "attractive", "bags under eyes", "bald", "bangs", "big lips", "big nose",
        "black hair", "blond hair", "blurry", "brown hair", "bushy eyebrows", "chubby", "double chin", "glasses",
        "goatee", "grey hair", "heavy make-up", "high cheekbones", "male", "mouth open", "moustache", "narrow eyes",
        "no beard", "oval face", "pale skin", "pointy nose", "receding hairline", "rosy cheeks", "sideburns", "smiling",
        "straight hair", "wavy hair", "earrings", "hat", "lipstick", "necklace", "necktie", "young",
    ]
    static let hiddenFaceAttributes: Set<Int> = [2]

    /// PETA's 35 pedestrian attributes in the order of the Model Zoo's peta_names.json, in plain words.
    public static let petaAttributes = [
        "age under 30", "age 30-45", "age 45-60", "age over 60", "backpack", "carrying something", "casual trousers",
        "casual top", "formal trousers", "formal top", "hat", "jacket", "jeans", "leather shoes", "logo", "long hair",
        "male", "messenger bag", "scarf", "no accessories", "carrying nothing", "plaid", "plastic bag", "sandals",
        "shoes", "shorts", "short sleeves", "short skirt", "sneakers", "thin stripes", "sunglasses", "trousers",
        "T-shirt", "other top", "V-neck",
    ]

    /// face_attr_resnet_v1_18: per attribute two scores (absent, present); the Zoo takes the larger
    /// (face_attr_postprocessing.py). The probability is their softmax.
    public static func faceAttributes(_ tensor: Tensor) -> [Classification] {
        let values = tensor.floats()
        let count = min(values.count / 2, celebaAttributes.count)
        let all = (0..<count).filter { !hiddenFaceAttributes.contains($0) }.map { index in
            let present = 1 / (1 + exp(values[2 * index] - values[2 * index + 1]))
            return Classification(label: celebaAttributes[index], classIndex: index, probability: present)
        }
        return present(all)
    }

    /// person_attr_resnet_v1_18: one logit per attribute; present when >= 0 (the Zoo's person_attr
    /// visualisation), probability its sigmoid.
    public static func personAttributes(_ tensor: Tensor) -> [Classification] {
        let values = tensor.floats()
        let all = values.prefix(petaAttributes.count).enumerated().map { index, logit in
            Classification(label: petaAttributes[index], classIndex: index, probability: 1 / (1 + exp(-logit)))
        }
        return present(all)
    }

    /// The attributes at or above 0.5, most certain first.
    static func present(_ all: [Classification]) -> [Classification] {
        all.filter { $0.probability >= 0.5 }.sorted { $0.probability > $1.probability }
    }

    /// A re-identification embedding scaled to unit length (person_reid_postprocessing.py), so a dot
    /// product is the cosine similarity.
    public static func unitEmbedding(_ tensor: Tensor) -> [Float] {
        var values = tensor.floats()
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        if norm > 1e-10 { for i in values.indices { values[i] /= norm } }
        return values
    }
}
