import CoreGraphics
import Foundation

// Decoders for dense face landmarks on one face crop (`CropTasks`): 3DDFA (68 points from a 3D face
// model) and MediaPipe's face mesh (468 points).

extension PostProcess {
    /// The 3D face model 3DDFA's parameters drive: the 68 landmark vertices of the Basel Face Model
    /// (bfm_noneck_v3.pkl from the Model Zoo's tddfa archive, 3DDFA_V2's configs/): the mean shape (204
    /// values, x y z per point), 40 shape and 10 expression bases (204 x 40, 204 x 10), float32.
    struct FaceModel3D {
        let mean: [Float], shape: [Float], expression: [Float]

        static let landmarks: FaceModel3D? = {
            guard let url = Bundle.module.url(forResource: "tddfa_bfm68", withExtension: "bin"),
                  let data = try? Data(contentsOf: url), data.count == 204 * 51 * 4 else { return nil }
            let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return FaceModel3D(mean: Array(values[0..<204]), shape: Array(values[204..<(204 * 41)]), expression: Array(values[(204 * 41)...]))
        }()
    }

    /// 3DDFA's 62 outputs are normalized parameters; these undo that (TDDFA_RESCALE_PARAMS in
    /// face_landmarks_3d_postprocessing.py, 3DDFA_V2's param_mean_std_62d_120x120.pkl).
    static let tddfaMean: [Float] = [
        3.4926363e-04, 2.5279013e-07, -6.8751979e-07, 6.0167957e01, -6.2955132e-07, 5.7572004e-04,
        -5.0853912e-05, 7.4278198e01, 5.4009172e-07, 6.5741384e-05, 3.4420125e-04, -6.6671577e01,
        -3.4660369e05, -6.7468234e04, 4.6822266e04, -1.5262047e04, 4.3505889e03, -5.4261453e04,
        -1.8328033e04, -1.5843289e03, -8.4566344e04, 3.8359607e03, -2.0811361e04, 3.8094930e04,
        -1.9967855e04, -9.2413701e03, -1.9600715e04, 1.3168090e04, -5.2591440e03, 1.8486478e03,
        -1.3030662e04, -2.4355562e03, -2.2542065e03, -1.4396562e04, -6.1763291e03, -2.5621920e04,
        2.2639447e02, -6.3261235e03, -1.0867251e04, 8.6846509e02, -5.8311479e03, 2.7051238e03,
        -3.6294177e03, 2.0439901e03, -2.4466162e03, 3.6586970e03, -7.6459897e03, -6.6744526e03,
        1.1638839e02, 7.1855972e03, -1.4294868e03, 2.6173665e03, -1.2070955e00, 6.6907924e-01,
        -1.7760828e-01, 5.6725528e-02, 3.9678156e-02, -1.3586316e-01, -9.2239931e-02, -1.7260718e-01,
        -1.5804484e-02, -1.4168486e-01,
    ]
    static let tddfaStd: [Float] = [
        1.76321526e-04, 6.73794348e-05, 4.47084894e-04, 2.65502319e01, 1.23137695e-04, 4.49302170e-05,
        7.92367064e-05, 6.98256302e00, 4.35044407e-04, 1.23148900e-04, 1.74000015e-04, 2.08030396e01,
        5.75421125e05, 2.77649062e05, 2.58336844e05, 2.55163125e05, 1.50994375e05, 1.60086109e05,
        1.11277305e05, 9.73117812e04, 1.17198453e05, 8.93173672e04, 8.84935547e04, 7.22299297e04,
        7.10802109e04, 5.00139531e04, 5.59685820e04, 4.75255039e04, 4.95150664e04, 3.81614805e04,
        4.48720586e04, 4.62732383e04, 3.81167695e04, 2.81911621e04, 3.21914375e04, 3.60061719e04,
        3.25598926e04, 2.55511172e04, 2.42675098e04, 2.75213984e04, 2.31665312e04, 2.11015762e04,
        1.94123242e04, 1.94522031e04, 1.74549844e04, 2.25376230e04, 1.61742812e04, 1.46716406e04,
        1.51156885e04, 1.38700732e04, 1.37463125e04, 1.26631338e04, 1.58708346e00, 1.50770092e00,
        5.88135779e-01, 5.88974476e-01, 2.13278517e-01, 2.63020128e-01, 2.79642940e-01, 3.80302161e-01,
        1.61628410e-01, 2.55969286e-01,
    ]

