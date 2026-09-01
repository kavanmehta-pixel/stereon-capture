import Foundation
import Security

/// Pairing state for a deployment: server, access key, operator. Every value
/// is optional — anything unset resolves to the compile-time StereonConfig,
/// so a pilot phone with zero setup behaves exactly as it always has.
enum StereonSettings {
    // MARK: - Stored values

    private static let serverURLKey = "stereon.serverURL"
    private static let operatorNameKey = "stereon.operatorName"

    static var serverURLString: String? {
        get { UserDefaults.standard.string(forKey: serverURLKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        set { store(newValue, forKey: serverURLKey) }
    }

    static var operatorName: String? {
        get { UserDefaults.standard.string(forKey: operatorNameKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        set { store(newValue, forKey: operatorNameKey) }
    }

    private static func store(_ value: String?, forKey key: String) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let trimmed {
            UserDefaults.standard.set(trimmed, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Access key (Keychain)

    // The key never touches UserDefaults — one leaked key already forced a
    // rotation. Every Keychain call is best-effort: a refusal means the key
    // just isn't remembered, never a crash mid-load.
    private static let keychainService = "com.stereon.capture"
    private static let keychainAccount = "access-key"

    static var accessKey: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data,
                  let key = String(data: data, encoding: .utf8) else { return nil }
            return key.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
            ]
            SecItemDelete(base as CFDictionary)
            guard let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                  let data = value.data(using: .utf8) else { return }
            var add = base
            add[kSecValueData as String] = data
            // The outbox flushes in the background — the key must be readable
            // after first unlock, but never off this device.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: - Resolved values

    static var resolvedBaseURL: URL {
        serverURLString.flatMap(parseServerURL) ?? StereonConfig.baseURL
    }

    static var resolvedAccessKey: String {
        accessKey ?? StereonConfig.accessKey
    }

    /// Empty settings keep the historical literal, so server-side records that
    /// filter on "capture-app" stay coherent across the pilot fleet.
    static var resolvedOperatorName: String {
        operatorName ?? "capture-app"
    }

    /// One parse shared by save and test, so what tested is what gets used.
    /// A bare host gets https; anything without a host is rejected.
    static func parseServerURL(_ string: String) -> URL? {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()),
              url.host()?.isEmpty == false else { return nil }
        return url
    }

    // MARK: - Connection test

    enum ConnectionTest: Equatable {
        case reachable(itemCount: Int?)
        case unauthorised(statusCode: Int)
        case unreachable(String)
    }

    /// Probes /api/library-lite with the values as entered — not the saved
    /// ones — so the operator learns whether *these* fields work before saving.
    /// Blank fields fall back exactly the way the resolved values do.
    static func testConnection(urlString: String, accessKey enteredKey: String) async -> ConnectionTest {
        let base: URL
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty {
            base = StereonConfig.baseURL
        } else if let parsed = parseServerURL(trimmedURL) {
            base = parsed
        } else {
            return .unreachable("Not a valid server URL")
        }
        let key = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? StereonConfig.accessKey

        var request = URLRequest(url: base.appendingPathComponent("api/library-lite"))
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "x-access-key")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return .unreachable("No response from server")
        }
        switch http.statusCode {
        case 200..<300:
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return .reachable(itemCount: (json?["items"] as? [Any])?.count)
        case 401, 403:
            return .unauthorised(statusCode: http.statusCode)
        default:
            return .unreachable("Server returned \(http.statusCode)")
        }
    }
}
