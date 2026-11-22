#include "ugenloader.h"

#include <string.h>

// Loader vendor requests: recipient = device, IN = 0xC0, OUT = 0x40.
enum { REQ_BUILD = 0x11, REQ_START = 0x12, REQ_SKU = 0x14, REQ_STATUS = 0x15, REQ_PROTOCOL = 0x16 };
enum { STATUS_RECEIVER_READY = 0, STATUS_RX_COUNTER = 1, STATUS_DATA_READY = 2 };
#define REQTYPE_DEVICE_IN 0xC0
#define REQTYPE_DEVICE_OUT 0x40
#define LOADER_CHUNK 65536u
#define PING_SIZE 64u
#define READY_POLLS 100
#define POLL_INTERVAL_MS 100u

static int vendor_in(const ugen_transport *t, uint8_t request, uint16_t value, void *data, uint16_t length,
                     uint16_t *got, int *transport_error) {
    uint16_t transferred = 0;
    int rc = t->control_in(t->context, REQTYPE_DEVICE_IN, request, value, 0, data, length, &transferred);
    if (got != NULL) *got = transferred;
    if (rc != 0) { *transport_error = rc; return UGEN_ERR_TRANSPORT; }
    return UGEN_OK;
}

static int bulk(const ugen_transport *t, const void *data, uint32_t length, int *transport_error) {
    int rc = t->bulk_out(t->context, UGEN_LOADER_ENDPOINT_OUT, data, length);
    if (rc != 0) { *transport_error = rc; return UGEN_ERR_TRANSPORT; }
    return UGEN_OK;
}

int ugen_loader_probe(const ugen_transport *transport, ugen_loader_info *info, int *transport_error) {
    int ignored = 0;
    if (transport_error == NULL) transport_error = &ignored;
    memset(info, 0, sizeof *info);

    uint8_t raw[4] = {0};
    uint16_t got = 0;
    int rc = vendor_in(transport, REQ_PROTOCOL, 0, raw, sizeof raw, &got, transport_error);
    if (rc != UGEN_OK) return rc;
    if (got != sizeof raw) return UGEN_ERR_PROTOCOL;
    info->protocol = (uint32_t)raw[0] | ((uint32_t)raw[1] << 8) | ((uint32_t)raw[2] << 16) | ((uint32_t)raw[3] << 24);

    rc = vendor_in(transport, REQ_SKU, 0, info->sku, 64, &got, transport_error);
    if (rc != UGEN_OK) return rc;
    return vendor_in(transport, REQ_BUILD, 0, info->build, 64, &got, transport_error);
}

int ugen_loader_upload(const ugen_transport *transport, const void *image, uint32_t image_size,
                       void (*sleep_ms)(uint32_t ms), ugen_loader_progress progress, void *progress_context,
                       int *transport_error) {
    int ignored = 0;
    if (transport_error == NULL) transport_error = &ignored;
    if (image == NULL || image_size == 0 || sleep_ms == NULL) return UGEN_ERR_ARGUMENT;

    // Refuse anything but the loader this image was built for.
    ugen_loader_info info;
    int rc = ugen_loader_probe(transport, &info, transport_error);
    if (rc != UGEN_OK) return rc;
    if (info.protocol != UGEN_LOADER_EXPECTED_PROTOCOL) return UGEN_ERR_LOADER_PROTOCOL;
    if (strcmp(info.build, UGEN_LOADER_EXPECTED_BUILD) != 0) return UGEN_ERR_LOADER_BUILD;

    // Upload start: the image size travels as wIndex:wValue.
    int trc = transport->control_out(transport->context, REQTYPE_DEVICE_OUT, REQ_START,
                                     (uint16_t)(image_size & 0xFFFF), (uint16_t)(image_size >> 16), NULL, 0);
    if (trc != 0) { *transport_error = trc; return UGEN_ERR_TRANSPORT; }

    uint8_t ready = 0;
    for (int i = 0; i < READY_POLLS && ready != 1; i++) {
        rc = vendor_in(transport, REQ_STATUS, STATUS_RECEIVER_READY, &ready, 1, NULL, transport_error);
        if (rc != UGEN_OK) return rc;
        if (ready != 1) sleep_ms(POLL_INTERVAL_MS);
    }
    if (ready != 1) return UGEN_ERR_LOADER_NOT_READY;

    // Two pings. The first counter read clears the counter; the vendor tool only warns on a mismatch.
    uint8_t ping[PING_SIZE];
    memset(ping, 0xAA, sizeof ping);
    uint8_t counter[4];
    rc = bulk(transport, ping, sizeof ping, transport_error);
    if (rc != UGEN_OK) return rc;
    rc = vendor_in(transport, REQ_STATUS, STATUS_RX_COUNTER, counter, sizeof counter, NULL, transport_error);
    if (rc != UGEN_OK) return rc;
    sleep_ms(POLL_INTERVAL_MS);
    rc = bulk(transport, ping, sizeof ping, transport_error);
    if (rc != UGEN_OK) return rc;
    rc = vendor_in(transport, REQ_STATUS, STATUS_RX_COUNTER, counter, sizeof counter, NULL, transport_error);
    if (rc != UGEN_OK) return rc;

    uint8_t data_ready = 0;
    rc = vendor_in(transport, REQ_STATUS, STATUS_DATA_READY, &data_ready, 1, NULL, transport_error);
    if (rc != UGEN_OK) return rc;
    if (data_ready != 1) return UGEN_ERR_LOADER_NOT_READY;

    const uint8_t *p = image;
    uint32_t sent = 0;
    while (sent < image_size) {
        const uint32_t remaining = image_size - sent;
        const uint32_t chunk = (remaining < LOADER_CHUNK) ? remaining : LOADER_CHUNK;
        rc = bulk(transport, p + sent, chunk, transport_error);
        if (rc != UGEN_OK) return rc;
        sent += chunk;
        if (progress != NULL) progress(progress_context, sent, image_size);
    }
    // A zero-length transfer marks the end of the image.
    return bulk(transport, ping, 0, transport_error);
}
