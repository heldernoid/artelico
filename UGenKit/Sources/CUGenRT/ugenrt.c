#include "ugenrt.h"

#include <string.h>

// ---- Wire constants (hailort v5.3.0) ----------------------------------------------------------

#define RPC_MAGIC 0x8A554432u
#define RPC_HEADER_SIZE 20u
#define RPC_MAX_BODY 2048u
#define RPC_MESSAGE_SIZE (RPC_HEADER_SIZE + RPC_MAX_BODY)  // every message is sent at this fixed size
#define USB_MAX_CHUNK (1024u * 1024u)                      // USB_MAX_BUFFER_SIZE in usb_session.hpp
#define HAILO_UNINITIALIZED 1u
#define BUFFER_TYPE_VIEW 1u
#define SCHEDULING_ROUND_ROBIN 1u

// Control requests go to the interface recipient: vendor | interface.
#define REQTYPE_OUT 0x41
#define REQTYPE_IN 0xC1
enum { USB_OPCODE_CONNECT = 1, USB_OPCODE_CLOSE = 2 };

// HailoRpcActionID, in declaration order.
enum {
    ACTION_VDEVICE_CREATE = 0,
    ACTION_VDEVICE_DESTROY = 1,
    ACTION_VDEVICE_CREATE_INFER_MODEL = 2,
    ACTION_INFER_MODEL_DESTROY = 3,
    ACTION_INFER_MODEL_CREATE_CONFIGURED = 4,
    ACTION_CONFIGURED_DESTROY = 5,
    ACTION_CONFIGURED_RUN_ASYNC = 18,
    ACTION_DEVICE_CREATE = 20,
    ACTION_DEVICE_DESTROY = 21,
    ACTION_DEVICE_IDENTIFY = 22,
    ACTION_DEVICE_GET_CHIP_TEMPERATURE = 24,
    ACTION_DEVICE_POWER_MEASUREMENT = 25,
    ACTION_DEVICE_QUERY_HEALTH_STATS = 30,
    ACTION_DEVICE_QUERY_PERFORMANCE_STATS = 31,
    ACTION_DEVICE_GET_CURRENT_LIMIT = 37,
    ACTION_NOTIFICATION = 38,
    ACTION_SYSTEM_RESET = 39,
};

// ---- Little-endian helpers --------------------------------------------------------------------

static void put_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

static uint32_t get_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// ---- Minimal protobuf writer ------------------------------------------------------------------

typedef struct {
    uint8_t *data;
    uint32_t capacity;
    uint32_t length;
    int overflow;
} pb_writer;

static void pb_byte(pb_writer *w, uint8_t b) {
    if (w->length < w->capacity) w->data[w->length++] = b; else w->overflow = 1;
}

static void pb_varint(pb_writer *w, uint64_t v) {
    while (v >= 0x80) { pb_byte(w, (uint8_t)(v | 0x80)); v >>= 7; }
    pb_byte(w, (uint8_t)v);
}

static void pb_tag(pb_writer *w, uint32_t field, uint32_t wire_type) { pb_varint(w, ((uint64_t)field << 3) | wire_type); }

// proto3 omits zero-valued scalars; do the same so the bytes match the reference encoder.
static void pb_uint(pb_writer *w, uint32_t field, uint64_t v) {
    if (v == 0) return;
    pb_tag(w, field, 0);
    pb_varint(w, v);
}

static void pb_float(pb_writer *w, uint32_t field, float v) {
    uint32_t bits;
    memcpy(&bits, &v, sizeof bits);
    if (bits == 0) return;
    pb_tag(w, field, 5);
    uint8_t raw[4];
    put_u32(raw, bits);
    for (int i = 0; i < 4; i++) pb_byte(w, raw[i]);
}

static void pb_bytes(pb_writer *w, uint32_t field, const void *data, uint32_t length) {
    pb_tag(w, field, 2);
    pb_varint(w, length);
    for (uint32_t i = 0; i < length; i++) pb_byte(w, ((const uint8_t *)data)[i]);
}

static void pb_string(pb_writer *w, uint32_t field, const char *s) {
    if (s == NULL || s[0] == 0) return;
    pb_bytes(w, field, s, (uint32_t)strlen(s));
}

