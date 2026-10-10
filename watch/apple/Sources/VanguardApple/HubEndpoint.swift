import Foundation
import Security

public enum HubFailure: Error { case invalidURL, loopbackOnDevice, missingCredential, invalidReceipt, enrollmentRejected }

/// LAN configuration has no relationship to the on-device inference engine.
public struct HubEndpoint: Sendable {
    public let url: URL
    public init(_ value: String, allowLoopback: Bool = false) throws {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
            ["http", "https"].contains(url.scheme), let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            url.path.isEmpty || url.path == "/", url.port.map({ $0 > 0 && $0 <= 65535 }) ?? true,
            !["0.0.0.0", "::"].contains(host) else { throw HubFailure.invalidURL }
        if !allowLoopback && (host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")) {
            throw HubFailure.loopbackOnDevice
        }
        self.url = url
    }
    public func request(path: String, token: String, requestID: String) throws -> URLRequest {
        guard path.hasPrefix("api/"), !path.contains("..") else { throw HubFailure.invalidURL }
        var request = URLRequest(url: url.appendingPathComponent(path))
        request.timeoutInterval = 8
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue(requestID, forHTTPHeaderField: "X-Request-ID")
        return request
    }
}

public enum HubCredential {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ph.vanguard.hub", kSecAttrAccount as String: "access-token"] }
    public static func read() -> String {
        var request = query; request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    public static func save(_ value: String) throws {
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item.merge(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw HubFailure.missingCredential }
        } else if status != errSecSuccess { throw HubFailure.missingCredential }
    }
}

public enum HubEnrollment {
    private struct Reply: Decodable { let ok: Bool; let token: String?; let error: String? }

    /// Redeems a short-lived operator-issued code. The permanent token is returned only to this client and is
    /// saved by the caller in Keychain; it is never displayed by the hub dashboard.
    public static func redeem(code: String, watchID: String, at endpoint: HubEndpoint, session: URLSession = .shared) async throws -> String {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.range(of: "^[A-F0-9]{16}$", options: .regularExpression) != nil,
              watchID.range(of: "^(APPLE-WATCH|IPHONE)-[A-Za-z0-9-]{1,52}$", options: .regularExpression) != nil else {
            throw HubFailure.enrollmentRejected
        }
        var request = try endpoint.request(path: "api/enrollment/redeem", token: "", requestID: UUID().uuidString.lowercased())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": value, "watchId": watchID])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.ok,
              let token = reply.token, token.utf8.count >= 32 else { throw HubFailure.enrollmentRejected }
        return token
    }
}
