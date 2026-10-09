import Foundation

public actor NativeWorkflow {
    public let store: NativeStore
    public let engine: QwenEngine
    public init(store: NativeStore, engine: QwenEngine) { self.store = store; self.engine = engine }

    public func process(_ capture: NativeCapture, device: AiDevice) async throws -> NativeProcessing {
        // Never depend on an inference engine or paired device to preserve input.
        try await store.save(capture)
        if let saved = try await store.processing(id: capture.id) {
            return try JSONDecoder().decode(NativeProcessing.self, from: saved)
        }
        let speech = try await store.transcription(id: capture.id)
        guard let transcript = capture.transcript ?? speech?.text else { throw QwenFailure.emptyOutput }
        let output = try await engine.generate(system: NativeProcessing.prompt, prompt: transcript, maxTokens: 256)
        let processing = try NativeProcessing.validated(generated: output.text, transcript: transcript,
            device: device, sttEngine: speech?.engine ?? "typed/original", artifact: try await engine.manifest())
        try await store.complete(id: capture.id, transcript: transcript, processingJSON: JSONEncoder().encode(processing))
        return processing
    }

    #if os(iOS)
    public func processAudio(_ capture: NativeCapture) async throws -> NativeProcessing {
        try await store.save(capture)
        if try await store.transcription(id: capture.id) == nil {
            guard let path = capture.audioPath, await OnDeviceTranscriber.requestPermission() else { throw TranscriptionFailure.permissionRequired }
            let transcriber = await OnDeviceTranscriber()
            let transcript = try await transcriber.transcribe(file: URL(fileURLWithPath: path), locale: Locale(identifier: "en-US"))
            try await store.saveTranscription(id: capture.id, transcript: transcript.originalText, engine: transcript.engine)
        }
        return try await process(capture, device: .iphone)
    }
    #endif

    /// Only validated ACK IDs from this request advance hospital receipt state.
    public func sync(to hub: URL, token: String = "", session: URLSession = .shared) async throws -> Int {
        #if os(iOS) || os(watchOS)
        let endpoint = try HubEndpoint(hub.absoluteString)
        #else
        let endpoint = try HubEndpoint(hub.absoluteString, allowLoopback: true)
        #endif
        let pending = try await store.outbox()
        if pending.isEmpty {
            let request = try endpoint.request(path: "api/config", token: token, requestID: UUID().uuidString)
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                config["contractVersion"] as? Int == 1, config["hospital"] as? String != nil else { throw HubFailure.invalidReceipt }
        }
        var acknowledged = 0
        for row in pending.prefix(100) {
            guard let localID = Int64(row["local_id"]!), let json = row["processing"]?.data(using: .utf8),
                let processing = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw NativeStoreFailure.unavailable }
            let report: [String: Any] = ["localId": localID, "reportId": row["id"]!, "createdAt": row["created_at"]!,
                "rawText": row["processed_transcript"]!, "processing": processing, "triage": "Unassessed",
                "location": "Unspecified", "injuries": "Unspecified", "patientCount": NSNull(), "ageGroup": "Unspecified"]
            var request = try endpoint.request(path: "api/sync-triage", token: token, requestID: row["id"]!)
            request.httpMethod = "POST"; request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["watchId": row["watch_id"]!, "reports": [report]])
            guard request.httpBody!.count <= 900 * 1024 else { throw HubFailure.invalidReceipt }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                let body = try JSONSerialization.jsonObject(with: data) as? [String: Any], body["ok"] as? Bool == true,
                let ids = body["ackLocalIds"] as? [Int64], ids == [localID],
                let inserted = body["inserted"] as? Int, let duplicates = body["duplicates"] as? Int,
                inserted >= 0, duplicates >= 0, inserted + duplicates == 1,
                let rejected = body["rejected"] as? [[String: Any]], rejected.isEmpty else { throw HubFailure.invalidReceipt }
            try await store.acknowledge(ids: [row["id"]!]); acknowledged += 1
        }
        return acknowledged
    }
}
