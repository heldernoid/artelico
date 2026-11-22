"""Decode a HAILO_NMS_BY_CLASS float32 output buffer (80 COCO classes) and print the detections.
Layout: for each class, a float32 box count followed by that many (y_min, x_min, y_max, x_max, score)."""
import struct, sys

COCO = ("person bicycle car motorcycle airplane bus train truck boat traffic_light fire_hydrant stop_sign "
        "parking_meter bench bird cat dog horse sheep cow elephant bear zebra giraffe backpack umbrella handbag "
        "tie suitcase frisbee skis snowboard sports_ball kite baseball_bat baseball_glove skateboard surfboard "
        "tennis_racket bottle wine_glass cup fork knife spoon bowl banana apple sandwich orange broccoli carrot "
        "hot_dog pizza donut cake chair couch potted_plant bed dining_table toilet tv laptop mouse remote "
        "keyboard cell_phone microwave oven toaster sink refrigerator book clock vase scissors teddy_bear "
        "hair_drier toothbrush").split()

def decode(path, classes=80):
    data = open(path, "rb").read()
    offset, found = 0, []
    for c in range(classes):
        (count,) = struct.unpack_from("<f", data, offset)
        offset += 4
        for _ in range(int(count)):
            y0, x0, y1, x1, score = struct.unpack_from("<5f", data, offset)
            offset += 20
            found.append((score, c, x0, y0, x1, y1))
    return sorted(found, reverse=True)

if __name__ == "__main__":
    dets = decode(sys.argv[1])
    print(f"{len(dets)} detections")
    for score, c, x0, y0, x1, y1 in dets:
        print(f"  {COCO[c]:<14} {score:.4f}  box x {x0:.4f}-{x1:.4f}  y {y0:.4f}-{y1:.4f}")
