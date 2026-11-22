import CoreGraphics
import CUGenRT
import Foundation

/// Errors from UGenKit. `code` values are IOKit return codes, hailo_status values, or client codes
/// from `ugenrt.h`, depending on the case.
public enum UGenError: Error, CustomStringConvertible, Sendable {
    /// The driver is not running: the stick is unplugged or the driver is not enabled in Settings.
    case driverNotFound
    /// The driver is running but the app could not open it.
    case driverOpenFailed(code: Int32)
    /// The driver attached to the stick but could not finish bringing it up.
    case driverNotReady(detail: String)
    /// The stick is in the wrong mode for this operation.
    case wrongMode(expected: UGenDevice.Mode, actual: UGenDevice.Mode)
    /// A USB transfer failed.
    case usbTransfer(step: String, code: Int32)
    /// The device answered with a HailoRT error status.
    case deviceStatus(step: String, status: Int32)
    /// The reply did not follow the protocol, or the loader is not the supported one.
    case client(step: String, code: Int32)
    case runtimeDidNotAppear
    /// An earlier client left the stick in a state only a restart clears. The stick has been told to
    /// reboot; connect again in a few seconds and boot the runtime.
    case restarting
    /// Every interface on the stick is held by clients that are gone. Only unplugging clears that.
    case replugNeeded
    case noModelLoaded
    case invalidInput(String)

    public var description: String {
        switch self {
        case .driverNotFound:
            return "Driver not found. Plug in the UGen300 and enable the driver in Settings."
        case .driverOpenFailed(let code):
            // 0xe00002c7 is "unsupported": the driver running on the iPad is older than the app.
            if UInt32(bitPattern: code) == 0xe00002c7 {
                return "The driver on the iPad is out of date. Unplug the stick and plug it back in to load the new one."
            }
            return "Could not open the driver (\(hex(code)))."
        case .driverNotReady(let detail):
            return "Driver could not bring up the device: \(detail)"
        case .wrongMode(let expected, let actual):
            return "Device is in \(actual) mode; this needs \(expected) mode."
        case .usbTransfer(let step, let code):
            return "\(step): USB transfer failed (\(hex(code)))."
        case .deviceStatus(let step, let status):
            return "\(step): device returned hailo_status \(status)."
        case .client(let step, let code):
            return "\(step): client error \(hex(code))."
        case .runtimeDidNotAppear:
            return "The runtime did not appear after the upload."
        case .restarting:
            return "The stick is restarting to clear a session left by an earlier run."
        case .replugNeeded:
            return "The stick is not answering. Unplug it, wait 3 seconds, and plug it back in."
        case .noModelLoaded:
            return "No model is loaded."
        case .invalidInput(let message):
            return message
        }
    }
}

private func hex(_ code: Int32) -> String { String(format: "0x%08x", UInt32(bitPattern: code)) }

