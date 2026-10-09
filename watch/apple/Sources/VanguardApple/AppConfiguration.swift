import Foundation

/// Public, non-secret settings read from the app's Info.plist (filled from
/// `watch/apple/Config/*.xcconfig`). Info.plist ships inside the installed app and
/// can be extracted: never place passwords, `sb_secret_*` or service-role keys here.
public struct AppConfiguration: Sendable, Equatable {
    public enum Key {
        public static let hubURL = "HUB_URL"
        public static let supabaseURL = "SUPABASE_URL"
        public static let supabasePublishableKey = "SUPABASE_PUBLISHABLE_KEY"
    }

    public struct Supabase: Sendable, Equatable {
        public let url: URL
        public let publishableKey: String
    }

    /// Hospital hub on the LAN; reports are sent here (the hub owns Supabase backup).
    public let hubURL: URL
    /// Optional direct Supabase access. nil keeps it off; local capture and LAN
    /// reporting never depend on it.
    public let supabase: Supabase?
    /// Why `supabase` is nil, or nil when it is configured.
    public let cloudDisabledReason: String?
}

public enum AppConfigurationError: Error, Equatable, CustomStringConvertible {
    case missingHubURL
    case invalidHubURL

    public var description: String {
        switch self {
        case .missingHubURL: return "HUB_URL is not set; add it to Secrets.xcconfig and rebuild"
        case .invalidHubURL: return "HUB_URL must be http://<hub-lan-ip>:<port>"
        }
    }
}

extension AppConfiguration {
    public static func load(bundle: Bundle = .main) throws -> AppConfiguration {
        try load(info: bundle.infoDictionary ?? [:])
    }

    public static func load(info: [String: Any]) throws -> AppConfiguration {
        func value(_ key: String) -> String {
            let raw = (info[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // An unresolved $(VAR) (missing xcconfig) or a <placeholder> counts as unset.
            return raw.contains("$(") || raw.contains("<") ? "" : raw
        }

        let hub = value(Key.hubURL)
        guard !hub.isEmpty else { throw AppConfigurationError.missingHubURL }
        guard let hubURL = URL(string: hub),
              ["http", "https"].contains(hubURL.scheme?.lowercased() ?? ""),
              !(hubURL.host ?? "").isEmpty else {
            throw AppConfigurationError.invalidHubURL
        }

        let url = value(Key.supabaseURL)
        let key = value(Key.supabasePublishableKey)
        let reason = cloudConfigurationError(url: url, key: key)
        let supabase = reason == nil ? URL(string: url).map { Supabase(url: $0, publishableKey: key) } : nil
        return AppConfiguration(hubURL: hubURL, supabase: supabase, cloudDisabledReason: reason)
    }

    static func cloudConfigurationError(url: String, key: String) -> String? {
        if url.isEmpty || key.isEmpty { return "Cloud sync is not configured" }
        guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "https",
              !(parsed.host ?? "").isEmpty else {
            return "SUPABASE_URL must use HTTPS"
        }
        if isServerKey(key) {
            return "SUPABASE_PUBLISHABLE_KEY must be a publishable/anon key, not a secret key"
        }
        return nil
    }

    static func isServerKey(_ key: String) -> Bool {
        if key.hasPrefix("sb_secret_") { return true }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return claims["role"] as? String == "service_role"
    }
}
