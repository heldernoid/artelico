// Tasks whose model looks at one face or one person at a time: a detector finds them (scrfd_10g for faces,
// yolov8s for people), each is cut out the way the model was trained, and the crops go through the model
// one after another. Both models must be loaded. Without a detector the whole picture is one crop.
// Port of StudioCore/CropTasks.swift.
import { Catalog, inputWidth, inputHeight } from "./catalog.js";
import { prepare, pixelsOf, cropSquare, cropFrame, stretchedCrop, toPicture, warpAffine } from "./prep.js";
import { detections } from "./decode.js";
import { faces } from "./faces.js";
import { alignment, unit, FaceGallery } from "./pipelines.js";
import { faceAttributes, personAttributes, tddfaLandmarks, faceMesh, loadFaceModel } from "./decode-crops.js";

export const CROP_TASKS = new Set(["face_attribute", "face_landmarks", "person_attribute", "person_re_id"]);

/** Where the five SCRFD landmarks sit in CelebA's aligned 178 x 218 pictures (means of list_landmarks_align_celeba.txt). */
const CELEBA_TEMPLATE = [[69, 111], [108, 111], [88, 135], [72, 152], [105, 152]];

export const CropTasks = {
  /** Each face or person costs one more run; more than this many (best scores first) are left out. */
  maxObjects: 10,
  /** People below this detector score are skipped (as for top-down pose). */
  personThreshold: 0.4,

  detectorName: (task) => (task === "face_attribute" || task === "face_landmarks" ? "scrfd_10g" : "yolov8s"),

  /** The faces or people in `image`, each described by the loaded model. `gallery`: re-identification's people so far. */
  async run(task, image, model, engine, gallery) {
    if (task === "face_landmarks") await loadFaceModel();
    const found = await this.find(task, image, engine);
    const pixels = found.length ? pixelsOf(image) : null, crops = [], outputs = [];
    for (const item of found) {
      const crop = this.crop(task, model, image, pixels, item);
      crops.push(crop);
      outputs.push(await engine.infer([crop.frame.rgb], model.name));
    }
    return decode(outputs, task, model, found, crops, gallery);
  },

  async find(task, image, engine) {
    const name = this.detectorName(task), detector = Catalog.model(name);
    if (task === "face_attribute" || task === "face_landmarks") {
      const frame = prepare(image, inputWidth(detector), inputHeight(detector), "letterbox");
      return faces(await engine.infer([frame.rgb], name), detector, frame).sort((a, b) => b.confidence - a.confidence).slice(0, this.maxObjects)
        .map((f) => ({ box: f.boundingBox, confidence: f.confidence, landmarks: f.landmarks }));
    }
    const frame = prepare(image, inputWidth(detector), inputHeight(detector), "letterbox");
    return detections((await engine.infer([frame.rgb], name))[0], frame, [])
      .filter((d) => d.classIndex === 0 && d.confidence >= this.personThreshold).slice(0, this.maxObjects)
      .map((d) => ({ box: d.boundingBox, confidence: d.confidence, landmarks: [] }));
  },

  /** One model input ({ frame, square }): square is the turned square when the crop is turned (face mesh). */
  crop(task, model, image, pixels, found) {
    const inW = inputWidth(model), inH = inputHeight(model), pw = pixels.width, ph = pixels.height;
    const box = { x: found.box.x * pw, y: found.box.y * ph, width: found.box.width * pw, height: found.box.height * ph };
    const midX = box.x + box.width / 2, midY = box.y + box.height / 2;
    const square = (sq) => ({ frame: cropFrame(cropSquare(pixels, sq, inW), inW, inH, pixels, { x: sq.cx - sq.size / 2, y: sq.cy - sq.size / 2, width: sq.size, height: sq.size }),
      square: sq.angle === 0 ? null : sq });
    if (task === "face_attribute") {
      // Aligned like CelebA's pictures by eyes, nose and mouth (sampled bilinearly: the faces are small and
      // a canvas's smoothing changed borderline attributes); stretched if that cannot be done.
      const t = alignment(image, found.landmarks, CELEBA_TEMPLATE.map(([x, y]) => [(x * inW) / 178, (y * inH) / 218]));
      if (!t) return { frame: stretchedCrop(pixels, box, inW, inH), square: null };
      // Output pixel -> picture: the inverse of the similarity (cos, sin, tx, ty), divided by its scale squared.
      const [c, s, tx, ty] = t, k = c * c + s * s;
      const inverse = [c / k, s / k, -(c * tx + s * ty) / k, -s / k, c / k, (s * tx - c * ty) / k];
      return { frame: cropFrame(warpAffine(pixels, inW, inH, inverse), inW, inH, pixels, box), square: null };
    }
    if (task === "face_landmarks" && model.outputs.length === 1) {
      // 3DDFA_V2's parse_roi_box_from_bbox: a square 1.58 x the box's mean side, moved down by 0.14 of it.
      const side = (box.width + box.height) / 2;
      return square({ cx: midX, cy: midY + side * 0.14, size: Math.trunc(side * 1.58), angle: 0 });
    }
    if (task === "face_landmarks") {
      // MediaPipe's face mesh: a square 1.5 x the box's longer side, turned so the eyes are level.
      const [left, right] = found.landmarks;
      const angle = left && right ? -Math.atan2((right.y - left.y) * ph, (right.x - left.x) * pw) : 0;
      return square({ cx: midX, cy: midY, size: 1.5 * Math.max(box.width, box.height), angle });
    }
    // People: the detector's box stretched to the input, as PETA's and Market-1501's crops are.
    return { frame: stretchedCrop(pixels, box, inW, inH), square: null };
  },

  /** The whole picture stretched to the input as the model's one crop (the Zoo's evaluation pictures are crops). */
  wholePicture(image, model) {
    const pixels = pixelsOf(image);
    return stretchedCrop(pixels, { x: 0, y: 0, width: pixels.width, height: pixels.height }, inputWidth(model), inputHeight(model));
  },

  async decodeWhole(tensors, task, model, frame, gallery) {
    if (task === "face_landmarks") await loadFaceModel();
    return decode([tensors], task, model, [{ box: { x: 0, y: 0, width: 1, height: 1 }, confidence: 1, landmarks: [] }], [{ frame, square: null }], gallery);
  },
};

