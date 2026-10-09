import AVFoundation
import VanguardApple

/// The Mac's microphone for the development host. Same file format and metering as the Watch recorder
/// (16 kHz mono PCM in CAF); macOS has no AVAudioSession, so permission comes from AVCaptureDevice.
@MainActor
final class MacMicrophone: AudioRecording {
    private var recorder: AVAudioRecorder?
    var onInterruption: (() -> Void)?
    var isRecording: Bool { recorder?.isRecording ?? false }

    func requestPermission() async -> Bool {
        // Outside an .app bundle macOS attributes the request to the launching app and kills this process.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(to file: URL) throws {
        guard recorder == nil else { throw RecordingFailure.alreadyRecording }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let recorder = try AVAudioRecorder(url: file, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else { throw RecordingFailure.unavailable }
        self.recorder = recorder
    }

    func stop() throws -> TimeInterval {
        guard let recorder else { throw RecordingFailure.notRecording }
        let seconds = recorder.currentTime
        recorder.stop(); self.recorder = nil
        return seconds
    }

    func level() -> Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        return AudioLevel.normalize(decibels: recorder.averagePower(forChannel: 0))
    }
}
