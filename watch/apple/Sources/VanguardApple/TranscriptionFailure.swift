import Foundation

/// Why speech could not be turned into text on a device. Shared by every platform (watchOS has no Speech
/// framework, so only the iPhone/macOS transcriber throws these, but the controller reports them everywhere).
public enum TranscriptionFailure: Error {
    case permissionRequired, onDeviceUnavailable, busy, empty, timeout
}
