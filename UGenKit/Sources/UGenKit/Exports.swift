// UGenKit = the stick (UGenDevice, GenAI) on top of StudioCore, the stick-free vision code shared with
// Artelico. Re-exported so `import UGenKit` keeps giving Hailo Studio everything it had.
@_exported import StudioCore

extension UGenDevice: InferenceEngine {}
