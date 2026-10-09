#if os(watchOS)
import AVFoundation
import Foundation
import whisper

/// Local multilingual speech recognition for Apple Watch. The iPhone remains a fallback for failed runs.
public actor WatchAudioTranscriber {
    private let modelURL: URL
    private let sampleRate = 16_000.0
    private let chunkSeconds = 30.0

    public init(modelURL: URL) { self.modelURL = modelURL }

    public func transcribe(file url: URL) async throws -> LocalTranscript {
        let audioFile = try AVAudioFile(forReading: url)
        let source = audioFile.processingFormat
        guard audioFile.length > 0, source.channelCount == 1, source.sampleRate > 0 else {
            throw TranscriptionFailure.onDeviceUnavailable
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: format) else {
            throw TranscriptionFailure.onDeviceUnavailable
        }

        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = false
        // Watch slices are CPU-only; GGML flash attention aborts on this backend.
        contextParams.flash_attn = false
        guard let context = modelURL.path.withCString({ whisper_init_from_file_with_params($0, contextParams) }) else {
            throw TranscriptionFailure.onDeviceUnavailable
        }
        defer { whisper_free(context) }

        let chunkFrames = AVAudioFrameCount(sampleRate * chunkSeconds)
        var transcript = ""
        while audioFile.framePosition < audioFile.length {
            try Task.checkCancellation()
            let remaining = audioFile.length - audioFile.framePosition
            let chunkSourceFrames = Int64((Double(chunkFrames) * source.sampleRate / sampleRate).rounded(.up))
            let sourceFrames = AVAudioFrameCount(min(remaining, min(Int64(UInt32.max), chunkSourceFrames)))
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: sourceFrames) else {
                throw TranscriptionFailure.onDeviceUnavailable
            }
            try audioFile.read(into: input, frameCount: sourceFrames)
            guard input.frameLength > 0 else { break }
            let outputCapacity = AVAudioFrameCount((Double(input.frameLength) * sampleRate / source.sampleRate).rounded(.up)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputCapacity) else {
                throw TranscriptionFailure.onDeviceUnavailable
            }
            var supplied = false
            var conversionError: NSError?
            let conversionStatus = converter.convert(to: output, error: &conversionError) { _, status in
                guard !supplied else { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return input
            }
            guard conversionError == nil,
                  conversionStatus == .haveData || conversionStatus == .inputRanDry,
                  let samples = output.floatChannelData?[0], output.frameLength > 0 else {
                throw conversionError ?? TranscriptionFailure.onDeviceUnavailable
            }

            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = 2
            params.no_context = true
            params.no_timestamps = true
            params.print_progress = false
            params.print_realtime = false
            params.print_timestamps = false
            let status = "auto".withCString { language in
                params.language = language
                return whisper_full(context, params, samples, Int32(output.frameLength))
            }
            guard status == 0 else { throw TranscriptionFailure.onDeviceUnavailable }
            for index in 0..<whisper_full_n_segments(context) {
                if let text = whisper_full_get_segment_text(context, index) { transcript += String(cString: text) }
            }
        }

        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionFailure.empty }
        return LocalTranscript(originalText: text, segmentConfidences: [], engine: "whisper.cpp/tiny-q5_1",
                              runtime: ProcessInfo.processInfo.operatingSystemVersionString)
    }
}
#endif
