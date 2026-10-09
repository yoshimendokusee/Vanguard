import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Converts microphone power (dBFS, as reported by AVAudioRecorder) to 0...1 for display.
/// This is the only thing the waveform may show: real input, never an independent animation.
public enum AudioLevel {
    /// Quieter than this is treated as silence.
    public static let floorDecibels: Float = -60
    public static func normalize(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        let clamped = min(0, max(floorDecibels, decibels))
        // Perceptual curve so quiet speech is still visible.
        return powf((clamped - floorDecibels) / -floorDecibels, 2)
    }
}

public enum RecordingFailure: Error, Equatable {
    case permissionDenied, unavailable, alreadyRecording, notRecording, interrupted, empty
}

/// The microphone side of voice reporting. Production uses `MicrophoneRecorder`; tests inject a fake.
@MainActor
public protocol AudioRecording: AnyObject {
    var isRecording: Bool { get }
    /// Asks for (or checks) microphone permission.
    func requestPermission() async -> Bool
    func start(to file: URL) throws
    /// Finalizes the file and returns the seconds recorded.
    func stop() throws -> TimeInterval
    /// Current normalized input level (0...1) from the real microphone.
    func level() -> Float
    /// Called when the system interrupts recording (call, Siri, route change). The audio so far is kept.
    var onInterruption: (() -> Void)? { get set }
}

#if canImport(AVFoundation) && (os(iOS) || os(watchOS))
/// AVAudioRecorder with metering. Uncompressed 16 kHz mono PCM in a CAF container: speech recognizers accept it,
/// and a CAF file stays readable if the app dies mid-recording (an m4a would lose its index and be unplayable).
@MainActor
public final class MicrophoneRecorder: NSObject, AudioRecording, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    public var onInterruption: (() -> Void)?
    public override init() { super.init() }
    public var isRecording: Bool { recorder?.isRecording ?? false }

    public func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    public func start(to file: URL) throws {
        guard recorder == nil else { throw RecordingFailure.alreadyRecording }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let recorder = try AVAudioRecorder(url: file, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else { throw RecordingFailure.unavailable }
        self.recorder = recorder
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
    }

    public func stop() throws -> TimeInterval {
        guard let recorder else { throw RecordingFailure.notRecording }
        let seconds = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return seconds
    }

    public func level() -> Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        return AudioLevel.normalize(decibels: recorder.averagePower(forChannel: 0))
    }

    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        onInterruption?()
    }

    nonisolated public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.onInterruption?() }
    }
}
#endif