    /// tddfa_mobilenet_v1: the 68 landmarks in input pixels (120 x 120, y down) and the head pose.
    /// Parameters: a 3 x 4 camera matrix (rotation with scale, offset), 40 shape and 10 expression
    /// weights; points = R (mean + shape + expression) + offset, then 3DDFA's similar_transform (x - 1,
    /// y flipped). The pose is 3DDFA_V2's calc_pose (utils/pose.py).
    public static func tddfaLandmarks(_ tensor: Tensor) -> (points: [CGPoint], pose: (yaw: Float, pitch: Float, roll: Float))? {
        let raw = tensor.floats()
        guard raw.count == 62, let face = FaceModel3D.landmarks else { return nil }
        let p = (0..<62).map { raw[$0] * tddfaStd[$0] + tddfaMean[$0] }
        var points: [CGPoint] = []
        let size = Float(120)
        for i in 0..<68 {
            var v = [Float](repeating: 0, count: 3)
            for axis in 0..<3 {
                let row = 3 * i + axis
                var value = face.mean[row]
                for k in 0..<40 { value += face.shape[row * 40 + k] * p[12 + k] }
                for k in 0..<10 { value += face.expression[row * 10 + k] * p[52 + k] }
                v[axis] = value
            }
            let x = p[0] * v[0] + p[1] * v[1] + p[2] * v[2] + p[3]
            let y = p[4] * v[0] + p[5] * v[1] + p[6] * v[2] + p[7]
            points.append(CGPoint(x: CGFloat(x - 1), y: CGFloat(size - y)))
        }
        return (points, headPose(p))
    }

    /// Yaw, pitch and roll in degrees from 3DDFA's camera matrix (P2sRt and matrix2angle).
    static func headPose(_ p: [Float]) -> (yaw: Float, pitch: Float, roll: Float) {
        func unit(_ v: [Float]) -> [Float] {
            let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
            return n > 0 ? v.map { $0 / n } : v
        }
        let r1 = unit([p[0], p[1], p[2]]), r2 = unit([p[4], p[5], p[6]])
        let r3 = [r1[1] * r2[2] - r1[2] * r2[1], r1[2] * r2[0] - r1[0] * r2[2], r1[0] * r2[1] - r1[1] * r2[0]]
        let yaw: Float, pitch: Float, roll: Float
        if r3[0] > 0.998 {
            yaw = .pi / 2; roll = 0; pitch = atan2(-r1[1], -r1[2])
        } else if r3[0] < -0.998 {
            yaw = -.pi / 2; roll = 0; pitch = atan2(r1[1], r1[2])
        } else {
            yaw = asin(r3[0])
            pitch = atan2(r3[1] / cos(yaw), r3[2] / cos(yaw))
            roll = atan2(r2[0] / cos(yaw), r1[0] / cos(yaw))
        }
        let degrees = Float(180) / .pi
        return (yaw * degrees, pitch * degrees, roll * degrees)
    }

    /// face_landmarks_lite (MediaPipe face mesh): 468 points as x, y, z in input pixels (192 x 192), and
    /// the face score (a sigmoid on the chip; the .alls adds it).
    public static func faceMesh(_ tensors: [Tensor]) -> (points: [CGPoint], score: Float)? {
        guard let coordinates = tensors.first(where: { $0.stream.features == 1404 })?.floats(),
              let score = tensors.first(where: { $0.stream.features == 1 })?.floats().first else { return nil }
        let points = (0..<468).map { CGPoint(x: CGFloat(coordinates[3 * $0]), y: CGFloat(coordinates[3 * $0 + 1])) }
        return (points, score)
    }
}
