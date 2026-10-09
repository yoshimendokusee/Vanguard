import Foundation

public actor NativeWorkflow {
    public let store: NativeStore
    public let engine: QwenEngine
    /// Offline terminology pack bundled in the app. Optional: a missing pack only means fewer reported terms.
    public let pack: TermPack?
    public init(store: NativeStore, engine: QwenEngine, pack: TermPack? = try? TermPack.bundled()) {
        self.store = store; self.engine = engine; self.pack = pack
    }

    /// Test seam only: lets unit tests exercise the pipeline without the 400 MB model. Production never sets it,
    /// and an overridden run is never evidence that Qwen executed (the live tests cover real inference).
    struct Override: Sendable { let generate: @Sendable (String) async throws -> String; let artifact: ModelArtifact }
    private var override: Override?
    func setOverride(_ value: Override?) { override = value }

    private func modelOutput(for transcript: String) async throws -> String {
        if let override { return try await override.generate(transcript) }
        return try await engine.generate(system: NativeProcessing.prompt, prompt: transcript, maxTokens: 256).text
    }
    private func modelArtifact() async throws -> ModelArtifact {
        if let override { return override.artifact }
        return try await engine.manifest()
    }

    private var inFlight: [String: Task<NativeProcessing, Error>] = [:]

    /// One job per capture: if recovery, the relay and the screen ask for the same capture at once, they share
    /// one extraction instead of running the model repeatedly or racing to store different results.
    public func process(_ capture: NativeCapture, device: AiDevice) async throws -> NativeProcessing {
        if let running = inFlight[capture.id] { return try await running.value }
        let job = Task { try await perform(capture, device: device) }
        inFlight[capture.id] = job
        defer { inFlight[capture.id] = nil }
        return try await job.value
    }

    private func perform(_ capture: NativeCapture, device: AiDevice) async throws -> NativeProcessing {
        // Never depend on an inference engine or paired device to preserve input.
        try await store.save(capture)
        if let saved = try await store.processing(id: capture.id) {
            return try JSONDecoder().decode(NativeProcessing.self, from: saved)
        }
        let speech = try await store.transcription(id: capture.id)
        guard let transcript = capture.transcript ?? speech?.text else { throw QwenFailure.emptyOutput }
        let output = try await modelOutput(for: transcript)
        var processing = try NativeProcessing.validated(generated: output, transcript: transcript,
            device: device, sttEngine: speech?.engine ?? "typed/original", artifact: try await modelArtifact())
        // RAG findings are quote-grounded rules, not model output (the 0.6B model cannot do this reliably).
        processing.findings = DeterministicIntake.findings(for: transcript, terms: pack?.retrieve(transcript, limit: 12) ?? [])
        try await store.complete(id: capture.id, transcript: transcript, processingJSON: JSONEncoder().encode(processing))
        try await finalize(capture.id)
        return processing
    }

    /// Stores the iPhone's speech transcript and extraction for an audio capture recorded on this device.
    /// The original audio stays; the speech text becomes the immutable original transcript.
    public func adoptRemote(captureID: String, processingJSON: Data) async throws {
        let processing = try JSONDecoder().decode(NativeProcessing.self, from: processingJSON)
        guard processing.isValid, let capture = try await store.captures().first(where: { $0.id == captureID }) else { throw NativeStoreFailure.invalidCapture }
        if capture.transcript == nil {
            try await store.saveTranscription(id: captureID, transcript: processing.originalTranscript, engine: processing.provenance.sttEngine)
        }
        try await store.complete(id: captureID, transcript: processing.originalTranscript, processingJSON: processingJSON)
        try await finalize(captureID)
    }

    /// After a report is durably extracted: retain legacy optional fields as revision 1 and queue it for delivery
    /// (unless the person chose Save only). Idempotent, and never blocks on a human review step.
    func finalize(_ id: String) async throws {
        if try await store.detailRevisions(captureID: id).isEmpty { try await store.appendDetails(captureID: id, source: "extracted", ReportDetails()) }
        try await store.queueForDelivery(captureID: id)
    }

    /// Re-extracts a corrected transcript (a new immutable version). The original and its processing are untouched.
    public func processCorrection(captureID: String, version: Int, device: AiDevice) async throws -> NativeProcessing {
        guard let target = try await store.transcriptVersions(captureID: captureID).first(where: { $0.version == version && version > 0 }) else { throw NativeStoreFailure.invalidCapture }
        if let saved = target.processing { return try JSONDecoder().decode(NativeProcessing.self, from: saved) }
        let output = try await modelOutput(for: target.transcript)
        var processing = try NativeProcessing.validated(generated: output, transcript: target.transcript, device: device,
            sttEngine: "corrected-on-device", artifact: try await modelArtifact())
        processing.findings = DeterministicIntake.findings(for: target.transcript, terms: pack?.retrieve(target.transcript, limit: 12) ?? [])
        try await store.completeCorrection(captureID: captureID, version: version, processingJSON: JSONEncoder().encode(processing))
        return processing
    }

    #if os(iOS) || os(macOS) || os(watchOS)
    public func processAudio(_ capture: NativeCapture) async throws -> NativeProcessing {
        try await store.save(capture)
        if try await store.transcription(id: capture.id) == nil {
            guard let path = capture.audioPath else { throw TranscriptionFailure.empty }
            let file = URL(fileURLWithPath: path)
            #if os(watchOS)
            guard let model = Bundle.main.url(forResource: "ggml-tiny-q5_1", withExtension: "bin",
                                              subdirectory: "whisper-tiny-q5_1") else {
                throw TranscriptionFailure.onDeviceUnavailable
            }
            let transcript = try await WatchAudioTranscriber(modelURL: model).transcribe(file: file)
            try await store.saveTranscription(id: capture.id, transcript: transcript.originalText, engine: transcript.engine)
            return try await process(capture, device: .appleWatch)
            #else
            guard await OnDeviceTranscriber.requestPermission() else { throw TranscriptionFailure.permissionRequired }
            // English and Filipino are both tried on-device; the more confident transcript is kept (never the cloud).
            let (transcript, locale) = try await LocaleSelection.best(locales: LocaleSelection.defaultLocales) { locale in
                try await OnDeviceTranscriber().transcribe(file: file, locale: locale)
            }
            try await store.saveTranscription(id: capture.id, transcript: transcript.originalText, engine: "\(transcript.engine)/\(locale.identifier)")
            #endif
        }
        #if os(watchOS)
        return try await process(capture, device: .appleWatch)
        #else
        return try await process(capture, device: .iphone)
        #endif
    }
    #endif

    private var syncing = false

    /// Only validated ACK IDs from this request advance hospital receipt state. Each report moves through the
    /// persisted delivery states: TRANSFERRING while the request is in flight, AWAITING_RECEIPT once a response
    /// arrived, DELIVERED only after a valid acknowledgment is stored, RETRY_REQUIRED after a transient failure and
    /// FAILED_PERMANENTLY when the hospital explicitly rejects the report. Reports held by Save only are not sent.
    public func sync(to hub: URL, token: String = "", session: URLSession = .shared) async throws -> Int {
        guard !syncing else { return 0 }
        syncing = true
        defer { syncing = false }
        #if os(iOS) || os(watchOS)
        let endpoint = try HubEndpoint(hub.absoluteString)
        #else
        let endpoint = try HubEndpoint(hub.absoluteString, allowLoopback: true)
        #endif
        try await store.recoverInterruptedDelivery()
        let pending = try await store.deliverable()
        if pending.isEmpty {
            let request = try endpoint.request(path: "api/config", token: token, requestID: UUID().uuidString)
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                config["contractVersion"] as? Int == 1, config["hospital"] as? String != nil else { throw HubFailure.invalidReceipt }
        }
        var acknowledged = 0
        for row in pending.prefix(100) {
            let id = row["id"]!
            try await store.setDelivery(captureID: id, .transferring, countAttempt: true)
            do {
                guard let localID = Int64(row["local_id"]!), let json = row["processing"]?.data(using: .utf8),
                    let processing = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw NativeStoreFailure.unavailable }
                let details = try await store.detailRevisions(captureID: id).first?.details ?? ReportDetails()
                var report: [String: Any] = ["localId": localID, "reportId": id, "createdAt": row["created_at"]!,
                    "rawText": row["processed_transcript"]!, "processing": processing, "triage": "Unassessed",
                    "location": details.location ?? "Unspecified", "injuries": "Unspecified",
                    "patientCount": details.patientCount.map { $0 as Any } ?? NSNull(), "ageGroup": details.ageGroup,
                    "etaMinutes": details.etaMinutes.map { $0 as Any } ?? NSNull()]
                if let encounter = try await store.deliveryRecord(captureID: id)?.encounterID { report["encounterId"] = encounter }
                var request = try endpoint.request(path: "api/sync-triage", token: token, requestID: id)
                request.httpMethod = "POST"; request.timeoutInterval = 8
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["watchId": row["watch_id"]!, "reports": [report]])
                guard request.httpBody!.count <= 900 * 1024 else { throw HubFailure.invalidReceipt }
                let (data, response) = try await session.data(for: request)
                try await store.setDelivery(captureID: id, .awaitingReceipt)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                // The hospital explicitly refused this report: retrying the same bytes cannot succeed.
                if [400, 413].contains(status) || (status == 200 && (body?["rejected"] as? [[String: Any]])?.isEmpty == false) {
                    let reason = (body?["error"] as? String) ?? ((body?["rejected"] as? [[String: Any]])?.first?["reason"] as? String) ?? "rejected"
                    try await store.setDelivery(captureID: id, .failedPermanently, error: "Hospital rejected the report: \(reason)")
                    continue
                }
                guard status == 200, let body, body["ok"] as? Bool == true,
                    let ids = body["ackLocalIds"] as? [Int64], ids == [localID],
                    let inserted = body["inserted"] as? Int, let duplicates = body["duplicates"] as? Int,
                    inserted >= 0, duplicates >= 0, inserted + duplicates == 1,
                    let rejected = body["rejected"] as? [[String: Any]], rejected.isEmpty else { throw HubFailure.invalidReceipt }
                try await store.acknowledge(ids: [id]); acknowledged += 1
            } catch {
                try? await store.setDelivery(captureID: id, .retryRequired, error: "Not delivered: \(type(of: error))")
                throw error
            }
        }
        // Corrections are best effort: a failure keeps them queued and never undoes a delivered report.
        try? await syncCorrections(endpoint: endpoint, token: token, session: session)
        return acknowledged
    }

    /// Sends transcript corrections for already delivered reports as hub report revisions. The hub addresses a
    /// report by its own integer ID, found through the stored report UUID, and requires the current base revision.
    func syncCorrections(endpoint: HubEndpoint, token: String, session: URLSession) async throws {
        let corrections = try await store.correctionsToSend()
        guard !corrections.isEmpty else { return }
        for correction in corrections {
            let lookup = try await session.data(for: endpoint.request(path: "api/triage/source/\(correction.captureID)", token: token, requestID: correction.requestID))
            guard (lookup.1 as? HTTPURLResponse)?.statusCode == 200,
                  let detail = try JSONSerialization.jsonObject(with: lookup.0) as? [String: Any],
                  detail["source_report_id"] as? String == correction.captureID,
                  let hubID = detail["id"] as? Int, let revision = detail["revision"] as? Int,
                  let history = detail["history"] as? [[String: Any]],
                  let capture = try await store.captures().first(where: { $0.id == correction.captureID }) else { continue }
            // A lost response can be recovered from immutable history even after a later hospital correction.
            if let replay = history.first(where: { $0["request_id"] as? String == correction.requestID }),
               let payload = replay["payload"] as? [String: Any], payload["transcript"] as? String == correction.transcript {
                try await store.markCorrectionSent(captureID: correction.captureID, version: correction.version)
                continue
            }
            let versions = try await store.transcriptVersions(captureID: correction.captureID)
            let previous = versions.first { $0.version == correction.version - 1 }
            let base = correction.version == 1 ? 0 : history.first(where: { $0["request_id"] as? String == previous?.requestID })?["revision"] as? Int
            // Never rebase an old device correction over a newer hospital assessment or correction.
            guard let base, revision == base, detail["current_transcript"] as? String == previous?.transcript else { continue }
            var payload: [String: Any] = ["requestId": correction.requestID, "baseRevision": base, "actor": "apple-watch:\(capture.watchID)",
                "reason": String(correction.reason.prefix(500)), "kind": "correction", "transcript": correction.transcript]
            if let data = correction.processing, let processing = try? JSONSerialization.jsonObject(with: data) { payload["processing"] = processing }
            var request = try endpoint.request(path: "api/triage/\(hubID)/revisions", token: token, requestID: correction.requestID)
            request.httpMethod = "POST"; request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["current_transcript"] as? String == correction.transcript else { continue }
            try await store.markCorrectionSent(captureID: correction.captureID, version: correction.version)
        }
    }
}

