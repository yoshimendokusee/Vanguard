import Foundation

/// Persisted transport state. It is independent of the visible screen and survives restarts.
/// DELIVERED is only ever set from a hospital receipt, never from the act of sending.
public enum DeliveryState: String, Codable, Sendable, CaseIterable {
    case localSaved = "LOCAL_SAVED", queued = "QUEUED", transferring = "TRANSFERRING"
    case awaitingReceipt = "AWAITING_RECEIPT", delivered = "DELIVERED"
    case retryRequired = "RETRY_REQUIRED", failedPermanently = "FAILED_PERMANENTLY"
}

public struct DeliveryRecord: Sendable, Equatable {
    public let captureID: String
    public let state: DeliveryState
    public let held: Bool
    public let attempts: Int
    public let lastError: String?
    public let encounterID: String
    public let updatedAt: String
}

/// The structured report fields a person or the extractor can state. `nil` means unknown, never zero.
public struct ReportDetails: Codable, Equatable, Sendable {
    public static let ageGroups = ["Infant", "Child", "Adult", "Elderly", "Unspecified"]
    public var location: String?
    public var patientCount: Int?
    public var ageGroup: String
    public var etaMinutes: Int?
    public init(location: String? = nil, patientCount: Int? = nil, ageGroup: String = "Unspecified", etaMinutes: Int? = nil) {
        self.location = location; self.patientCount = patientCount; self.ageGroup = ageGroup; self.etaMinutes = etaMinutes
    }
    public var isValid: Bool {
        (location.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 200 } ?? true)
            && (patientCount.map { (1...99).contains($0) } ?? true)
            && Self.ageGroups.contains(ageGroup)
            && (etaMinutes.map { (1...720).contains($0) } ?? true)
    }
}

public struct TranscriptVersion: Sendable, Equatable {
    public let captureID: String
    /// 0 is the immutable original; corrections start at 1.
    public let version: Int
    public let transcript: String
    public let reason: String
    public let requestID: String
    public let createdAt: String
    public let processing: Data?
    public let sentAt: String?
}

public struct ReportSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public let createdAt: String
    public let transcript: String?
    public let hasAudio: Bool
    public let provisional: ProvisionalTriage?
    public let delivery: DeliveryState
    public let held: Bool
    public let details: ReportDetails?
}

extension NativeStore {
    private static func now() -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: Delivery state

    /// Creates the delivery record for a capture (LOCAL_SAVED) once; later calls change nothing.
    public func ensureDelivery(captureID: String, encounterID: String? = nil) throws {
        if let encounterID {
            guard UUID(uuidString: encounterID) != nil else { throw NativeStoreFailure.invalidCapture }
            if let existing = try deliveryRecord(captureID: captureID), existing.encounterID != encounterID { throw NativeStoreFailure.identityConflict }
        }
        guard try rows("SELECT 1 FROM native_captures WHERE id = ?", [captureID]).first != nil else { throw NativeStoreFailure.invalidCapture }
        try rows("INSERT OR IGNORE INTO native_delivery (capture_id, state, encounter_id, updated_at) VALUES (?, 'LOCAL_SAVED', ?, ?)",
                 [captureID, encounterID ?? UUID().uuidString.lowercased(), Self.now()])
    }

    public func deliveryRecord(captureID: String) throws -> DeliveryRecord? {
        try rows("SELECT * FROM native_delivery WHERE capture_id = ?", [captureID]).first.flatMap(Self.record)
    }

    private static func record(_ row: [String: String]) -> DeliveryRecord? {
        guard let state = row["state"].flatMap(DeliveryState.init(rawValue:)), let id = row["capture_id"], let encounter = row["encounter_id"] else { return nil }
        return DeliveryRecord(captureID: id, state: state, held: row["held"] == "1", attempts: Int(row["attempts"] ?? "0") ?? 0,
                              lastError: row["last_error"], encounterID: encounter, updatedAt: row["updated_at"] ?? "")
    }

    /// DELIVERED requires a stored hospital receipt. Anything else is rejected, so a request that was
    /// merely attempted can never be shown as delivered.
    public func setDelivery(captureID: String, _ state: DeliveryState, error: String? = nil, countAttempt: Bool = false) throws {
        try ensureDelivery(captureID: captureID)
        if state == .delivered, try rows("SELECT 1 FROM native_receipts WHERE capture_id = ?", [captureID]).first == nil {
            throw NativeStoreFailure.identityConflict
        }
        // Error text is a short diagnostic only; patient content never goes in here.
        let message = error.map { String($0.prefix(200)) }
        try rows("UPDATE native_delivery SET state = ?, last_error = ?, attempts = attempts + ?, updated_at = ? WHERE capture_id = ?",
                 [state.rawValue, state == .delivered ? nil : message, countAttempt ? "1" : "0", Self.now(), captureID])
    }

