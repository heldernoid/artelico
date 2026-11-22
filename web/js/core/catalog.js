// The model catalog and label sets (port of StudioCore/ModelInfo.swift). Same models.json and
// labels.json as the apps, copied into web/data.

let models = [];
let labelFile = { imagenet: [], cityscapes: [], dota: [], kinetics400: [] };

export async function loadCatalog(base = "data") {
  const [m, l] = await Promise.all([fetch(`${base}/models.json`), fetch(`${base}/labels.json`)]);
  models = await m.json();
  labelFile = await l.json();
  return models;
}

export const Catalog = {
  get all() { return models; },
  model(name) { return models.find((m) => m.name === name); },
  /** Models for any of the catalog tasks `tasks`, the default first, then by name. */
  forTask(tasks) {
    const any = (list) => list.some((t) => tasks.includes(t));
    return models.filter((m) => any(m.tasks)).sort((a, b) => {
      const da = any(a.defaultFor), db = any(b.defaultFor);
      return da !== db ? (da ? -1 : 1) : a.name.localeCompare(b.name, undefined, { numeric: true });
    });
  },
};

export const inputWidth = (m) => m.inputs[0]?.width ?? 0;
export const inputHeight = (m) => m.inputs[0]?.height ?? 0;
export const isNMS = (stream) => stream.order === "NMS_BY_CLASS";
/** The device runs box decoding and NMS itself and returns finished detections. */
export const hasDeviceNMS = (m) => m.outputs.length === 1 && isNMS(m.outputs[0]);

const COCO = ["person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light",
  "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
  "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
  "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove", "skateboard", "surfboard",
  "tennis racket", "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
  "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch",
  "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard",
  "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase",
  "scissors", "teddy bear", "hair drier", "toothbrush"];

const COCO_PAPER = ["person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light",
  "fire hydrant", "N/A", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep",
  "cow", "elephant", "bear", "zebra", "giraffe", "N/A", "backpack", "umbrella", "N/A", "N/A",
  "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball", "kite", "baseball bat",
  "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle", "N/A", "wine glass", "cup", "fork",
  "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange", "broccoli", "carrot", "hot dog",
  "pizza", "donut", "cake", "chair", "couch", "potted plant", "bed", "N/A", "dining table", "N/A",
  "N/A", "toilet", "N/A", "tv", "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave",
  "oven", "toaster", "sink", "refrigerator", "N/A", "book", "clock", "vase", "scissors", "teddy bear",
  "hair drier", "toothbrush"];

const FOUR = ["person", "vehicle", "face", "license plate"];
const VISDRONE = ["person", "person", "bicycle", "car", "van", "truck", "tricycle", "awning-tricycle", "bus", "motor", "others"];

/** The Pascal VOC colour of class `index` (bits of the index spread over the high bits of R, G, B). */
function vocColor(index) {
  let r = 0, g = 0, b = 0;
  for (let shift = 7, c = index; shift >= 0 && c > 0; shift--, c >>= 3) { r |= (c & 1) << shift; g |= ((c >> 1) & 1) << shift; b |= ((c >> 2) & 1) << shift; }
  return [r, g, b];
}

/** Pascal VOC 2012 (deeplab_v3_mobilenet_v2 and _wo_dilation; cfg/base/pascal.yaml), with the dataset's colour map. */
const PASCAL_VOC = {
  labels: ["background", "aeroplane", "bicycle", "bird", "boat", "bottle", "bus", "car", "cat", "chair", "cow",
    "dining table", "dog", "horse", "motorbike", "person", "potted plant", "sheep", "sofa", "train", "tv monitor"],
  colors: Array.from({ length: 21 }, (_, i) => vocColor(i)), background: 0,
};
/** Oxford-IIIT Pet trimaps as in TensorFlow's tutorial (unet_mobilenet_v2; labels_offset 1 turns 1, 2, 3 into 0, 1, 2). */
const OXFORD_PET = { labels: ["pet", "background", "pet outline"], colors: [[255, 140, 0], [0, 0, 0], [255, 230, 80]], background: 1 };

const padded = (labels, count) => labels.length >= count ? labels : [...labels, ...Array.from({ length: count - labels.length }, (_, i) => `class ${labels.length + i}`)];

export const Labels = {
  coco: COCO,
  get imagenet() { return labelFile.imagenet; },
  get cityscapes() { return labelFile.cityscapes.map((c) => c.name); },
  get cityscapesColors() { return labelFile.cityscapes.map((c) => c.color); },
  get dota() { return labelFile.dota; },
  get kinetics400() { return labelFile.kinetics400; },
  /** The class set of a segmentation model, from the dataset its Model Zoo config names (SegmentationLabels.swift). */
  segmentation(model) {
    if (model.name.startsWith("deeplab")) return PASCAL_VOC;
    if (model.name.startsWith("unet")) return OXFORD_PET;
    return { labels: this.cityscapes, colors: this.cityscapesColors, background: null };   // fcn8, segformer, stdc1
  },
  /** Labels for a detection model; unknown sets fall back to "class N". */
  detection(model) {
    const count = model.outputs[0]?.classes ?? 0;
    if (model.name.includes("visdrone")) return padded(VISDRONE, count);
    if (model.name.includes("4_classes")) return padded(FOUR, count);
    if (count === COCO.length) return COCO;
    if (count === COCO_PAPER.length) return COCO_PAPER;
    return padded([], count);
  },
};