/// A complete report relayed after local extraction, using the same immutable intake as direct LAN delivery.
public struct RelayedReport: Codable, Sendable {
    public let capture: NativeCapture
    public let processing: Data
    public let details: ReportDetails
    public let encounterID: String
    public let corrections: [RelayedCorrection]
}

public struct RelayedCorrection: Codable, Sendable {
    public let version: Int
    public let transcript: String
    public let reason: String
    public let requestID: String
    public let processing: Data?
}

extension NativeWorkflow {
    public func relayReport(id: String) async throws -> RelayedReport {
        guard let capture = try await store.captures().first(where: { $0.id == id }),
              let processing = try await store.processing(id: id),
              let record = try await store.deliveryRecord(captureID: id) else { throw NativeStoreFailure.invalidCapture }
        let original = try JSONDecoder().decode(NativeProcessing.self, from: processing).originalTranscript
        return RelayedReport(capture: NativeCapture(id: id, watchID: capture.watchID, createdAt: capture.createdAt, transcript: original),
            processing: processing, details: try await store.detailRevisions(captureID: id).first?.details ?? ReportDetails(), encounterID: record.encounterID,
            corrections: try await store.transcriptVersions(captureID: id).filter { $0.version > 0 }.map {
                RelayedCorrection(version: $0.version, transcript: $0.transcript, reason: $0.reason, requestID: $0.requestID, processing: $0.processing)
            })
    }

    public func acceptRelay(_ report: RelayedReport) async throws {
        try await store.acceptRelay(report)
    }
}