    /// "Save only": keep the report on this device and out of the outbox until it is released.
    public func setHeld(captureID: String, _ held: Bool) throws {
        try ensureDelivery(captureID: captureID)
        guard let record = try deliveryRecord(captureID: captureID), record.state != .delivered else { return }
        try rows("UPDATE native_delivery SET held = ?, state = ?, updated_at = ? WHERE capture_id = ?",
                 [held ? "1" : "0", held ? DeliveryState.localSaved.rawValue : DeliveryState.queued.rawValue, Self.now(), captureID])
    }

    /// Puts a finished report in the delivery queue unless the person chose Save only.
    public func queueForDelivery(captureID: String) throws {
        try ensureDelivery(captureID: captureID)
        guard let record = try deliveryRecord(captureID: captureID), !record.held else { return }
        if [.localSaved, .retryRequired, .failedPermanently].contains(record.state) { try setDelivery(captureID: captureID, .queued) }
    }

    /// Run at launch: a receipt always wins, and a request interrupted before its receipt is retried.
    public func recoverInterruptedDelivery() throws {
        try rows("""
            UPDATE native_delivery SET state = 'DELIVERED', last_error = NULL, updated_at = ?
            WHERE state != 'DELIVERED' AND EXISTS (SELECT 1 FROM native_receipts r WHERE r.capture_id = native_delivery.capture_id)
            """, [Self.now()])
        try rows("""
            UPDATE native_delivery SET state = 'RETRY_REQUIRED', last_error = 'Interrupted before a hospital receipt', updated_at = ?
            WHERE state IN ('TRANSFERRING', 'AWAITING_RECEIPT')
            """, [Self.now()])
    }

    /// Outbox rows that may be sent now: extracted, not receipted, not held and not permanently failed.
    public func deliverable() throws -> [[String: String]] {
        try rows("""
            SELECT c.*, e.transcript AS processed_transcript, e.processing, d.encounter_id AS encounter_id
            FROM native_captures c JOIN native_extractions e ON e.capture_id = c.id
            LEFT JOIN native_delivery d ON d.capture_id = c.id
            WHERE NOT EXISTS (SELECT 1 FROM native_receipts r WHERE r.capture_id = c.id)
              AND COALESCE(d.held, 0) = 0 AND COALESCE(d.state, 'QUEUED') != 'FAILED_PERMANENTLY'
            ORDER BY c.local_id
            """)
    }

    // MARK: Transcript versions

    /// The immutable original (version 0) followed by every correction, oldest first.
    public func transcriptVersions(captureID: String) throws -> [TranscriptVersion] {
        guard let capture = try rows("SELECT * FROM native_captures WHERE id = ?", [captureID]).first else { throw NativeStoreFailure.invalidCapture }
        var versions: [TranscriptVersion] = []
        let speech = try transcription(id: captureID)?.text
        if let original = capture["transcript"] ?? speech {
            versions.append(TranscriptVersion(captureID: captureID, version: 0, transcript: original, reason: "Original",
                requestID: captureID, createdAt: capture["created_at"] ?? "", processing: try processing(id: captureID), sentAt: nil))
        }
        for row in try rows("SELECT * FROM native_transcript_versions WHERE capture_id = ? ORDER BY version", [captureID]) {
            versions.append(TranscriptVersion(captureID: captureID, version: Int(row["version"]!)!, transcript: row["transcript"]!,
                reason: row["reason"]!, requestID: row["request_id"]!, createdAt: row["created_at"]!,
                processing: row["processing"]?.data(using: .utf8), sentAt: row["sent_at"]))
        }
        return versions
    }

    public func currentTranscript(captureID: String) throws -> String? { try transcriptVersions(captureID: captureID).last?.transcript }