// HailoObjectHandle { uint32 id = 1; } as a sub-message in `field`. Always written, even for id 0.
static void pb_handle(pb_writer *w, uint32_t field, uint32_t id) {
    uint8_t tmp[8];
    pb_writer inner = {tmp, sizeof tmp, 0, 0};
    pb_uint(&inner, 1, id);
    pb_bytes(w, field, tmp, inner.length);
}

// ---- Minimal protobuf reader ------------------------------------------------------------------

typedef struct {
    const uint8_t *data;
    uint32_t length;
    uint32_t pos;
} pb_reader;

typedef struct {
    uint32_t number;
    uint32_t wire_type;
    uint64_t value;        // varint, fixed32 or fixed64
    const uint8_t *bytes;  // length-delimited payload
    uint32_t length;
} pb_field;

static int pb_read_varint(pb_reader *r, uint64_t *out) {
    uint64_t v = 0;
    for (int shift = 0; shift < 64; shift += 7) {
        if (r->pos >= r->length) return 0;
        uint8_t b = r->data[r->pos++];
        v |= (uint64_t)(b & 0x7F) << shift;
        if (!(b & 0x80)) { *out = v; return 1; }
    }
    return 0;
}

// Returns 1 and fills `f` for the next field, 0 at end of input or on malformed data.
static int pb_next(pb_reader *r, pb_field *f) {
    uint64_t tag;
    if (r->pos >= r->length || !pb_read_varint(r, &tag)) return 0;
    f->number = (uint32_t)(tag >> 3);
    f->wire_type = (uint32_t)(tag & 7);
    f->value = 0; f->bytes = NULL; f->length = 0;
    switch (f->wire_type) {
    case 0:
        return pb_read_varint(r, &f->value);
    case 1:
        if (r->length - r->pos < 8) return 0;
        memcpy(&f->value, r->data + r->pos, 8);
        r->pos += 8;
        return 1;
    case 2: {
        uint64_t n;
        if (!pb_read_varint(r, &n) || n > r->length - r->pos) return 0;
        f->bytes = r->data + r->pos;
        f->length = (uint32_t)n;
        r->pos += (uint32_t)n;
        return 1;
    }
    case 5:
        if (r->length - r->pos < 4) return 0;
        f->value = get_u32(r->data + r->pos);
        r->pos += 4;
        return 1;
    default:
        return 0;
    }
}

static float bits_to_float(uint64_t bits) {
    uint32_t b = (uint32_t)bits;
    float v;
    memcpy(&v, &b, sizeof v);
    return v;
}

// Reads the id out of a HailoObjectHandle sub-message stored in `field` of `body`.
static uint32_t read_handle(const uint8_t *body, uint32_t length, uint32_t field) {
    pb_reader r = {body, length, 0};
    pb_field f;
    while (pb_next(&r, &f)) {
        if (f.number == field && f.wire_type == 2) {
            pb_reader inner = {f.bytes, f.length, 0};
            pb_field g;
            while (pb_next(&inner, &g)) {
                if (g.number == 1 && g.wire_type == 0) return (uint32_t)g.value;
            }
            return 0;  // present but empty means id 0
        }
    }
    return 0;  // absent also decodes as the default
}

static void copy_string(char *dst, size_t capacity, const uint8_t *src, uint32_t length) {
    size_t n = (length < capacity - 1) ? length : capacity - 1;
    memcpy(dst, src, n);
    dst[n] = 0;
}

// serial_number / part_number arrive as repeated uint32, one character per element (packed or not).
static void append_char(char *dst, size_t capacity, uint64_t c) {
    size_t n = strlen(dst);
    if (c != 0 && n + 1 < capacity) { dst[n] = (char)c; dst[n + 1] = 0; }
}

static void read_char_array(char *dst, size_t capacity, const pb_field *f) {
    if (f->wire_type == 0) { append_char(dst, capacity, f->value); return; }
    if (f->wire_type != 2) return;
    pb_reader r = {f->bytes, f->length, 0};
    uint64_t c;
    while (r.pos < r.length && pb_read_varint(&r, &c)) append_char(dst, capacity, c);
}

// ---- Transport helpers ------------------------------------------------------------------------

static int fail_transport(ugen_session *s, int error) {
    s->last_transport_error = error;
    return UGEN_ERR_TRANSPORT;
}

