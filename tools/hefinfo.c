// Prints every virtual stream of a HEF as JSON, including quantization parameters, using Hailo's own
// library (the reference macOS build in vendor/ref-hailort-macos-usb). Ground truth for models.json.
// Build: see tools/build_hefinfo.sh
#include <stdio.h>
#include <string.h>

#include "hailo/hailort.h"

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s <model.hef>\n", argv[0]); return 64; }
    hailo_hef hef = NULL;
    hailo_status status = hailo_create_hef_file(&hef, argv[1]);
    if (status != HAILO_SUCCESS) { fprintf(stderr, "hailo_create_hef_file failed: %d\n", status); return 1; }

    hailo_vstream_info_t infos[64];
    size_t count = 64;
    status = hailo_hef_get_all_vstream_infos(hef, NULL, infos, &count);
    if (status != HAILO_SUCCESS) { fprintf(stderr, "get_all_vstream_infos failed: %d\n", status); return 1; }

    printf("[\n");
    for (size_t i = 0; i < count; i++) {
        const hailo_vstream_info_t *v = &infos[i];
        printf(" {\"name\": \"%s\", \"direction\": \"%s\", \"formatType\": %d, \"formatOrder\": %d, \"formatFlags\": %d, ",
               v->name, v->direction == HAILO_H2D_STREAM ? "input" : "output", v->format.type, v->format.order, v->format.flags);
        if (v->format.order == HAILO_FORMAT_ORDER_HAILO_NMS_BY_CLASS || v->format.order == HAILO_FORMAT_ORDER_HAILO_NMS ||
            v->format.order == HAILO_FORMAT_ORDER_HAILO_NMS_BY_SCORE || v->format.order == HAILO_FORMAT_ORDER_HAILO_NMS_WITH_BYTE_MASK) {
            printf("\"classes\": %u, \"maxBoxes\": %u, \"maxBoxesTotal\": %u, ", v->nms_shape.number_of_classes,
                   v->nms_shape.max_bboxes_per_class, v->nms_shape.max_bboxes_total);
        } else {
            printf("\"height\": %u, \"width\": %u, \"features\": %u, ", v->shape.height, v->shape.width, v->shape.features);
        }
        printf("\"qpZp\": %.9g, \"qpScale\": %.9g}%s\n", v->quant_info.qp_zp, v->quant_info.qp_scale, (i + 1 < count) ? "," : "");
    }
    printf("]\n");
    hailo_release_hef(hef);
    return 0;
}
