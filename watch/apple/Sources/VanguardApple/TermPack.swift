import Foundation

/// Offline terminology retrieval, a Swift port of `hub/rag/knowledge.js`. The pack
/// (`Resources/medical_terms.json`) is a byte-for-byte copy of the hub's and is an UNREVIEWED DRAFT: it
/// translates vocabulary only and never carries urgency. `docs/fixtures/intake-parity-v1.json` is generated
/// from the hub implementation and `IntakeParityTests` must match it exactly.
public struct TermMatch: Equatable, Sendable {
    public let id: String
    public let matched: String
    public let filipino: String
    public let english: String
    public let medicalTerm: String
    public let category: String
    /// A denial word ("no", "walang", "hindi") directly precedes the phrase.
    public let negated: Bool
}

public struct TermPack: Sendable {
    struct Entry: Decodable, Sendable {
        let id: String, phrases: [String], filipino: String, english: String, medicalTerm: String, category: String
    }
    private struct File: Decodable { let packId: String, packVersion: String, reviewStatus: String, entries: [Entry] }

    public let packID: String
    public let packVersion: String
    public let reviewStatus: String
    let entries: [Entry]
    private let tokenIndex: [String: [Int]]   // token -> entry indexes, for candidate lookup

    /// Everyday Tagalog particles and pronouns that may sit between the words of a phrase (at most one per gap).
    static let fillers = ["siya", "siyang", "niya", "yung", "yong", "ang", "ng", "na", "po", "ay", "sa", "ko", "mo", "ka", "kasi", "raw", "daw", "din", "rin",
                          "nga", "lang", "naman", "pa", "at", "ni", "kay", "yata", "ba", "pala", "muna", "eh"]
    static let gap = "(?: (?:\(fillers.joined(separator: "|"))))?"

    /// Where a normalized phrase occurs in a padded, normalized text: leading space to trailing space, like the hub.
    /// "ang" also matches its spoken forms "yung"/"yong".
    static func locate(_ padded: NSString, _ phrase: String) -> NSRange? {
        let words = phrase.split(separator: " ").map { $0 == "ang" ? "(?:ang|yung|yong)" : NSRegularExpression.escapedPattern(for: String($0)) }
        guard let regex = try? NSRegularExpression(pattern: " " + words.joined(separator: gap + " ") + " ") else { return nil }
        let match = regex.firstMatch(in: padded as String, range: NSRange(location: 0, length: padded.length))
        return match?.range
    }

    static let negators: Set<String> = ["no", "not", "without", "denies", "denied", "never", "wala", "walang", "hindi", "di", "hindi po", "walang po"]
    static let maxQueryTokens = 200

    public init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard ["unreviewed-draft", "clinician-reviewed"].contains(file.reviewStatus), !file.entries.isEmpty else { throw NativeStoreFailure.unavailable }
        packID = file.packId; packVersion = file.packVersion; reviewStatus = file.reviewStatus
        entries = file.entries.map { Entry(id: $0.id, phrases: $0.phrases.map(Self.normalize), filipino: $0.filipino, english: $0.english,
                                           medicalTerm: $0.medicalTerm, category: $0.category) }
        var index: [String: [Int]] = [:]
        for (i, entry) in entries.enumerated() { for phrase in Set(entry.phrases.flatMap { $0.split(separator: " ").map(String.init) }) { index[phrase, default: []].append(i) } }
        tokenIndex = index
    }

    /// The pack that ships inside the app.
    public static func bundled() throws -> TermPack {
        guard let url = Bundle.module.url(forResource: "medical_terms", withExtension: "json") else { throw NativeStoreFailure.unavailable }
        return try TermPack(data: Data(contentsOf: url))
    }

    /// Same steps as `normalize` in knowledge.js: NFKC, NFD, strip accents, lowercase, collapse non-letters/digits.
    public static func normalize(_ text: String) -> String {
        let stripped = String(String.UnicodeScalarView(text.precomposedStringWithCompatibilityMapping.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !(0x300...0x36F).contains($0.value) }))
        let lower = stripped.lowercased()
        return lower.replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Whole-phrase matches, longest first; a phrase inside a longer matched phrase is not reported separately.
    public func retrieve(_ text: String, limit: Int = 5) -> [TermMatch] {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return [] }
        var seenTokens = Set<String>(), query: [String] = []
        for token in normalized.split(separator: " ").map(String.init) where seenTokens.insert(token).inserted { query.append(token) }
        let queryTokens = Set(query.prefix(Self.maxQueryTokens))
        let padded = " \(normalized) " as NSString
        // Candidates are entries sharing a token with the text, visited in pack order (as the hub's FTS rowids are).
        let candidates = Set(queryTokens.flatMap { tokenIndex[$0] ?? [] }).sorted()
        var best: [(index: Int, phrase: String)] = []
        for i in candidates {
            var chosen: String?
            for phrase in entries[i].phrases where phrase.split(separator: " ").contains(where: { queryTokens.contains(String($0)) })
                && Self.locate(padded, phrase) != nil {
                if chosen == nil || phrase.utf16.count > chosen!.utf16.count { chosen = phrase }
            }
            if let chosen { best.append((i, chosen)) }
        }
        let ordered = best.sorted { a, b in
            a.phrase.utf16.count != b.phrase.utf16.count ? a.phrase.utf16.count > b.phrase.utf16.count : entries[a.index].id < entries[b.index].id
        }
        var accepted: [(entry: Entry, phrase: String, start: Int, end: Int)] = []
        for item in ordered {
            guard let span = Self.locate(padded, item.phrase) else { continue }
            let start = span.location, end = span.location + span.length
            if accepted.contains(where: { start >= $0.start && end <= $0.end && ($0.end - $0.start) > (end - start) }) { continue }
            accepted.append((entries[item.index], item.phrase, start, end))
        }
        return accepted.prefix(max(0, min(limit, 20))).map { item in
            let before = padded.substring(to: item.start).trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            let firstWord = item.phrase.split(separator: " ").first.map(String.init) ?? ""
            return TermMatch(id: item.entry.id, matched: item.phrase, filipino: item.entry.filipino, english: item.entry.english,
                             medicalTerm: item.entry.medicalTerm, category: item.entry.category,
                             negated: Self.negators.contains(before) && !Self.negators.contains(firstWord))
        }
    }
}