static int write_all(ugen_session *s, const void *data, uint32_t length) {
    const uint8_t *p = data;
    while (length > 0) {
        uint32_t chunk = (length < USB_MAX_CHUNK) ? length : USB_MAX_CHUNK;
        int rc = s->transport.bulk_out(s->transport.context, s->endpoint_out, p, chunk);
        if (rc != 0) return fail_transport(s, rc);
        p += chunk;
        length -= chunk;
    }
    return UGEN_OK;
}

static int read_exact(ugen_session *s, void *data, uint32_t length) {
    uint8_t *p = data;
    while (length > 0) {
        uint32_t chunk = (length < USB_MAX_CHUNK) ? length : USB_MAX_CHUNK;
        uint32_t got = 0;
        int rc = s->transport.bulk_in(s->transport.context, s->endpoint_in, p, chunk, &got);
        if (rc != 0) return fail_transport(s, rc);
        if (got == 0 || got > chunk) return UGEN_ERR_PROTOCOL;
        p += got;
        length -= got;
    }
    return UGEN_OK;
}

// Sends one request and its extra write buffers. Returns the message id used.
static int rpc_send(ugen_session *s, uint32_t action, const uint8_t *body, uint32_t body_length,
                    const ugen_const_buffer *writes, uint32_t write_count, uint32_t *message_id_out) {
    if (!s->connected) return UGEN_ERR_ARGUMENT;
    if (body_length > RPC_MAX_BODY) return UGEN_ERR_TOO_LARGE;

    uint8_t message[RPC_MESSAGE_SIZE];
    memset(message, 0, sizeof message);
    const uint32_t message_id = s->next_message_id++;
    put_u32(message + 0, RPC_MAGIC);
    put_u32(message + 4, body_length);
    put_u32(message + 8, message_id);
    put_u32(message + 12, action);
    put_u32(message + 16, HAILO_UNINITIALIZED);
    if (body_length > 0) memcpy(message + RPC_HEADER_SIZE, body, body_length);

    int rc = write_all(s, message, sizeof message);
    if (rc != UGEN_OK) return rc;
    for (uint32_t i = 0; i < write_count; i++) {
        rc = write_all(s, writes[i].data, writes[i].size);
        if (rc != UGEN_OK) return rc;
    }
    if (message_id_out != NULL) *message_id_out = message_id;
    return UGEN_OK;
}

// Waits for the reply to `message_id` and its read buffers. Notifications are skipped. Replies arrive
// in request order, so any other message id means the stream is out of step.
static int rpc_receive(ugen_session *s, uint32_t message_id, const ugen_buffer *reads, uint32_t read_count,
                       uint8_t *reply_body, uint32_t *reply_length) {
    uint8_t message[RPC_MESSAGE_SIZE];
    for (;;) {
        uint32_t got = 0;
        int trc = s->transport.bulk_in(s->transport.context, s->endpoint_in, message, sizeof message, &got);
        if (trc != 0) return fail_transport(s, trc);
        if (got < RPC_HEADER_SIZE || get_u32(message) != RPC_MAGIC) return UGEN_ERR_PROTOCOL;
        const uint32_t size = get_u32(message + 4);
        if (size > RPC_MAX_BODY || got < RPC_HEADER_SIZE + size) return UGEN_ERR_PROTOCOL;
        if (get_u32(message + 12) == ACTION_NOTIFICATION) continue;
        if (get_u32(message + 8) != message_id) return UGEN_ERR_PROTOCOL;

        const uint32_t status = get_u32(message + 16);
        if (status != 0) return (int)status;
        // Extra buffers follow only a successful reply.
        for (uint32_t i = 0; i < read_count; i++) {
            int rc = read_exact(s, reads[i].data, reads[i].size);
            if (rc != UGEN_OK) return rc;
        }
        if (reply_body != NULL) memcpy(reply_body, message + RPC_HEADER_SIZE, size);
        if (reply_length != NULL) *reply_length = size;
        return UGEN_OK;
    }
}

static int rpc_call(ugen_session *s, uint32_t action, const uint8_t *body, uint32_t body_length,
                    const ugen_const_buffer *writes, uint32_t write_count,
                    const ugen_buffer *reads, uint32_t read_count,
                    uint8_t *reply_body, uint32_t *reply_length) {
    uint32_t message_id = 0;
    int rc = rpc_send(s, action, body, body_length, writes, write_count, &message_id);
    if (rc != UGEN_OK) return rc;
    return rpc_receive(s, message_id, reads, read_count, reply_body, reply_length);
}

