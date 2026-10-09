import Foundation
import SQLite3

public struct NativeCapture: Codable, Sendable {
    public let id: String
    public let watchID: String
    public let createdAt: String
    public let transcript: String?
    public let audioPath: String?
    public let localID: Int64?
    public init(id: String = UUID().uuidString.lowercased(), watchID: String, createdAt: String, transcript: String?, audioPath: String? = nil, localID: Int64? = nil) {
        self.id = id; self.watchID = watchID; self.createdAt = createdAt
        self.transcript = transcript; self.audioPath = audioPath; self.localID = localID
    }
}

public enum NativeStoreFailure: Error { case unavailable, invalidCapture, identityConflict, transcriptConflict }

/// Separate native SQLite file; no existing Flutter/hospital database is opened.
public actor NativeStore: FallbackRepository {
    private let db: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }; throw NativeStoreFailure.unavailable
        }
        var initialized = false
        defer { if !initialized { sqlite3_close(handle) } }
        sqlite3_busy_timeout(handle, 5000)
        guard sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;", nil, nil, nil) == SQLITE_OK else {
            throw NativeStoreFailure.unavailable
        }
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &query, nil) == SQLITE_OK,
            sqlite3_step(query) == SQLITE_ROW else { sqlite3_finalize(query); throw NativeStoreFailure.unavailable }
        let version = sqlite3_column_int(query, 0); sqlite3_finalize(query)
        guard version <= 1 else { throw NativeStoreFailure.unavailable }
        let sql = version == 0 ? try String(contentsOf: Bundle.module.url(forResource: "0001_native", withExtension: "sql")!, encoding: .utf8) : "SELECT 1"
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw NativeStoreFailure.unavailable }
        db = handle
        initialized = true
    }
    deinit { sqlite3_close(db) }

    @discardableResult
    private func rows(_ sql: String, _ values: [String?] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw NativeStoreFailure.unavailable }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() {
            let result = value.map { sqlite3_bind_text(statement, Int32(i + 1), $0, Int32($0.utf8.count), Self.transient) } ?? sqlite3_bind_null(statement, Int32(i + 1))
            guard result == SQLITE_OK else { throw NativeStoreFailure.unavailable }
        }
        var output: [[String: String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return output }
            guard status == SQLITE_ROW else { throw NativeStoreFailure.unavailable }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, index) {
                    row[String(cString: sqlite3_column_name(statement, index))] = String(decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
                }
            }
            output.append(row)
        }
    }

    public func capture(watchID: String, transcript: String?, audioPath: String? = nil) throws -> NativeCapture {
        try rows("BEGIN IMMEDIATE")
        do {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let latest = try rows("SELECT MAX(created_at) AS latest FROM native_captures WHERE watch_id = ?", [watchID]).first?["latest"].flatMap(formatter.date)
            let date = max(Date(), latest?.addingTimeInterval(0.001) ?? .distantPast)
            let capture = NativeCapture(watchID: watchID, createdAt: formatter.string(from: date), transcript: transcript, audioPath: audioPath)
            try save(capture)
            try rows("COMMIT")
            return capture
        } catch { try? rows("ROLLBACK"); throw error }
    }

    public func save(_ capture: NativeCapture) throws {
        guard UUID(uuidString: capture.id) != nil, capture.id == capture.id.lowercased(), !capture.watchID.isEmpty, capture.watchID.utf16.count <= 64,
            ISO8601DateFormatter().date(from: capture.createdAt) != nil || Self.date(capture.createdAt) != nil,
            capture.transcript != nil || capture.audioPath != nil,
            capture.transcript.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 16_000 }) ?? true else { throw NativeStoreFailure.invalidCapture }
        if let old = try rows("SELECT * FROM native_captures WHERE id = ?", [capture.id]).first {
            guard old["watch_id"] == capture.watchID, old["created_at"] == capture.createdAt,
                old["transcript"] == capture.transcript, old["audio_path"] == capture.audioPath else { throw NativeStoreFailure.identityConflict }
            return
        }
        try rows("INSERT INTO native_captures (id, watch_id, created_at, transcript, audio_path) VALUES (?, ?, ?, ?, ?)",
            [capture.id, capture.watchID, capture.createdAt, capture.transcript, capture.audioPath])
    }
    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
    public func captures(pendingOnly: Bool = false) throws -> [NativeCapture] {
        let whereSQL = pendingOnly ? " WHERE NOT EXISTS (SELECT 1 FROM native_extractions e WHERE e.capture_id = c.id)" : ""
        return try rows("SELECT c.* FROM native_captures c" + whereSQL + " ORDER BY local_id").map {
            NativeCapture(id: $0["id"]!, watchID: $0["watch_id"]!, createdAt: $0["created_at"]!, transcript: $0["transcript"], audioPath: $0["audio_path"], localID: Int64($0["local_id"]!))
        }
    }
    public func pendingCaptures() throws -> [PendingCapture] {
        try captures(pendingOnly: true).compactMap { capture in
            capture.audioPath.map { PendingCapture(captureID: capture.id, watchID: capture.watchID,
                createdAt: capture.createdAt, audioFile: URL(fileURLWithPath: $0)) }
        }
    }
    public func commitProcessed(capture: PendingCapture, transcript: String, processingJSON: Data) throws {
        try complete(id: capture.captureID, transcript: transcript, processingJSON: processingJSON)
    }
    public func complete(id: String, transcript: String, processingJSON: Data) throws {
        guard let capture = try rows("SELECT * FROM native_captures WHERE id = ?", [id]).first else { throw NativeStoreFailure.invalidCapture }
        if let original = capture["transcript"], original != transcript { throw NativeStoreFailure.transcriptConflict }
        if let speech = try rows("SELECT transcript FROM native_transcriptions WHERE capture_id = ?", [id]).first?["transcript"], speech != transcript { throw NativeStoreFailure.transcriptConflict }
        let processing = try JSONDecoder().decode(NativeProcessing.self, from: processingJSON)
        guard processing.originalTranscript == transcript, processing.isValid, processing.provenance.extraction.execution == "local",
            let json = String(data: try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: processingJSON), options: [.sortedKeys]), encoding: .utf8) else { throw NativeStoreFailure.transcriptConflict }
        if let old = try rows("SELECT transcript, processing FROM native_extractions WHERE capture_id = ?", [id]).first {
            guard old["transcript"] == transcript, old["processing"] == json else { throw NativeStoreFailure.identityConflict }
            return
        }
        try rows("INSERT INTO native_extractions (capture_id, transcript, processing) VALUES (?, ?, ?)", [id, transcript, json])
    }
    public func saveTranscription(id: String, transcript: String, engine: String) throws {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, transcript.utf16.count <= 16_000,
            !engine.isEmpty, engine.utf16.count <= 100 else { throw NativeStoreFailure.invalidCapture }
        if let old = try rows("SELECT transcript, engine FROM native_transcriptions WHERE capture_id = ?", [id]).first {
            guard old["transcript"] == transcript, old["engine"] == engine else { throw NativeStoreFailure.transcriptConflict }
            return
        }
        try rows("INSERT INTO native_transcriptions (capture_id, transcript, engine) VALUES (?, ?, ?)", [id, transcript, engine])
    }
    public func transcription(id: String) throws -> (text: String, engine: String)? {
        guard let row = try rows("SELECT transcript, engine FROM native_transcriptions WHERE capture_id = ?", [id]).first else { return nil }
        return (row["transcript"]!, row["engine"]!)
    }
    public func processing(id: String) throws -> Data? {
        try rows("SELECT processing FROM native_extractions WHERE capture_id = ?", [id]).first?["processing"]?.data(using: .utf8)
    }
    public func outbox() throws -> [[String: String]] {
        try rows("SELECT c.*, e.transcript AS processed_transcript, e.processing FROM native_captures c JOIN native_extractions e ON e.capture_id = c.id WHERE NOT EXISTS (SELECT 1 FROM native_receipts r WHERE r.capture_id = c.id) ORDER BY c.local_id")
    }
    public func acknowledge(ids: [String]) throws {
        for id in ids {
            try rows("INSERT OR IGNORE INTO native_receipts (capture_id, acknowledged_at) SELECT id, ? FROM native_captures WHERE id = ? AND EXISTS (SELECT 1 FROM native_extractions e WHERE e.capture_id = id)", [ISO8601DateFormatter().string(from: Date()), id])
        }
    }
}