/// An ASUS UGen300 (Hailo-10H) reached through the UGenDriver DriverKit extension.
///
/// Typical use:
/// ```swift
/// let device = UGenDevice()
/// if try await device.connect() == .loader {
///     try await device.bootRuntime(image: runtimeImageURL)
/// }
/// let model = ModelCatalog.model(named: "yolov8m")!
/// try await device.loadModel(hef: yolov8mURL, info: model)
/// let result = try await VisionPipeline.run(.detection, on: cgImage, device: device)
/// ```
public actor UGenDevice {
    public enum Mode: String, Sendable {
        case unknown, loader, runtime
    }

    public struct Identity: Sendable {
        public let firmwareVersion: String
        public let architecture: UInt32
        public let isRelease: Bool
        public let chipTemperatureCelsius: Float?
        /// Current the USB-C source advertises to the stick. Hailo warns of reduced performance below 3000 mA.
        public let currentLimitMilliamps: UInt32?
    }

    public struct LoaderInfo: Sendable {
        public let protocolVersion: UInt32
        public let sku: String
        public let build: String
    }

    // The transport holds a pointer to this, so it lives on the heap for the actor's lifetime.
    private let connection = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    private var transport = ugen_transport()
    private var session = ugen_session()
    private var sessionOpen = false
    private struct Loaded {
        let info: ModelInfo
        let inferModel: UInt32
        let configured: UInt32
        let queueSize: Int
    }

    private var vdevice: UInt32?
    /// Models on the stick, by name. Several can be loaded at once; the stick switches between them.
    private var loaded: [String: Loaded] = [:]
    /// The model `infer`, `submit` and `loadedModel` refer to when no name is given.
    private var primary: String?
    /// Frames sent and not yet collected, oldest first.
    private var pending: [(messageID: UInt32, model: String)] = []

    /// The session of the GenAI service in use (speech-to-text, LLM or VLM), on interface 0. Only one of
    /// this and the vision session is open at a time. The framing on top of it lives in GenAI.swift.
    var genaiSession = ugen_session()
    /// Port of the open GenAI session, or nil when there is none.
    private(set) var genaiPort: UInt32?
    /// Changes every time a GenAI session is opened, so a model object can tell that its session is gone.
    private(set) var genaiSessionID = 0

    public private(set) var mode: Mode = .unknown

    public init() {
        connection.initialize(to: 0)
    }

    deinit {
        if connection.pointee != 0 { ugen_driver_close(connection.pointee) }
        connection.deallocate()
    }

    // MARK: Connection

    /// Opens the driver and reports which mode the stick is in.
    @discardableResult
    public func connect() throws -> Mode {
        disconnect()
        let status = ugen_driver_open(connection)
        if status == Int32(UGEN_DRIVER_NOT_FOUND) { throw UGenError.driverNotFound }
        guard status == 0 else { throw UGenError.driverOpenFailed(code: status) }
        ugen_driver_make_transport(connection, &transport)

        var info = ugen_driver_info()
        let infoStatus = ugen_driver_get_info(connection.pointee, &info)
        guard infoStatus == 0 else {
            disconnect()
            throw UGenError.driverOpenFailed(code: infoStatus)
        }
        guard info.ready == 1 else {
            let detail = "open \(hex(info.open_status)), configuration \(hex(info.set_config_status)), "
                + "interface \(hex(info.interface_status)), buffers \(hex(info.buffer_status))"
            disconnect()
            throw UGenError.driverNotReady(detail: detail)
        }
        mode = (info.mode == 1) ? .loader : (info.mode == 2 ? .runtime : .unknown)
        return mode
    }

    /// Closes the session and the driver connection. Loaded models are released on the device, and so
    /// is a GenAI model (speech-to-text, LLM or VLM) if one is in use.
    public func disconnect() {
        closeGenAISession()
        closeVisionSession()
        if connection.pointee != 0 {
            ugen_driver_close(connection.pointee)
            connection.pointee = 0
        }
        mode = .unknown
    }

    // MARK: Loader

    /// Reads the loader's version information. Read-only.
    public func loaderInfo() throws -> LoaderInfo {
        try require(.loader)
        var info = ugen_loader_info()
        var transportError: Int32 = 0
        try check("loader probe", ugen_loader_probe(&transport, &info, &transportError), transportError: transportError)
        return LoaderInfo(protocolVersion: info.protocol, sku: string(from: info.sku), build: string(from: info.build))
    }

    /// Uploads the runtime root filesystem to the stick's RAM, waits for it to restart in runtime mode,
    /// and reconnects. The image is needed after every power cycle of the stick.
    /// - Parameter image: `core-image-hailo-hailo10-usb-dongle.ext4` from the HailoRT 5.3.0 USB package.
    public func bootRuntime(image: URL, timeout: Duration = .seconds(30)) async throws {
        try require(.loader)
        let data = try Data(contentsOf: image, options: .mappedIfSafe)
        guard !data.isEmpty, data.count <= Int(UInt32.max) else { throw UGenError.invalidInput("Runtime image is empty or too large.") }

        var transportError: Int32 = 0
        let result = data.withUnsafeBytes { bytes in
            ugen_loader_upload(&transport, bytes.baseAddress, UInt32(bytes.count), { usleep($0 * 1000) }, nil, nil, &transportError)
        }
        try check("runtime upload", result, transportError: transportError)

        // The loader drops off the bus and the runtime enumerates a few seconds later.
        disconnect()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            if (try? connect()) == .runtime { return }
            disconnect()
        }
        throw UGenError.runtimeDidNotAppear
    }

    // MARK: Runtime

    public func identify() throws -> Identity {
        try openSessionIfNeeded()
        var handle: UInt32 = 0
        try check("device create", ugen_device_create(&session, &handle))
        defer { _ = ugen_device_destroy(&session, handle) }
        var identity = ugen_identity()
        try check("identify", ugen_device_identify(&session, handle, &identity))
        var ts0: Float = 0
        var ts1: Float = 0
        let hasTemperature = ugen_device_chip_temperature(&session, handle, &ts0, &ts1) == Int32(UGEN_OK)
        var milliamps: UInt32 = 0
        let hasCurrent = ugen_device_current_limit(&session, handle, &milliamps) == Int32(UGEN_OK)
        return Identity(firmwareVersion: "\(identity.fw_major).\(identity.fw_minor).\(identity.fw_revision)",
                        architecture: identity.device_architecture,
                        isRelease: identity.is_release != 0,
                        chipTemperatureCelsius: hasTemperature ? ts0 : nil,
                        currentLimitMilliamps: hasCurrent ? milliamps : nil)
    }

    /// The chip's health and load (hailort's query_health_stats, query_performance_stats and power_measurement
    /// examples). Each reading is nil when the stick does not answer it; `unsupported` says which and why.
    public struct ChipStats: Sendable {
        public var temperatureCelsius: Float?
        public var coreMillivolts: Int?
        /// Start-up self-test failures (0 = none).
        public var selfTestFailures: Int?
        public var cpuPercent: Float?
        /// Neural-core utilisation.
        public var neuralCorePercent: Float?
        public var dspPercent: Int?
        public var ramUsedBytes: Int64?
        public var ramTotalBytes: Int64?
        public var powerWatts: Float?
        /// "<reading>: <reason>" for every reading the stick refused.
        public var unsupported: [String] = []
    }

    /// Reads the chip's stats over `samplingMilliseconds` (the load figures are averages over that time).
    /// Returns nil without asking when frames are in flight or a language model holds the stick, since the
    /// question would share their connection.
    public func chipStats(samplingMilliseconds: UInt32 = 300) throws -> ChipStats? {
        guard pending.isEmpty, genaiPort == nil else { return nil }
        try openSessionIfNeeded()
        var handle: UInt32 = 0
        try check("device create", ugen_device_create(&session, &handle))
        defer { _ = ugen_device_destroy(&session, handle) }
        var stats = ChipStats()
        func refused(_ what: String, _ code: Int32) { stats.unsupported.append("\(what): \(Self.statusName(code))") }

        var health = ugen_health()
        let healthCode = ugen_device_health(&session, handle, &health)
        if healthCode == Int32(UGEN_OK) {
            stats.temperatureCelsius = health.on_die_temperature
            if health.on_die_voltage >= 0 { stats.coreMillivolts = Int(health.on_die_voltage) }
            if health.bist_failure_mask >= 0 { stats.selfTestFailures = Int(health.bist_failure_mask) }
        } else {
            refused("health", healthCode)
            // The plain temperature call is older and answered more widely.
            var ts0: Float = 0, ts1: Float = 0
            if ugen_device_chip_temperature(&session, handle, &ts0, &ts1) == Int32(UGEN_OK) { stats.temperatureCelsius = max(ts0, ts1) }
        }

        var load = ugen_performance()
        let loadCode = ugen_device_performance(&session, handle, samplingMilliseconds, &load)
        if loadCode == Int32(UGEN_OK) {
            if load.cpu_utilization >= 0 { stats.cpuPercent = load.cpu_utilization }
            if load.nnc_utilization >= 0 { stats.neuralCorePercent = load.nnc_utilization }
            if load.dsp_utilization >= 0 { stats.dspPercent = Int(load.dsp_utilization) }
            // The stick reads RAM from Linux `free`, in KiB.
            if load.ram_size_total > 0 { stats.ramTotalBytes = load.ram_size_total * 1024; stats.ramUsedBytes = load.ram_size_used * 1024 }
        } else {
            refused("load", loadCode)
        }

        var watts: Float = 0
        let powerCode = ugen_device_power(&session, handle, 2, &watts)  // HAILO_POWER_MEASUREMENT_TYPES__POWER
        if powerCode == Int32(UGEN_OK) { stats.powerWatts = watts } else { refused("power", powerCode) }
        return stats
    }

    /// hailo_status names for the codes these calls return.
    static func statusName(_ code: Int32) -> String {
        switch code {
        case 79: return "HAILO_NOT_SUPPORTED (79)"
        case 6: return "HAILO_INVALID_OPERATION (6)"
        // The firmware reads power from a Linux hwmon power sensor; the stick has none, so the file is missing.
        case 13: return "HAILO_OPEN_FILE_FAILURE (13): no power sensor on this board"
        case 75: return "HAILO_INVALID_DEVICE_ARCHITECTURE (75)"
        case Int32(UGEN_ERR_TRANSPORT): return "USB transfer failed"
        case Int32(UGEN_ERR_PROTOCOL): return "unexpected reply"
        default: return "status \(code)"
        }
    }

    /// Uploads a compiled model (HEF) and makes it the only model on the stick. Outputs stay in the
    /// model's own data types; use `Tensor.floats()` to convert them.
    public func loadModel(hef: URL, info: ModelInfo) throws {
        try openSessionIfNeeded()
        unloadModels()
        try addModel(hef: hef, info: info)
        primary = info.name
    }

    /// Uploads another model next to the ones already loaded (for pipelines that use two models, such
    /// as finding text and then reading it). Does nothing if it is already loaded.
    public func addModel(hef: URL, info: ModelInfo) throws {
        try openSessionIfNeeded()
        guard loaded[info.name] == nil else { return }
        let data = try Data(contentsOf: hef, options: .mappedIfSafe)
        guard !data.isEmpty, data.count <= Int(UInt32.max) else { throw UGenError.invalidInput("HEF is empty or too large.") }

        if vdevice == nil {
            var handle: UInt32 = 0
            try check("create vdevice", ugen_vdevice_create(&session, &handle))
            vdevice = handle
        }
        guard let vdevice else { return }

        var modelHandle: UInt32 = 0
        let createStatus = data.withUnsafeBytes { bytes in
            ugen_infer_model_create(&session, vdevice, bytes.baseAddress, UInt32(bytes.count), &modelHandle)
        }
        try check("create infer model", createStatus)

        // No stream parameters: the device keeps the HEF's default formats and NMS settings.
        var configuredHandle: UInt32 = 0
        var queueSize: UInt32 = 0
        let configureStatus = ugen_configure(&session, modelHandle, vdevice, nil, 0, nil, 0, &configuredHandle, &queueSize)
        if configureStatus != Int32(UGEN_OK) {
            _ = ugen_infer_model_destroy(&session, modelHandle)
            try check("configure", configureStatus)
        }
        loaded[info.name] = Loaded(info: info, inferModel: modelHandle, configured: configuredHandle, queueSize: Int(queueSize))
        if primary == nil { primary = info.name }
    }

    /// The main model currently loaded on the stick, if any.
    public var loadedModel: ModelInfo? { primary.flatMap { loaded[$0]?.info } }

    /// Names of every model currently on the stick.
    public var loadedModelNames: [String] { loaded.keys.sorted() }

    /// Runs a loaded model once. `inputs` are raw frames in the order of `ModelInfo.inputs`.
    /// `model` names which loaded model to use; nil means the main one.
    public func infer(inputs: [[UInt8]], model: String? = nil) throws -> [Tensor] {
        try submit(inputs: inputs, model: model)
        return try collect()
    }

    /// Sends one set of input frames without waiting for the result. Call `collect()` once per
    /// submission, in order. Keeping two or more frames in flight roughly doubles throughput.
    public func submit(inputs given: [[UInt8]], model name: String? = nil) throws {
        guard let key = name ?? primary, let entry = loaded[key] else { throw UGenError.noModelLoaded }
        let model = entry.info
        let inputs = Self.stickInputs(given, model: model)
        guard inputs.count == model.inputs.count else {
            throw UGenError.invalidInput("Model needs \(model.inputs.count) input(s), got \(inputs.count).")
        }
        for (frame, stream) in zip(inputs, model.inputs) where frame.count != stream.frameSize {
            throw UGenError.invalidInput("Input \(stream.name) is \(frame.count) bytes; the model needs \(stream.frameSize).")
        }
        guard pending.count < max(1, entry.queueSize) else { throw UGenError.invalidInput("Too many frames in flight.") }

        let outputSizes = model.outputs.map { UInt32($0.frameSize) }
        var messageID: UInt32 = 0
        // Pin every input frame for the duration of the call.
        func send(_ index: Int, _ buffers: inout [ugen_const_buffer]) -> Int32 {
            if index == inputs.count {
                return ugen_infer_submit(&session, entry.configured, entry.inferModel, buffers, UInt32(buffers.count),
                                         outputSizes, UInt32(outputSizes.count), &messageID)
            }
            return inputs[index].withUnsafeBytes { raw in
                buffers.append(ugen_const_buffer(data: raw.baseAddress, size: UInt32(raw.count)))
                return send(index + 1, &buffers)
            }
        }
        var buffers: [ugen_const_buffer] = []
        try check("infer (send)", send(0, &buffers))
        pending.append((messageID, key))
    }

    /// Pictures in the input's own quantization where the model needs it. Most models take plain pixels
    /// (or have a scale near 1 that makes no visible difference); denoising models do not: dncnn's
    /// input is (q - 46) x 1.585, so plain pixels come out too bright. For those the pixels are
    /// rescaled as q = pixel / scale + zero point (checked against the Core ML conversion: mean 1.03 ->
    /// 0.84, Core ML 0.84).
    static func stickInputs(_ inputs: [[UInt8]], model: ModelInfo) -> [[UInt8]] {
        guard model.tasks.contains("image_denoising") else { return inputs }
        return zip(inputs, model.inputs).map { frame, stream in
            guard stream.type == "UINT8", let zero = stream.qpZp, let scale = stream.qpScale, scale > 0,
                  abs(zero) > 0.01 || abs(scale - 1) > 0.01 else { return frame }
            var table = [UInt8](repeating: 0, count: 256)
            for value in 0..<256 { table[value] = UInt8(min(255, max(0, (Float(value) / scale + zero).rounded()))) }
            return frame.map { table[Int($0)] }
        }
    }

    /// Waits for the oldest submitted frame and returns its outputs in the order of `ModelInfo.outputs`.
    public func collect() throws -> [Tensor] {
        guard !pending.isEmpty else { throw UGenError.invalidInput("Nothing was submitted.") }
        let (messageID, key) = pending.removeFirst()
        guard let model = loaded[key]?.info else { throw UGenError.noModelLoaded }

        // One raw buffer per output for the C call, copied into arrays afterwards.
        let raw = model.outputs.map { UnsafeMutableRawBufferPointer.allocate(byteCount: $0.frameSize, alignment: 16) }
        defer { raw.forEach { $0.deallocate() } }
        let buffers = raw.map { ugen_buffer(data: $0.baseAddress, size: UInt32($0.count)) }
        try check("infer (receive)", ugen_infer_collect(&session, messageID, buffers, UInt32(buffers.count)))
        return zip(model.outputs, raw).map { Tensor(stream: $0, bytes: [UInt8]($1)).withPerChannelDequantized }
    }

    /// Number of submitted frames whose results have not been collected yet.
    public var framesInFlight: Int { pending.count }

    /// How many frames the device accepts in flight for the main model.
    public var queueSize: Int { primary.flatMap { loaded[$0]?.queueSize } ?? 0 }

    // MARK: GenAI session

    /// Closes the vision session, if it is open, and opens a session with the GenAI service on `port`
    /// (`UGEN_LLM_PORT`, `UGEN_VLM_PORT` or `UGEN_SPEECH_TO_TEXT_PORT`) on interface 0. Vision models
    /// loaded on the stick are released, and a GenAI session that was open is closed first: the stick
    /// gives this process one session at a time.
    ///
    /// The vision session is opened first when it is not already, because that is the check that
    /// interface 0 answers; it restarts the stick when an earlier client left it stuck (see
    /// `openSessionIfNeeded`), in which case this throws `.restarting` or `.replugNeeded`.
    /// - Returns: The id of the new session, to pass to the GenAI calls.
    func openGenAISession(port: UInt32) throws -> Int {
        try require(.runtime)
        closeGenAISession()
        try openSessionIfNeeded()
        closeVisionSession()
        // The interface has to be opened afresh for a new session: without this, a session that follows
        // another one on the same interface takes requests but its replies never arrive (seen on the stick).
        let reset = ugen_driver_reset(connection, 0)
        guard reset == 0 else { throw UGenError.driverOpenFailed(code: reset) }
        ugen_driver_make_transport(connection, &transport)

        let status = ugen_session_open_port(&genaiSession, &transport, 0, port)
        if status != Int32(UGEN_OK) {
            let transportError = genaiSession.last_transport_error
            genaiSession.connected = 0
            try check("open GenAI session (port \(port))", status, transportError: transportError)
        }
        genaiPort = port
        genaiSessionID += 1
        return genaiSessionID
    }

    /// Closes the GenAI session. The device frees the model that was created through it.
    func closeGenAISession() {
        if genaiPort != nil { _ = ugen_session_close(&genaiSession) }
        genaiSession.connected = 0
        genaiPort = nil
    }

    // MARK: Helpers

    /// Releases the vision models and closes the vision session.
    private func closeVisionSession() {
        if sessionOpen {
            for entry in loaded.values {
                _ = ugen_configured_destroy(&session, entry.configured)
                _ = ugen_infer_model_destroy(&session, entry.inferModel)
            }
            if let vdevice { _ = ugen_vdevice_destroy(&session, vdevice) }
            _ = ugen_session_close(&session)
        }
        sessionOpen = false
        vdevice = nil
        loaded.removeAll()
        primary = nil
        pending.removeAll()
    }

    private func unloadModels() {
        for entry in loaded.values {
            _ = ugen_configured_destroy(&session, entry.configured)
            _ = ugen_infer_model_destroy(&session, entry.inferModel)
        }
        if let vdevice { _ = ugen_vdevice_destroy(&session, vdevice) }
        loaded.removeAll()
        primary = nil
        vdevice = nil
        pending.removeAll()
    }

    private func require(_ expected: Mode) throws {
        guard connection.pointee != 0 else { throw UGenError.driverNotFound }
        guard mode == expected else { throw UGenError.wrongMode(expected: expected, actual: mode) }
    }

    private func openSessionIfNeeded() throws {
        try require(.runtime)
        guard !sessionOpen else { return }
        // A GenAI session and the vision session cannot be open together.
        closeGenAISession()
        // HailoRT 5.3.0 never frees the interface of a client that exited without closing (an app that
        // was killed, for example), and requests on it time out. The runtime has five interfaces, so
        // try each in turn with a short timeout. If a later one answers, earlier ones are stuck: tell
        // the stick to reboot, which is the only thing that frees them, and report that.
        ugen_driver_set_bulk_timeout(2000)
        defer { ugen_driver_set_bulk_timeout(0) }
        for interface in UInt8(0)..<5 {
            let reset = ugen_driver_reset(connection, interface)
            guard reset == 0 else { throw UGenError.driverOpenFailed(code: reset) }
            ugen_driver_make_transport(connection, &transport)

            guard ugen_session_open(&session, &transport, interface) == Int32(UGEN_OK) else { continue }
            var handle: UInt32 = 0
            guard ugen_device_create(&session, &handle) == Int32(UGEN_OK) else {
                session.connected = 0
                continue
            }
            _ = ugen_device_destroy(&session, handle)
            if interface == 0 {
                sessionOpen = true
                return
            }
            _ = ugen_system_reset(&session)
            disconnect()
            throw UGenError.restarting
        }
        disconnect()
        throw UGenError.replugNeeded
    }

    private func check(_ step: String, _ status: Int32, transportError: Int32? = nil) throws {
        guard status != Int32(UGEN_OK) else { return }
        if status == Int32(UGEN_ERR_TRANSPORT) {
            throw UGenError.usbTransfer(step: step, code: transportError ?? session.last_transport_error)
        }
        if status >= 0x10000 { throw UGenError.client(step: step, code: status) }
        throw UGenError.deviceStatus(step: step, status: status)
    }

    private func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