int ugen_session_write(ugen_session *session, const void *data, uint32_t length) {
    if (session == NULL || !session->connected) return UGEN_ERR_ARGUMENT;
    return write_all(session, data, length);
}

int ugen_session_read(ugen_session *session, void *data, uint32_t length) {
    if (session == NULL || !session->connected) return UGEN_ERR_ARGUMENT;
    return read_exact(session, data, length);
}

// ---- Session ----------------------------------------------------------------------------------

static int send_usb_opcode(const ugen_transport *t, uint8_t opcode, const uint8_t *request, uint16_t request_size,
                           uint32_t *status, int *transport_error) {
    int rc = t->control_out(t->context, REQTYPE_OUT, opcode, 0, 0, request, request_size);
    if (rc != 0) { *transport_error = rc; return UGEN_ERR_TRANSPORT; }
    uint8_t response[4] = {0};
    uint16_t got = 0;
    rc = t->control_in(t->context, REQTYPE_IN, opcode, 0, 0, response, sizeof response, &got);
    if (rc != 0) { *transport_error = rc; return UGEN_ERR_TRANSPORT; }
    if (got != sizeof response) return UGEN_ERR_PROTOCOL;
    *status = get_u32(response);
    return UGEN_OK;
}

static int send_connect(ugen_session *session, uint32_t *status) {
    // UsbConnectRequest (packed): u8 interface, u32 port. The reply is read with the same bRequest.
    uint8_t request[5];
    request[0] = session->interface_number;
    put_u32(request + 1, session->port);
    return send_usb_opcode(&session->transport, USB_OPCODE_CONNECT, request, sizeof request, status,
                           &session->last_transport_error);
}

static int send_close(ugen_session *session, uint32_t *status) {
    // UsbCloseRequest (packed): u32 port, u8 interface.
    uint8_t request[5];
    put_u32(request, session->port);
    request[4] = session->interface_number;
    return send_usb_opcode(&session->transport, USB_OPCODE_CLOSE, request, sizeof request, status,
                           &session->last_transport_error);
}

int ugen_session_open(ugen_session *session, const ugen_transport *transport, uint8_t interface_number) {
    return ugen_session_open_port(session, transport, interface_number, UGEN_SERVER_PORT);
}

int ugen_session_open_port(ugen_session *session, const ugen_transport *transport, uint8_t interface_number, uint32_t port) {
    if (session == NULL || transport == NULL || interface_number > 4) return UGEN_ERR_ARGUMENT;
    memset(session, 0, sizeof *session);
    session->port = port;
    session->transport = *transport;
    session->interface_number = interface_number;
    session->endpoint_out = (uint8_t)(0x01 + interface_number);
    session->endpoint_in = (uint8_t)(0x81 + interface_number);

    // Always close first: if an earlier client died without closing, the device still holds its
    // session on this interface and the first transfer of a new one fails. The status of this close
    // is ignored because there is usually nothing to close.
    uint32_t status = 0;
    int rc = send_close(session, &status);
    if (rc != UGEN_OK) return rc;
    rc = send_connect(session, &status);
    if (rc != UGEN_OK) return rc;
    if (status != 0) return (int)status;

    session->connected = 1;
    return UGEN_OK;
}

int ugen_session_close(ugen_session *session) {
    if (session == NULL || !session->connected) return UGEN_OK;
    session->connected = 0;
    uint32_t status = 0;
    int rc = send_close(session, &status);
    return (rc != UGEN_OK) ? rc : (int)status;
}

// ---- Calls ------------------------------------------------------------------------------------

// Sends a request whose body is a single HailoObjectHandle in field 1 and ignores the reply body.
static int call_with_handle(ugen_session *s, uint32_t action, uint32_t handle) {
    uint8_t body[16];
    pb_writer w = {body, sizeof body, 0, 0};
    pb_handle(&w, 1, handle);
    return rpc_call(s, action, body, w.length, NULL, 0, NULL, 0, NULL, NULL);
}

