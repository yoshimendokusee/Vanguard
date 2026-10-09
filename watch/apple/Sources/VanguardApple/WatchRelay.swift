#if os(iOS) || os(watchOS)
import Foundation
import WatchConnectivity

/// Watch Connectivity is an optional durable relay; its receipt is not hospital delivery.
public final class WatchRelay: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let workflow: NativeWorkflow
    private let session: WCSession
    public var onChange: (@Sendable (String) -> Void)?
    /// Fired with the capture ID when a paired device's result has been durably stored here.
    public var onResult: (@Sendable (String) -> Void)?
    public init(workflow: NativeWorkflow) {
        self.workflow = workflow; session = WCSession.default
        super.init()
        if WCSession.isSupported() { session.delegate = self; session.activate() }
    }
    public func offer(_ capture: NativeCapture) async throws {
        guard session.activationState == .activated else { throw NativeStoreFailure.unavailable }
        try await workflow.store.ensureDelivery(captureID: capture.id)
        let encounter = try await workflow.store.deliveryRecord(captureID: capture.id)!.encounterID
        let data = try JSONEncoder().encode(capture)
        if let path = capture.audioPath {
            session.transferFile(URL(fileURLWithPath: path), metadata: ["vanguardCapture": data, "encounterID": encounter])
        } else { session.transferUserInfo(["vanguardCapture": data, "encounterID": encounter]) }
    }
    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated { retry() }
        if let error { onChange?("Watch relay activation failed: \(error.localizedDescription)") }
    }
    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
    public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        #if os(iOS)
        do {
            guard let data = file.metadata?["vanguardCapture"] as? Data, data.count <= 100_000,
                let size = try file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 20_000_000 else { throw NativeStoreFailure.invalidCapture }
            let source = try JSONDecoder().decode(NativeCapture.self, from: data)
            guard UUID(uuidString: source.id) != nil, source.id == source.id.lowercased(), source.transcript == nil else { throw NativeStoreFailure.invalidCapture }
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WatchAudio")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Keep the sender's container (caf from the Watch recorder, m4a from older builds).
            let ext = URL(fileURLWithPath: source.audioPath ?? "").pathExtension
            let destination = directory.appendingPathComponent(source.id + "." + (["caf", "m4a", "wav"].contains(ext) ? ext : "caf"))
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: destination) == Data(contentsOf: file.fileURL) else { throw NativeStoreFailure.identityConflict }
            } else { try FileManager.default.copyItem(at: file.fileURL, to: destination) }
            let capture = NativeCapture(id: source.id, watchID: source.watchID, createdAt: source.createdAt, transcript: nil, audioPath: destination.path)
            Task {
                do {
                    try await workflow.store.save(capture)
                    try await workflow.store.ensureDelivery(captureID: capture.id, encounterID: file.metadata?["encounterID"] as? String)
                    let processing = try await workflow.processAudio(capture)
                    session.transferUserInfo(["vanguardResult": try JSONEncoder().encode(processing), "captureID": capture.id])
                    onChange?("Watch audio and original speech preserved; iPhone result queued")
                } catch { onChange?("Watch audio retained; offline speech/model processing pending") }
            }
        } catch { onChange?("Watch audio transfer rejected; sender must retain pending capture") }
        #endif
    }

    public func retry() {
        guard session.activationState == .activated else { return }
        Task {
            do {
                #if os(watchOS)
                for capture in try await workflow.store.captures(pendingOnly: true) { try await offer(capture) }
                #else
                for capture in try await workflow.store.captures() where capture.watchID.hasPrefix("APPLE-WATCH-") {
                    if let processing = try await workflow.store.processing(id: capture.id) {
                        session.transferUserInfo(["vanguardResult": processing, "captureID": capture.id])
                    }
                }
                #endif
            } catch { onChange?("Fallback retry deferred; pending inputs retained") }
        }
    }

    /// Completed reports use their original extraction and encounter; the iPhone never runs Qwen again.
    public func relayPendingReports() async throws {
        guard session.activationState == .activated else { throw NativeStoreFailure.unavailable }
        #if os(watchOS)
        let pending = try await workflow.store.deliverable().map { $0["id"]! }
        let corrections = try await workflow.store.correctionsToSend().map(\.captureID)
        for id in Set(pending + corrections).sorted().prefix(100) {
            let report = try await workflow.relayReport(id: id)
            let data = try JSONEncoder().encode(report)
            guard data.count <= 900 * 1024 else { throw NativeStoreFailure.invalidCapture }
            if !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo["reportID"] as? String == report.capture.id }) {
                session.transferUserInfo(["vanguardReport": data, "reportID": report.capture.id])
            }
        }
        #else
        for capture in try await workflow.store.captures() where capture.watchID.hasPrefix("APPLE-WATCH-") {
            guard let delivery = try await workflow.store.deliveryRecord(captureID: capture.id), delivery.state == .delivered else { continue }
            if !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo["vanguardReceipt"] as? String == capture.id }) {
                session.transferUserInfo(["vanguardReceipt": capture.id, "watchID": capture.watchID,
                    "createdAt": capture.createdAt, "encounterID": delivery.encounterID,
                    "correctionReceipts": try await workflow.store.transcriptVersions(captureID: capture.id).filter { $0.version > 0 && $0.sentAt != nil }.map(\.requestID)])
            }
        }
        #endif
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let data = userInfo["vanguardReport"] as? Data, data.count <= 900 * 1024 {
            #if os(iOS)
            Task {
                do {
                    let report = try JSONDecoder().decode(RelayedReport.self, from: data)
                    try await workflow.acceptRelay(report)
                    onChange?("Watch report persisted on iPhone; hospital acknowledgment pending")
                } catch { onChange?("Watch report relay refused; original retained on Watch") }
            }
            #endif
        } else if let id = userInfo["vanguardReceipt"] as? String,
                  let watchID = userInfo["watchID"] as? String, let createdAt = userInfo["createdAt"] as? String,
                  let encounter = userInfo["encounterID"] as? String {
            #if os(watchOS)
            Task {
                do {
                    guard let capture = try await workflow.store.captures().first(where: { $0.id == id }),
                          capture.watchID == watchID, capture.createdAt == createdAt,
                          try await workflow.store.deliveryRecord(captureID: id)?.encounterID == encounter else { throw NativeStoreFailure.identityConflict }
                    try await workflow.store.acknowledge(ids: [id])
                    let receipts = userInfo["correctionReceipts"] as? [String] ?? []
                    for version in try await workflow.store.transcriptVersions(captureID: id) where version.version > 0 && receipts.contains(version.requestID) {
                        try await workflow.store.markCorrectionSent(captureID: id, version: version.version)
                    }
                    onResult?(id)
                } catch { onChange?("Relay receipt refused; report retained") }
            }
            #endif
        } else if let data = userInfo["vanguardCapture"] as? Data, data.count <= 100_000 {
            Task {
                do {
                    let capture = try JSONDecoder().decode(NativeCapture.self, from: data)
                    // Incoming text jobs cannot supply an arbitrary local audio path.
                    guard capture.audioPath == nil, capture.transcript != nil else { throw NativeStoreFailure.invalidCapture }
                    try await workflow.store.save(capture)
                    try await workflow.store.ensureDelivery(captureID: capture.id, encounterID: userInfo["encounterID"] as? String)
                    #if os(iOS)
                    let processing = try await workflow.process(capture, device: .iphone)
                    session.transferUserInfo(["vanguardResult": try JSONEncoder().encode(processing), "captureID": capture.id])
                    onChange?("Paired Watch report processed and persisted on iPhone")
                    #endif
                } catch { onChange?("Fallback pending; processing or persistence unavailable") }
            }
        } else if let data = userInfo["vanguardResult"] as? Data, data.count <= 100_000, let id = userInfo["captureID"] as? String {
            Task {
                do {
                    try await workflow.adoptRemote(captureID: id, processingJSON: data)
                    onChange?("iPhone extraction durably received; hospital receipt still pending")
                    onResult?(id)
                } catch { onChange?("Fallback result refused; original and pending work retained") }
            }
        }
    }
}
#endif
