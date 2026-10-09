import Foundation
import CryptoKit
import llama
import os

public enum QwenFailure: Error {
    case missingModel, invalidManifest, checksumMismatch, insufficientMemory
    case loadFailed, contextFailed, inputTooLong, timeout, decodeFailed, emptyOutput, incompleteOutput
}

public struct ModelArtifact: Codable, Sendable {
    public let model: String
    public let file: String
    public let sha256: String
    public let sizeBytes: Int
    public let revision: String

    public static func verify(directory: URL) throws -> ModelArtifact {
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.model == "Qwen3-0.6B", manifest.sizeBytes > 8,
            manifest.file == URL(fileURLWithPath: manifest.file).lastPathComponent,
            manifest.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw QwenFailure.invalidManifest }
        let file = directory.appendingPathComponent(manifest.file)
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw QwenFailure.missingModel }
        defer { try? handle.close() }
        var hash = SHA256()
        var size = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            if size == 0 && chunk.prefix(4) != Data("GGUF".utf8) { throw QwenFailure.checksumMismatch }
            hash.update(data: chunk); size += chunk.count
        }
        guard size == manifest.sizeBytes,
            hash.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else { throw QwenFailure.checksumMismatch }
        return manifest
    }
}

public struct QwenGeneration: Codable, Sendable {
    public let text: String
    public let generatedTokens: Int
    public let initializationSeconds: Double
    public let completionSeconds: Double
    public let tokensPerSecond: Double
    public let peakResidentBytes: UInt64
    public let runtime: String
}

/// Serialized CPU inference on this actor's executor; the UI never runs decoding.
public actor QwenEngine {
    private let directory: URL
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var artifact: ModelArtifact?
    private var initializationSeconds = 0.0
    public init(directory: URL) { self.directory = directory }

    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    public func manifest() throws -> ModelArtifact {
        try load()
        return artifact!
    }

    private func load() throws {
        if model != nil { return }
        let start = Date()
        let verified = try ModelArtifact.verify(directory: directory)
        #if (os(iOS) || os(watchOS)) && !targetEnvironment(simulator)
        // Conservative process-budget check, not a guarantee against OS jetsam.
        guard os_proc_available_memory() > UInt64(verified.sizeBytes + 96 * 1_048_576) else { throw QwenFailure.insufficientMemory }
        #endif
        llama_backend_init()
        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = 0
        parameters.use_mmap = true
        guard let loaded = llama_model_load_from_file(directory.appendingPathComponent(verified.file).path, parameters) else { throw QwenFailure.loadFailed }
        var settings = llama_context_default_params()
        #if os(watchOS)
        settings.n_ctx = 1024
        settings.n_threads = 1
        #else
        settings.n_ctx = 2048
        settings.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.processorCount - 2)))
        #endif
        settings.n_batch = 64
        settings.n_ubatch = 64
        settings.n_threads_batch = settings.n_threads
        guard let initialized = llama_init_from_model(loaded, settings) else {
            llama_model_free(loaded); throw QwenFailure.contextFailed
        }
        model = loaded; context = initialized; artifact = verified
        initializationSeconds = Date().timeIntervalSince(start)
    }

    public func generate(system: String, prompt: String, maxTokens: Int = 160, timeout: TimeInterval = 60) throws -> QwenGeneration {
        try Task.checkCancellation()
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            prompt.utf8.count <= 16_000, system.utf8.count <= 8_000,
            maxTokens > 0, maxTokens <= 512, timeout.isFinite, timeout > 0 else { throw QwenFailure.inputTooLong }
        try load()
        let start = Date()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        let ctx = context!, vocab = llama_model_get_vocab(model!)!
        // Encode untrusted input as JSON, preventing literal ChatML delimiter injection.
        let quoted = String(data: try JSONEncoder().encode(prompt), encoding: .utf8)!
            .replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
        let chat = "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(quoted) /no_think<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        let count = -llama_tokenize(vocab, chat, Int32(chat.utf8.count), nil, 0, false, true)
        guard count > 0, Int(count) + maxTokens < Int(llama_n_ctx(ctx)) else { throw QwenFailure.inputTooLong }
        var tokens = [llama_token](repeating: 0, count: Int(count))
        let actual = llama_tokenize(vocab, chat, Int32(chat.utf8.count), &tokens, count, false, true)
        guard actual == count else { throw QwenFailure.decodeFailed }
        llama_memory_clear(llama_get_memory(ctx), true)
        func check() throws {
            try Task.checkCancellation()
            if clock.now >= deadline { throw QwenFailure.timeout }
        }
        for offset in stride(from: 0, to: tokens.count, by: 64) {
            try check()
            var chunk = Array(tokens[offset..<min(offset + 64, tokens.count)])
            let result = chunk.withUnsafeMutableBufferPointer { buffer in
                llama_decode(ctx, llama_batch_get_one(buffer.baseAddress!, Int32(buffer.count)))
            }
            guard result == 0 else { throw QwenFailure.decodeFailed }
        }
        guard let sampler = llama_sampler_init_greedy() else { throw QwenFailure.contextFailed }
        defer { llama_sampler_free(sampler) }
        var output = Data(), generated = 0, completed = false
        let generationStart = Date()
        for _ in 0..<maxTokens {
            try check()
            var token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { completed = true; break }
            var piece = [CChar](repeating: 0, count: 256)
            let size = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            guard size >= 0, size <= piece.count else { throw QwenFailure.decodeFailed }
            output.append(contentsOf: piece.prefix(Int(size)).map { UInt8(bitPattern: $0) })
            generated += 1
            guard llama_decode(ctx, llama_batch_get_one(&token, 1)) == 0 else { throw QwenFailure.decodeFailed }
        }
        guard completed else { throw QwenFailure.incompleteOutput }
        guard generated > 0, let text = String(data: output, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw QwenFailure.emptyOutput }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return QwenGeneration(text: text, generatedTokens: generated,
            initializationSeconds: initializationSeconds, completionSeconds: Date().timeIntervalSince(start),
            tokensPerSecond: Double(generated) / max(0.001, Date().timeIntervalSince(generationStart)),
            peakResidentBytes: UInt64(usage.ru_maxrss), runtime: "llama.cpp/b6500 CPU")
    }
}