int ugen_device_create(ugen_session *session, uint32_t *device_handle) {
    uint8_t reply[RPC_MAX_BODY];
    uint32_t length = 0;
    int rc = rpc_call(session, ACTION_DEVICE_CREATE, NULL, 0, NULL, 0, NULL, 0, reply, &length);
    if (rc != UGEN_OK) return rc;
    *device_handle = read_handle(reply, length, 1);
    return UGEN_OK;
}

int ugen_device_destroy(ugen_session *session, uint32_t device_handle) {
    return call_with_handle(session, ACTION_DEVICE_DESTROY, device_handle);
}

int ugen_device_identify(ugen_session *session, uint32_t device_handle, ugen_identity *identity) {
    uint8_t body[16];
    pb_writer w = {body, sizeof body, 0, 0};
    pb_handle(&w, 1, device_handle);

    uint8_t reply[RPC_MAX_BODY];
    uint32_t length = 0;
    int rc = rpc_call(session, ACTION_DEVICE_IDENTIFY, body, w.length, NULL, 0, NULL, 0, reply, &length);
    if (rc != UGEN_OK) return rc;

    memset(identity, 0, sizeof *identity);
    pb_reader outer = {reply, length, 0};
    pb_field f;
    while (pb_next(&outer, &f)) {
        if (f.number != 1 || f.wire_type != 2) continue;  // DeviceIdentityProto identity = 1
        pb_reader r = {f.bytes, f.length, 0};
        pb_field g;
        while (pb_next(&r, &g)) {
            switch (g.number) {
            case 1: identity->protocol_version = (uint32_t)g.value; break;
            case 2: {
                pb_reader v = {g.bytes, g.length, 0};
                pb_field h;
                while (g.wire_type == 2 && pb_next(&v, &h)) {
                    if (h.number == 1) identity->fw_major = (uint32_t)h.value;
                    if (h.number == 2) identity->fw_minor = (uint32_t)h.value;
                    if (h.number == 3) identity->fw_revision = (uint32_t)h.value;
                }
                break;
            }
            case 3: identity->logger_version = (uint32_t)g.value; break;
            case 4: if (g.wire_type == 2) copy_string(identity->board_name, sizeof identity->board_name, g.bytes, g.length); break;
            case 5: identity->is_release = (uint8_t)(g.value != 0); break;
            case 7: identity->device_architecture = (uint32_t)g.value; break;
            case 8: read_char_array(identity->serial_number, sizeof identity->serial_number, &g); break;
            case 9: read_char_array(identity->part_number, sizeof identity->part_number, &g); break;
            case 10: if (g.wire_type == 2) copy_string(identity->product_name, sizeof identity->product_name, g.bytes, g.length); break;
            default: break;
            }
        }
    }
    return UGEN_OK;
}

int ugen_device_chip_temperature(ugen_session *session, uint32_t device_handle, float *ts0, float *ts1) {
    uint8_t body[16];
    pb_writer w = {body, sizeof body, 0, 0};
    pb_handle(&w, 1, device_handle);

    uint8_t reply[RPC_MAX_BODY];
    uint32_t length = 0;
    int rc = rpc_call(session, ACTION_DEVICE_GET_CHIP_TEMPERATURE, body, w.length, NULL, 0, NULL, 0, reply, &length);
    if (rc != UGEN_OK) return rc;

    *ts0 = 0; *ts1 = 0;
    pb_reader r = {reply, length, 0};
    pb_field f;
    while (pb_next(&r, &f)) {
        if (f.number == 1 && f.wire_type == 5) *ts0 = bits_to_float(f.value);
        if (f.number == 2 && f.wire_type == 5) *ts1 = bits_to_float(f.value);
    }
    return UGEN_OK;
}

int ugen_vdevice_create(ugen_session *session, uint32_t *vdevice_handle) {
    // VDevice_Create_Request { VDeviceParamsProto params = 1 { scheduling_algorithm = 1; group_id = 2 } }
    // Defaults of hailo_vdevice_params_t: round-robin scheduler, group id "UNIQUE".
    uint8_t params[32];
    pb_writer p = {params, sizeof params, 0, 0};
    pb_uint(&p, 1, SCHEDULING_ROUND_ROBIN);
    pb_string(&p, 2, "UNIQUE");

    uint8_t body[64];
    pb_writer w = {body, sizeof body, 0, 0};
    pb_bytes(&w, 1, params, p.length);

    uint8_t reply[RPC_MAX_BODY];
    uint32_t length = 0;
    int rc = rpc_call(session, ACTION_VDEVICE_CREATE, body, w.length, NULL, 0, NULL, 0, reply, &length);
    if (rc != UGEN_OK) return rc;
    *vdevice_handle = read_handle(reply, length, 1);
    return UGEN_OK;
}