function decode(outputs, task, model, found, crops, gallery) {
  if (task === "face_landmarks") {
    const value = [];
    found.forEach((item, i) => {
      const { frame, square } = crops[i], tensors = outputs[i];
      const picture = (p) => {
        if (!square) return frame.toSource(p.x, p.y);
        const q = toPicture(square, p.x, p.y, frame.width);
        return { x: q.x / frame.sourceWidth, y: q.y / frame.sourceHeight };
      };
      const mesh = faceMesh(tensors);
      if (mesh) { value.push({ boundingBox: item.box, confidence: mesh.score, points: mesh.points.map(picture) }); return; }
      const dense = tddfaLandmarks(tensors[0]);
      if (dense) value.push({ boundingBox: item.box, confidence: item.confidence, points: dense.points.map(picture), headPose: dense.pose });
    });
    return { kind: "faceLandmarks", value };
  }
  if (task === "person_re_id") {
    const people = found.map((item, i) => ({ boundingBox: item.box, confidence: item.confidence, attributes: [], embedding: unit(Float32Array.from(outputs[i][0].values)) }));
    ReIdentification.name(people, gallery ?? ReIdentification.gallery(model));
    return { kind: "described", value: people };
  }
  return { kind: "described", value: found.map((item, i) => ({ boundingBox: item.box, confidence: item.confidence,
    attributes: task === "face_attribute" ? faceAttributes(outputs[i][0]) : personAttributes(outputs[i][0]) })) };
}

/**
 * Re-identification: people are told apart by the cosine similarity of their appearance vectors. A person
 * not like anyone seen before becomes "Person N"; the gallery keeps a few looks per person.
 */
export const ReIdentification = {
  /** Looks kept per person (the latest), so a turn or a step into shade still matches. */
  looksPerPerson: 8,

  /**
   * An empty gallery with the similarity `model` needs to call two crops the same person. OSNet's vectors
   * come out of a ReLU (no negative numbers), so even strangers score 0.6-0.85 on bus.jpg; RepVGG spreads
   * them wider (strangers 0.2-0.6, the same person 0.6-0.99).
   */
  gallery(model) {
    const gallery = new FaceGallery();
    gallery.threshold = model.name === "osnet_x1_0" ? 0.75 : 0.6;
    return gallery;
  },

  /** The people seen so far, shared by Photos and Live (one gallery per model; Live starts a new one). */
  sessions: new Map(),
  session(model) {
    if (!this.sessions.has(model.name)) this.sessions.set(model.name, this.gallery(model));
    return this.sessions.get(model.name);
  },
  /** Numbers people from 1 again. */
  reset() { this.sessions.clear(); },

  /** Names everyone in `people` from `gallery`, adding new people to it; each name once per picture, most similar pairs first. */
  name(people, gallery) {
    const pairs = [];
    people.forEach((person, index) => {
      for (const [name, looks] of Object.entries(gallery.people)) {
        let best = -1;
        for (const look of looks) { let dot = 0; for (let i = 0; i < look.length; i++) dot += look[i] * person.embedding[i]; best = Math.max(best, dot); }
        if (best >= gallery.threshold) pairs.push({ index, name, similarity: best });
      }
    });
    const takenNames = new Set(), named = new Set();
    for (const pair of pairs.sort((a, b) => b.similarity - a.similarity)) {
      if (takenNames.has(pair.name) || named.has(pair.index)) continue;
      takenNames.add(pair.name); named.add(pair.index);
      Object.assign(people[pair.index], { name: pair.name, similarity: pair.similarity });
      gallery.people[pair.name] = [...gallery.people[pair.name].slice(-(this.looksPerPerson - 1)), Array.from(people[pair.index].embedding)];
    }
    people.forEach((person, index) => {
      if (named.has(index)) return;
      person.name = `Person ${Object.keys(gallery.people).length + 1}`;
      gallery.enroll(person.name, person.embedding);
    });
  },
};
