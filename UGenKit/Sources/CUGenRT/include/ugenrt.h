// Minimal HailoRT 5.3.0 RPC client for the ASUS UGen300 (Hailo-10H) over USB.
// Portable C with no dependencies: the caller supplies the USB transport.
// Wire format follows hailo-ai/hailort v5.3.0 (hrpc/, hrpc_protocol/rpc.proto).
#ifndef UGENRT_H
#define UGENRT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Error codes returned by this library. Values >= 0x10000 never collide with hailo_status.
enum {
    UGEN_OK = 0,
    UGEN_ERR_TRANSPORT = 0x10001,   // a USB transfer failed; see ugen_session.last_transport_error
    UGEN_ERR_PROTOCOL = 0x10002,    // bad magic, short message, or malformed reply
    UGEN_ERR_TOO_LARGE = 0x10003,   // request body does not fit in one message
    UGEN_ERR_ARGUMENT = 0x10004,
    // Any other non-zero value is a hailo_status returned by the device.
};

// USB transport supplied by the host platform. Every function returns 0 on success or a
// platform error code. All calls are blocking.
typedef struct ugen_transport {
    void *context;
    // Vendor control transfer with a host-to-device data stage.
    int (*control_out)(void *context, uint8_t request_type, uint8_t request, uint16_t value, uint16_t index,
                       const void *data, uint16_t length);
    // Vendor control transfer with a device-to-host data stage.
    int (*control_in)(void *context, uint8_t request_type, uint8_t request, uint16_t value, uint16_t index,
                      void *data, uint16_t length, uint16_t *transferred);
    // One bulk OUT transfer of exactly `length` bytes on `endpoint` (e.g. 0x01).
    int (*bulk_out)(void *context, uint8_t endpoint, const void *data, uint32_t length);
    // One bulk IN transfer of up to `length` bytes on `endpoint` (e.g. 0x81).
    int (*bulk_in)(void *context, uint8_t endpoint, void *data, uint32_t length, uint32_t *transferred);
} ugen_transport;

typedef struct ugen_session {
    ugen_transport transport;
    uint8_t interface_number;
    uint8_t endpoint_out;
    uint8_t endpoint_in;
    uint8_t connected;
    uint32_t port;
    uint32_t next_message_id;
    int last_transport_error;
} ugen_session;

typedef struct ugen_buffer {
    void *data;
    uint32_t size;
} ugen_buffer;

typedef struct ugen_const_buffer {
    const void *data;
    uint32_t size;
} ugen_const_buffer;

// hailo_format_type_t / hailo_format_order_t values used by this library.
enum { UGEN_FORMAT_TYPE_AUTO = 0, UGEN_FORMAT_TYPE_UINT8 = 1, UGEN_FORMAT_TYPE_UINT16 = 2, UGEN_FORMAT_TYPE_FLOAT32 = 3 };
enum { UGEN_FORMAT_ORDER_AUTO = 0, UGEN_FORMAT_ORDER_NHWC = 1, UGEN_FORMAT_ORDER_NMS_BY_CLASS = 22 };

typedef struct ugen_stream_params {
    const char *name;
    uint32_t format_order;
    uint32_t format_type;
    float nms_score_threshold;
    float nms_iou_threshold;
    uint32_t nms_max_proposals_per_class;
    uint32_t nms_max_accumulated_mask_size;
    uint32_t nms_max_proposals_total;
} ugen_stream_params;

typedef struct ugen_identity {
    uint32_t protocol_version;
    uint32_t fw_major, fw_minor, fw_revision;
    uint32_t logger_version;
    uint32_t device_architecture;  // 6 = HAILO10H
    uint8_t is_release;
    char board_name[64];
    char product_name[64];
    char serial_number[32];
    char part_number[32];
} ugen_identity;

#define UGEN_SERVER_PORT 12133u
#define UGEN_LLM_PORT 12145u
#define UGEN_VLM_PORT 12147u
#define UGEN_SPEECH_TO_TEXT_PORT 12149u
#define UGEN_INVALID_HANDLE 0xFFFFFFFFu