int ugen_vdevice_destroy(ugen_session *session, uint32_t vdevice_handle) {
    return call_with_handle(session, ACTION_VDEVICE_DESTROY, vdevice_handle);
}

int ugen_infer_model_create(ugen_session *session, uint32_t vdevice_handle, const void *hef, uint32_t hef_size,
                            uint32_t *infer_model_handle) {
    if (hef == NULL || hef_size == 0) return UGEN_ERR_ARGUMENT;
    // VDevice_CreateInferModel_Request { vdevice_handle = 1; hef_size = 2; name = 3 }, then the HEF bytes.
    uint8_t body[32];
    pb_writer w = {body, sizeof body, 0, 0};
    pb_handle(&w, 1, vdevice_handle);
    pb_uint(&w, 2, hef_size);

    const ugen_const_buffer writes[1] = {{hef, hef_size}};
    uint8_t reply[RPC_MAX_BODY];
    uint32_t length = 0;
    int rc = rpc_call(session, ACTION_VDEVICE_CREATE_INFER_MODEL, body, w.length, writes, 1, NULL, 0, reply, &length);
    if (rc != UGEN_OK) return rc;
    *infer_model_handle = read_handle(reply, length, 1);
    return UGEN_OK;
}

int ugen_infer_model_destroy(ugen_session *session, uint32_t infer_model_handle) {
    return call_with_handle(session, ACTION_INFER_MODEL_DESTROY, infer_model_handle);
}

static void write_stream_params(pb_writer *w, uint32_t field, const ugen_stream_params *p) {
    uint8_t tmp[320];
    pb_writer s = {tmp, sizeof tmp, 0, 0};
    pb_string(&s, 1, p->name);
    pb_uint(&s, 2, p->format_order);
    pb_uint(&s, 3, p->format_type);
    pb_float(&s, 4, p->nms_score_threshold);
    pb_float(&s, 5, p->nms_iou_threshold);
    pb_uint(&s, 6, p->nms_max_proposals_per_class);
    pb_uint(&s, 7, p->nms_max_accumulated_mask_size);
    pb_uint(&s, 8, p->nms_max_proposals_total);
    if (s.overflow) { w->overflow = 1; return; }
    pb_bytes(w, field, tmp, s.length);
}

int ugen_configure(ugen_session *session, uint32_t infer_model_handle, uint32_t vdevice_handle,
                   const ugen_stream_params *inputs, uint32_t input_count,
                   const ugen_stream_params *outputs, uint32_t output_count,
                   uint32_t *configured_handle, uint32_t *async_queue_size) {
    // batch_size, power_mode, latency_flag and enable_kv_cache stay at their zero defaults.
    uint8_t body[RPC_MAX_BODY];
    pb_writer w = {body, sizeof body, 0, 0};
    pb_handle(&w, 1, infer_model_handle);
    pb_handle(&w, 2, vdevice_handle);
    for (uint32_t i = 0; i < input_count; i++) write_stream_params(&w, 3, &inputs[i]);
    for (uint32_t i = 0; i < output_count; i++) write_stream_params(&w, 4, &outputs[i]);
    if (w.overflow) return UGEN_ERR_TOO_LARGE;

    uint8_t reply[RPC_MAX_BODY];
    uint32_t length = 0;
    int rc = rpc_call(session, ACTION_INFER_MODEL_CREATE_CONFIGURED, body, w.length, NULL, 0, NULL, 0, reply, &length);
    if (rc != UGEN_OK) return rc;

    *configured_handle = read_handle(reply, length, 1);
    if (async_queue_size != NULL) {
        *async_queue_size = 0;
        pb_reader r = {reply, length, 0};
        pb_field f;
        while (pb_next(&r, &f)) {
            if (f.number == 2 && f.wire_type == 0) *async_queue_size = (uint32_t)f.value;
        }
    }
    return UGEN_OK;
}

int ugen_configured_destroy(ugen_session *session, uint32_t configured_handle) {
    return call_with_handle(session, ACTION_CONFIGURED_DESTROY, configured_handle);
}

