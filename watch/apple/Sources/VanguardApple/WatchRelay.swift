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
    public func offer(_ original: NativeCapture) async throws {
        let capture = try await workflow.fallbackCapture(original)
        guard session.activationState == .activated else { throw NativeStoreFailure.unavailable }
        let data = try JSONEncoder().encode(capture)
        if let path = capture.audioPath {
            session.transferFile(URL(fileURLWithPath: path), metadata: ["vanguardCapture": data])
        } else { session.transferUserInfo(["vanguardCapture": data]) }
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
            let capture = NativeCapture(id: source.id, watchID: source.watchID, createdAt: source.createdAt, transcript: nil, audioPath: destination.path, encounterID: source.encounterID)
            Task {
                do {
                    try await workflow.store.saveFallback(capture)
                    let processing = try await workflow.processAudio(capture)
                    session.transferUserInfo(["vanguardResult": try JSONEncoder().encode(processing), "captureID": capture.id])
                    onResult?(capture.id)
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

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let data = userInfo["vanguardCapture"] as? Data, data.count <= 100_000 {
            Task {
                do {
                    let capture = try JSONDecoder().decode(NativeCapture.self, from: data)
                    // Incoming text jobs cannot supply an arbitrary local audio path.
                    guard capture.audioPath == nil, capture.transcript != nil else { throw NativeStoreFailure.invalidCapture }
                    let stored = try await workflow.store.saveFallback(capture)
                    #if os(iOS)
                    let processing = try await workflow.process(stored, device: .iphone)
                    session.transferUserInfo(["vanguardResult": try JSONEncoder().encode(processing), "captureID": capture.id])
                    onResult?(capture.id)
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
