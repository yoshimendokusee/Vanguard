import XCTest
@testable import VanguardApple

final class AppConfigurationTests: XCTestCase {
    private let hub: [String: Any] = ["HUB_URL": "http://192.168.8.10:3000"]

    private func syntheticJWT(role: String) -> String {
        let claims = Data("{\"role\":\"\(role)\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(claims).sig"
    }

    func testHubOnlyConfigurationKeepsCloudOff() throws {
        for extra: [String: Any] in [
            [:],
            ["SUPABASE_URL": "$(SUPABASE_URL)", "SUPABASE_PUBLISHABLE_KEY": "$(SUPABASE_PUBLISHABLE_KEY)"],
            ["SUPABASE_URL": "https://<project-ref>.supabase.co", "SUPABASE_PUBLISHABLE_KEY": "<publishable-key>"],
            ["SUPABASE_URL": "https://example.supabase.co"],
        ] {
            let config = try AppConfiguration.load(info: hub.merging(extra) { $1 })
            XCTAssertEqual(config.hubURL, URL(string: "http://192.168.8.10:3000"))
            XCTAssertNil(config.supabase)
            XCTAssertEqual(config.cloudDisabledReason, "Cloud sync is not configured")
        }
    }

    func testPublishableKeyEnablesOptionalCloudAccess() throws {
        for key in ["sb_publishable_synthetic", syntheticJWT(role: "anon")] {
            let config = try AppConfiguration.load(info: hub.merging([
                "SUPABASE_URL": " https://example.supabase.co ", "SUPABASE_PUBLISHABLE_KEY": key,
            ]) { $1 })
            XCTAssertEqual(config.supabase?.url, URL(string: "https://example.supabase.co"))
            XCTAssertEqual(config.supabase?.publishableKey, key)
            XCTAssertNil(config.cloudDisabledReason)
        }
    }

    func testSecretKeysAndInsecureURLsNeverEnableCloudAccess() throws {
        for key in ["sb_secret_synthetic", syntheticJWT(role: "service_role")] {
            let config = try AppConfiguration.load(info: hub.merging([
                "SUPABASE_URL": "https://example.supabase.co", "SUPABASE_PUBLISHABLE_KEY": key,
            ]) { $1 })
            XCTAssertNil(config.supabase)
            XCTAssertEqual(config.cloudDisabledReason,
                "SUPABASE_PUBLISHABLE_KEY must be a publishable/anon key, not a secret key")
        }
        let insecure = try AppConfiguration.load(info: hub.merging([
            "SUPABASE_URL": "http://example.supabase.co", "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_synthetic",
        ]) { $1 })
        XCTAssertNil(insecure.supabase)
        XCTAssertEqual(insecure.cloudDisabledReason, "SUPABASE_URL must use HTTPS")
    }

    func testMissingUnresolvedOrInvalidHubURLFailsClearly() {
        for info: [String: Any] in [[:], ["HUB_URL": "$(HUB_URL)"], ["HUB_URL": "http://<hub-lan-ip>:3000"], ["HUB_URL": "  "]] {
            XCTAssertThrowsError(try AppConfiguration.load(info: info)) {
                XCTAssertEqual($0 as? AppConfigurationError, .missingHubURL)
            }
        }
        for url in ["192.168.8.10:3000", "ftp://192.168.8.10", "http://"] {
            XCTAssertThrowsError(try AppConfiguration.load(info: ["HUB_URL": url])) {
                XCTAssertEqual($0 as? AppConfigurationError, .invalidHubURL)
            }
        }
    }
}