static void write_buffer_info(pb_writer *w, uint32_t size) {
    uint8_t tmp[16];
    pb_writer b = {tmp, sizeof tmp, 0, 0};
    pb_uint(&b, 1, size);
    pb_uint(&b, 2, BUFFER_TYPE_VIEW);
    pb_bytes(w, 3, tmp, b.length);
}

static int build_infer_request(uint8_t *body, uint32_t capacity, uint32_t configured_handle, uint32_t infer_model_handle,
                               const ugen_const_buffer *inputs, uint32_t input_count,
                               const uint32_t *output_sizes, uint32_t output_count, uint32_t *length) {
    // ConfiguredInferModel_AsyncInfer_Request { configured = 1; infer_model = 2; repeated BufferInfo = 3 }
    // The buffer infos list inputs first, then outputs. Input frames follow the request; output frames
    // follow the reply.
    pb_writer w = {body, capacity, 0, 0};
    pb_handle(&w, 1, configured_handle);
    pb_handle(&w, 2, infer_model_handle);
    for (uint32_t i = 0; i < input_count; i++) write_buffer_info(&w, inputs[i].size);
    for (uint32_t i = 0; i < output_count; i++) write_buffer_info(&w, output_sizes[i]);
    if (w.overflow) return UGEN_ERR_TOO_LARGE;
    *length = w.length;
    return UGEN_OK;
}

#define MAX_OUTPUTS 64

int ugen_infer_submit(ugen_session *session, uint32_t configured_handle, uint32_t infer_model_handle,
                      const ugen_const_buffer *inputs, uint32_t input_count,
                      const uint32_t *output_sizes, uint32_t output_count, uint32_t *message_id) {
    uint8_t body[RPC_MAX_BODY];
    uint32_t length = 0;
    int rc = build_infer_request(body, sizeof body, configured_handle, infer_model_handle, inputs, input_count,
                                 output_sizes, output_count, &length);
    if (rc != UGEN_OK) return rc;
    return rpc_send(session, ACTION_CONFIGURED_RUN_ASYNC, body, length, inputs, input_count, message_id);
}

int ugen_infer_collect(ugen_session *session, uint32_t message_id, const ugen_buffer *outputs, uint32_t output_count) {
    return rpc_receive(session, message_id, outputs, output_count, NULL, NULL);
}

int ugen_infer(ugen_session *session, uint32_t configured_handle, uint32_t infer_model_handle,
               const ugen_const_buffer *inputs, uint32_t input_count,
               const ugen_buffer *outputs, uint32_t output_count) {
    if (output_count > MAX_OUTPUTS) return UGEN_ERR_ARGUMENT;
    uint32_t sizes[MAX_OUTPUTS];
    for (uint32_t i = 0; i < output_count; i++) sizes[i] = outputs[i].size;
    uint32_t message_id = 0;
    int rc = ugen_infer_submit(session, configured_handle, infer_model_handle, inputs, input_count, sizes, output_count, &message_id);
    if (rc != UGEN_OK) return rc;
    return ugen_infer_collect(session, message_id, outputs, output_count);
}

int ugen_system_reset(ugen_session *session) {
    int rc = rpc_send(session, ACTION_SYSTEM_RESET, NULL, 0, NULL, 0, NULL);
    session->connected = 0;  // the device is going away; there is nothing to close
    return rc;
}

int ugen_device_current_limit(ugen_session *session, uint32_t device_handle, uint32_t *milliamps) {
    uint8_t body[16];
    pb_writer w = {body, sizeof body, 0, 0};
    pb_handle(&w, 1, device_handle);
    uint8_t reply[RPC_MAX_BODY];
    uint32_t length = 0;
    int rc = rpc_call(session, ACTION_DEVICE_GET_CURRENT_LIMIT, body, w.length, NULL, 0, NULL, 0, reply, &length);
    if (rc != UGEN_OK) return rc;
    *milliamps = 0;
    pb_reader r = {reply, length, 0};
    pb_field f;
    while (pb_next(&r, &f)) {
        if (f.number == 1 && f.wire_type == 0) *milliamps = (uint32_t)f.value;
    }
    return UGEN_OK;
}

// ---- Health, load and power (hailort's query_health_stats / query_performance_stats / power_measurement) ----