// Sends the CONNECT handshake for `interface_number` (0..4) on the HailoRT server port.
// The device must already be configured and the interface claimed by the transport.
int ugen_session_open(ugen_session *session, const ugen_transport *transport, uint8_t interface_number);
// Same, for another service on the device (for example the speech-to-text server on port 12149).
int ugen_session_open_port(ugen_session *session, const ugen_transport *transport, uint8_t interface_number, uint32_t port);
// Raw access to an open session's byte stream, for services that do not use the RPC framing (the GenAI
// servers). `ugen_session_read` returns only when exactly `length` bytes have arrived.
int ugen_session_write(ugen_session *session, const void *data, uint32_t length);
int ugen_session_read(ugen_session *session, void *data, uint32_t length);
// Sends CLOSE. Safe to call on a session that failed to open.
int ugen_session_close(ugen_session *session);

int ugen_device_create(ugen_session *session, uint32_t *device_handle);
int ugen_device_identify(ugen_session *session, uint32_t device_handle, ugen_identity *identity);
int ugen_device_chip_temperature(ugen_session *session, uint32_t device_handle, float *ts0, float *ts1);
int ugen_device_destroy(ugen_session *session, uint32_t device_handle);

int ugen_vdevice_create(ugen_session *session, uint32_t *vdevice_handle);
int ugen_vdevice_destroy(ugen_session *session, uint32_t vdevice_handle);

// Uploads a HEF and creates an infer model from it.
int ugen_infer_model_create(ugen_session *session, uint32_t vdevice_handle, const void *hef, uint32_t hef_size,
                            uint32_t *infer_model_handle);
int ugen_infer_model_destroy(ugen_session *session, uint32_t infer_model_handle);

int ugen_configure(ugen_session *session, uint32_t infer_model_handle, uint32_t vdevice_handle,
                   const ugen_stream_params *inputs, uint32_t input_count,
                   const ugen_stream_params *outputs, uint32_t output_count,
                   uint32_t *configured_handle, uint32_t *async_queue_size);
int ugen_configured_destroy(ugen_session *session, uint32_t configured_handle);

// Runs one inference: sends every input buffer, then fills every output buffer.
int ugen_infer(ugen_session *session, uint32_t configured_handle, uint32_t infer_model_handle,
               const ugen_const_buffer *inputs, uint32_t input_count,
               const ugen_buffer *outputs, uint32_t output_count);

// Pipelined inference: submit sends the request and its input frames and returns at once;
// collect waits for the oldest outstanding result. Results come back in submission order.
// Keep the number of outstanding submissions at or below the queue size returned by ugen_configure.
int ugen_infer_submit(ugen_session *session, uint32_t configured_handle, uint32_t infer_model_handle,
                      const ugen_const_buffer *inputs, uint32_t input_count,
                      const uint32_t *output_sizes, uint32_t output_count, uint32_t *message_id);
int ugen_infer_collect(ugen_session *session, uint32_t message_id,
                       const ugen_buffer *outputs, uint32_t output_count);

// Tells the stick to reboot. It drops off the bus and comes back in loader mode, so the runtime has to
// be uploaded again. No reply is waited for.
int ugen_system_reset(ugen_session *session);

// Current the USB-C source advertises to the stick, in mA. Hailo warns of reduced performance below 3000.
int ugen_device_current_limit(ugen_session *session, uint32_t device_handle, uint32_t *milliamps);

// Chip health (hailo_health_stats_t): hottest sensor in degrees C, core voltage in mV and the start-up
// self-test failure mask; -1 means "not available".
typedef struct {
    float on_die_temperature;
    int32_t on_die_voltage;
    int32_t bist_failure_mask;
} ugen_health;
int ugen_device_health(ugen_session *session, uint32_t device_handle, ugen_health *health);

// Load over `sampling_period_ms` (hailo_performance_stats_t): percentages, -1 when not available; RAM in KiB
// (the stick reads Linux `free`). The stick sleeps for the period, so this session answers nothing else meanwhile.
typedef struct {
    float cpu_utilization;
    int64_t ram_size_total;
    int64_t ram_size_used;
    float nnc_utilization;
    int32_t ddr_noc_total_transactions;
    int32_t dsp_utilization;
} ugen_performance;
int ugen_device_performance(ugen_session *session, uint32_t device_handle, uint32_t sampling_period_ms,
                            ugen_performance *performance);

// One power-sensor reading (hailo_power_measurement_types_t: 0 shunt mV, 1 bus mV, 2 power W, 3 current mA).
// Boards without a power sensor answer HAILO_INVALID_OPERATION.
int ugen_device_power(ugen_session *session, uint32_t device_handle, uint32_t measurement_type, float *value);

#ifdef __cplusplus
}
#endif

#endif
