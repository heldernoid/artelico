// Decoders for the models that look at one face or person crop (crop-tasks.js): attributes, dense face
// landmarks (3DDFA, MediaPipe's face mesh). Port of StudioCore/PostProcess+Attributes.swift and
// PostProcess+FaceLandmarks.swift.

/** CelebA's 40 face attributes (list_attr_celeba.txt order), in plain words. */
export const CELEBA_ATTRIBUTES = [
  "stubble", "arched eyebrows", "attractive", "bags under eyes", "bald", "bangs", "big lips", "big nose",
  "black hair", "blond hair", "blurry", "brown hair", "bushy eyebrows", "chubby", "double chin", "glasses",
  "goatee", "grey hair", "heavy make-up", "high cheekbones", "male", "mouth open", "moustache", "narrow eyes",
  "no beard", "oval face", "pale skin", "pointy nose", "receding hairline", "rosy cheeks", "sideburns", "smiling",
  "straight hair", "wavy hair", "earrings", "hat", "lipstick", "necklace", "necktie", "young",
];
/** "Attractive" is a judgement, not something visible: never shown. */
const HIDDEN_FACE_ATTRIBUTES = new Set([2]);

/** PETA's 35 pedestrian attributes (the Zoo's peta_names.json order), in plain words. */
export const PETA_ATTRIBUTES = [
  "age under 30", "age 30-45", "age 45-60", "age over 60", "backpack", "carrying something", "casual trousers",
  "casual top", "formal trousers", "formal top", "hat", "jacket", "jeans", "leather shoes", "logo", "long hair",
  "male", "messenger bag", "scarf", "no accessories", "carrying nothing", "plaid", "plastic bag", "sandals",
  "shoes", "shorts", "short sleeves", "short skirt", "sneakers", "thin stripes", "sunglasses", "trousers",
  "T-shirt", "other top", "V-neck",
];

/** The attributes at or above 0.5, most certain first. */
const present = (all) => all.filter((a) => a.probability >= 0.5).sort((a, b) => b.probability - a.probability);

/** face_attr_resnet_v1_18: per attribute (absent, present) scores; probability = their softmax. */
export function faceAttributes(tensor) {
  const v = tensor.values, all = [];
  for (let i = 0; i < Math.min(v.length / 2, CELEBA_ATTRIBUTES.length); i++) {
    if (!HIDDEN_FACE_ATTRIBUTES.has(i)) all.push({ label: CELEBA_ATTRIBUTES[i], classIndex: i, probability: 1 / (1 + Math.exp(v[2 * i] - v[2 * i + 1])) });
  }
  return present(all);
}

/** person_attr_resnet_v1_18: one logit per attribute; present when >= 0 (the Zoo's visualisation), probability its sigmoid. */
export function personAttributes(tensor) {
  return present([...tensor.values.slice(0, PETA_ATTRIBUTES.length)].map((logit, i) => ({ label: PETA_ATTRIBUTES[i], classIndex: i, probability: 1 / (1 + Math.exp(-logit)) })));
}

// MARK: 3DDFA

/**
 * The 68 landmark vertices of the Basel Face Model that 3DDFA's parameters drive (data/tddfa_bfm68.bin, from
 * bfm_noneck_v3.pkl in the Model Zoo's tddfa archive): mean shape (204 = 68 x (x, y, z)), 40 shape and
 * 10 expression bases (204 x 40, 204 x 10), float32. Under the Basel Face Model's licence.
 */
let faceModel = null;
export async function loadFaceModel() {
  if (faceModel) return faceModel;
  const values = new Float32Array(await (await fetch(new URL("../../data/tddfa_bfm68.bin", import.meta.url))).arrayBuffer());
  if (values.length !== 204 * 51) throw new Error("data/tddfa_bfm68.bin has the wrong size.");
  faceModel = { mean: values.subarray(0, 204), shape: values.subarray(204, 204 * 41), expression: values.subarray(204 * 41) };
  return faceModel;
}

/** 3DDFA's 62 outputs are normalized; these undo it (3DDFA_V2's param_mean_std_62d_120x120.pkl). */
const TDDFA_MEAN = [
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
];
const TDDFA_STD = [
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
];

/**
 * tddfa_mobilenet_v1: the 68 landmarks in input pixels (120 x 120, y down) and the head pose. Parameters: a
 * 3 x 4 camera matrix (rotation with scale, offset), 40 shape and 10 expression weights; points = R (mean +
 * shape + expression) + offset, then 3DDFA's similar_transform (x - 1, y flipped). Needs loadFaceModel() first.
 */
export function tddfaLandmarks(tensor) {
  if (tensor.values.length !== 62 || !faceModel) return null;
  const p = Array.from(tensor.values, (v, i) => v * TDDFA_STD[i] + TDDFA_MEAN[i]), size = 120, points = [];
  for (let i = 0; i < 68; i++) {
    const v = [0, 1, 2].map((axis) => {
      const row = 3 * i + axis;
      let value = faceModel.mean[row];
      for (let k = 0; k < 40; k++) value += faceModel.shape[row * 40 + k] * p[12 + k];
      for (let k = 0; k < 10; k++) value += faceModel.expression[row * 10 + k] * p[52 + k];
      return value;
    });
    const x = p[0] * v[0] + p[1] * v[1] + p[2] * v[2] + p[3], y = p[4] * v[0] + p[5] * v[1] + p[6] * v[2] + p[7];
    points.push({ x: x - 1, y: size - y });
  }
  return { points, pose: headPose(p) };
}

/** Yaw, pitch and roll in degrees from 3DDFA's camera matrix (3DDFA_V2 utils/pose.py: P2sRt, matrix2angle). */
function headPose(p) {
  const unitV = (v) => { const n = Math.hypot(...v); return n > 0 ? v.map((x) => x / n) : v; };
  const r1 = unitV([p[0], p[1], p[2]]), r2 = unitV([p[4], p[5], p[6]]);
  const r3 = [r1[1] * r2[2] - r1[2] * r2[1], r1[2] * r2[0] - r1[0] * r2[2], r1[0] * r2[1] - r1[1] * r2[0]];
  let yaw, pitch, roll;
  if (r3[0] > 0.998) { yaw = Math.PI / 2; roll = 0; pitch = Math.atan2(-r1[1], -r1[2]); }
  else if (r3[0] < -0.998) { yaw = -Math.PI / 2; roll = 0; pitch = Math.atan2(r1[1], r1[2]); }
  else {
    yaw = Math.asin(r3[0]);
    pitch = Math.atan2(r3[1] / Math.cos(yaw), r3[2] / Math.cos(yaw));
    roll = Math.atan2(r2[0] / Math.cos(yaw), r1[0] / Math.cos(yaw));
  }
  const deg = 180 / Math.PI;
  return { yaw: yaw * deg, pitch: pitch * deg, roll: roll * deg };
}

/** face_landmarks_lite (MediaPipe face mesh): 468 x (x, y, z) in input pixels (192 x 192) and the face score (sigmoid applied). */
export function faceMesh(tensors) {
  const coordinates = tensors.find((t) => t.stream.features === 1404)?.values, score = tensors.find((t) => t.stream.features === 1)?.values[0];
  if (!coordinates || score === undefined) return null;
  return { points: Array.from({ length: 468 }, (_, i) => ({ x: coordinates[3 * i], y: coordinates[3 * i + 1] })), score };
}