// int32 fields are written as 64-bit varints; -1 ("not available") arrives as 2^64 - 1.
static int32_t varint_to_i32(uint64_t v) { return (int32_t)(uint32_t)v; }

int ugen_device_health(ugen_session *session, uint32_t device_handle, ugen_health *health) {
    uint8_t body[16];
    pb_writer w = {body, sizeof body, 0, 0};
    pb_handle(&w, 1, device_handle);
    uint8_t reply[RPC_MAX_BODY];
    uint32_t length = 0;
    int rc = rpc_call(session, ACTION_DEVICE_QUERY_HEALTH_STATS, body, w.length, NULL, 0, NULL, 0, reply, &length);
    if (rc != UGEN_OK) return rc;
    // Device_QueryHealthStats_Reply { float on_die_temperature = 1; int32 on_die_voltage = 2; int32 bist_failure_mask = 3 }
    health->on_die_temperature = 0; health->on_die_voltage = 0; health->bist_failure_mask = 0;
    pb_reader r = {reply, length, 0};
    pb_field f;
    while (pb_next(&r, &f)) {
        if (f.number == 1 && f.wire_type == 5) health->on_die_temperature = bits_to_float(f.value);
        if (f.number == 2 && f.wire_type == 0) health->on_die_voltage = varint_to_i32(f.value);
        if (f.number == 3 && f.wire_type == 0) health->bist_failure_mask = varint_to_i32(f.value);
    }
    return UGEN_OK;
}

int ugen_device_performance(ugen_session *session, uint32_t device_handle, uint32_t sampling_period_ms,
                            ugen_performance *performance) {
    uint8_t body[24];
    pb_writer w = {body, sizeof body, 0, 0};
    pb_handle(&w, 1, device_handle);
    pb_uint(&w, 2, sampling_period_ms);
    uint8_t reply[RPC_MAX_BODY];
    uint32_t length = 0;
    int rc = rpc_call(session, ACTION_DEVICE_QUERY_PERFORMANCE_STATS, body, w.length, NULL, 0, NULL, 0, reply, &length);
    if (rc != UGEN_OK) return rc;
    // Device_QueryPerformanceStats_Reply { float cpu_utilization = 1; int64 ram_size_total = 2; int64 ram_size_used = 3;
    //   float nnc_utilization = 4; int32 ddr_noc_total_transactions = 5; int32 dsp_utilization = 6 }
    memset(performance, 0, sizeof *performance);
    pb_reader r = {reply, length, 0};
    pb_field f;
    while (pb_next(&r, &f)) {
        switch (f.number) {
        case 1: if (f.wire_type == 5) performance->cpu_utilization = bits_to_float(f.value); break;
        case 2: if (f.wire_type == 0) performance->ram_size_total = (int64_t)f.value; break;
        case 3: if (f.wire_type == 0) performance->ram_size_used = (int64_t)f.value; break;
        case 4: if (f.wire_type == 5) performance->nnc_utilization = bits_to_float(f.value); break;
        case 5: if (f.wire_type == 0) performance->ddr_noc_total_transactions = varint_to_i32(f.value); break;
        case 6: if (f.wire_type == 0) performance->dsp_utilization = varint_to_i32(f.value); break;
        default: break;
        }
    }
    return UGEN_OK;
}

int ugen_device_power(ugen_session *session, uint32_t device_handle, uint32_t measurement_type, float *value) {
    // Device_PowerMeasurement_Request { handle = 1; hailo_dvm_options = 2 (AUTO = INT_MAX); hailo_power_measurement_type = 3 }
    uint8_t body[32];
    pb_writer w = {body, sizeof body, 0, 0};
    pb_handle(&w, 1, device_handle);
    pb_uint(&w, 2, 0x7FFFFFFF);
    pb_uint(&w, 3, measurement_type);
    uint8_t reply[RPC_MAX_BODY];
    uint32_t length = 0;
    int rc = rpc_call(session, ACTION_DEVICE_POWER_MEASUREMENT, body, w.length, NULL, 0, NULL, 0, reply, &length);
    if (rc != UGEN_OK) return rc;
    *value = 0;
    pb_reader r = {reply, length, 0};
    pb_field f;
    while (pb_next(&r, &f)) {
        if (f.number == 1 && f.wire_type == 5) *value = bits_to_float(f.value);
    }
    return UGEN_OK;
}
