import Foundation

public struct LocalTranscript: Sendable {
    public let originalText: String
    public let segmentConfidences: [Float]
    public let engine: String
    public let runtime: String
}