    /// Appends a correction. The original is never changed, and an identical retry is idempotent.
    @discardableResult
    public func appendCorrection(captureID: String, transcript: String, reason: String = "Corrected on device",
                                 requestID: String = UUID().uuidString.lowercased()) throws -> TranscriptVersion {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 16_000, UUID(uuidString: requestID) != nil, requestID == requestID.lowercased(),
              !reason.isEmpty, reason.utf16.count <= 500 else { throw NativeStoreFailure.invalidCapture }
        let existing = try transcriptVersions(captureID: captureID)
        guard let latest = existing.last else { throw NativeStoreFailure.invalidCapture }  // audio still awaiting transcription
        if let replay = existing.first(where: { $0.requestID == requestID && $0.version > 0 }) {
            guard replay.transcript == text else { throw NativeStoreFailure.identityConflict }
            return replay
        }
        guard latest.transcript != text else { throw NativeStoreFailure.transcriptConflict }   // nothing changed
        let version = latest.version + 1
        try rows("INSERT INTO native_transcript_versions (capture_id, version, transcript, reason, request_id, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                 [captureID, String(version), text, reason, requestID, Self.now()])
        return TranscriptVersion(captureID: captureID, version: version, transcript: text, reason: reason, requestID: requestID,
                                 createdAt: Self.now(), processing: nil, sentAt: nil)
    }

    /// Attaches the re-extraction of a corrected transcript, once. It must describe exactly that transcript.
    public func completeCorrection(captureID: String, version: Int, processingJSON: Data) throws {
        guard let row = try rows("SELECT * FROM native_transcript_versions WHERE capture_id = ? AND version = ?", [captureID, String(version)]).first else { throw NativeStoreFailure.invalidCapture }
        let processing = try JSONDecoder().decode(NativeProcessing.self, from: processingJSON)
        guard processing.originalTranscript == row["transcript"], processing.isValid, processing.provenance.extraction.execution == "local",
              let json = String(data: try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: processingJSON), options: [.sortedKeys]), encoding: .utf8)
        else { throw NativeStoreFailure.transcriptConflict }
        if let old = row["processing"] { guard old == json else { throw NativeStoreFailure.identityConflict }; return }
        try rows("UPDATE native_transcript_versions SET processing = ? WHERE capture_id = ? AND version = ?", [json, captureID, String(version)])
    }

    /// Corrections whose report already has a hospital receipt and that the hospital has not acknowledged yet.
    public func correctionsToSend() throws -> [TranscriptVersion] {
        try rows("""
            SELECT v.* FROM native_transcript_versions v
            WHERE v.sent_at IS NULL AND EXISTS (SELECT 1 FROM native_receipts r WHERE r.capture_id = v.capture_id)
            ORDER BY v.capture_id, v.version
            """).map {
            TranscriptVersion(captureID: $0["capture_id"]!, version: Int($0["version"]!)!, transcript: $0["transcript"]!, reason: $0["reason"]!,
                requestID: $0["request_id"]!, createdAt: $0["created_at"]!, processing: $0["processing"]?.data(using: .utf8), sentAt: nil)
        }
    }

    public func markCorrectionSent(captureID: String, version: Int) throws {
        try rows("UPDATE native_transcript_versions SET sent_at = ? WHERE capture_id = ? AND version = ? AND sent_at IS NULL",
                 [Self.now(), captureID, String(version)])
    }

    // MARK: Report details

    /// Appends a details revision (extracted by the pipeline or edited by a person). Unchanged details add nothing.
    @discardableResult
    public func appendDetails(captureID: String, source: String, _ details: ReportDetails) throws -> Int {
        guard ["extracted", "edited"].contains(source), details.isValid else { throw NativeStoreFailure.invalidDetails }
        guard try rows("SELECT 1 FROM native_captures WHERE id = ?", [captureID]).first != nil else { throw NativeStoreFailure.invalidCapture }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(details), encoding: .utf8)!
        let latest = try rows("SELECT revision, details FROM native_report_revisions WHERE capture_id = ? ORDER BY revision DESC LIMIT 1", [captureID]).first
        if let latest, latest["details"] == json { return Int(latest["revision"]!)! }
        let revision = (latest.flatMap { Int($0["revision"]!) } ?? 0) + 1
        try rows("INSERT INTO native_report_revisions (capture_id, revision, source, details, created_at) VALUES (?, ?, ?, ?, ?)",
                 [captureID, String(revision), source, json, Self.now()])
        return revision
    }

    public func currentDetails(captureID: String) throws -> ReportDetails? {
        try rows("SELECT details FROM native_report_revisions WHERE capture_id = ? ORDER BY revision DESC LIMIT 1", [captureID]).first?["details"]
            .flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(ReportDetails.self, from: $0) }
    }

    public func detailRevisions(captureID: String) throws -> [(revision: Int, source: String, details: ReportDetails)] {
        try rows("SELECT * FROM native_report_revisions WHERE capture_id = ? ORDER BY revision", [captureID]).compactMap { row in
            guard let data = row["details"]?.data(using: .utf8), let details = try? JSONDecoder().decode(ReportDetails.self, from: data) else { return nil }
            return (Int(row["revision"]!)!, row["source"]!, details)
        }
    }

    // MARK: Recent reports

    /// Newest first, from persisted rows only. Triage comes from the stored observations through the shared rules.
    public func reportSummaries(limit: Int = 20) throws -> [ReportSummary] {
        try rows("SELECT * FROM native_captures ORDER BY local_id DESC LIMIT ?", [String(max(1, min(limit, 200)))]).map { row in
            let id = row["id"]!
            let processing = try self.processing(id: id).flatMap { try? JSONDecoder().decode(NativeProcessing.self, from: $0) }
            let record = try deliveryRecord(captureID: id)
            let delivered = try rows("SELECT 1 FROM native_receipts WHERE capture_id = ?", [id]).first != nil
            return ReportSummary(id: id, createdAt: row["created_at"]!, transcript: try currentTranscript(captureID: id),
                hasAudio: row["audio_path"] != nil, provisional: processing.flatMap { TriageRules.assess($0.observations) },
                delivery: delivered ? .delivered : (record?.state ?? .localSaved), held: record?.held ?? false, details: try currentDetails(captureID: id))
        }
    }
}
