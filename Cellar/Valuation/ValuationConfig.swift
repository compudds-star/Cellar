import Foundation
import Security

/// Where the app looks up prices. Two pieces, kept apart on purpose:
///   • `baseURL`  — the endpoint (NOT secret) in UserDefaults.
///   • `apiKey`   — the credential, in the Keychain, never in the bundle/plist/logs.
///
/// Recommended endpoint is a small proxy on your own host that holds the real
/// Wine-Searcher (or Apify) key and caches/rate-limits — then the app can even
/// run with no `apiKey` at all. For personal direct use, point `baseURL` at the
/// provider and store the key here (Keychain).
struct ValuationConfig {
    var baseURL: URL?
    var apiKey: String?

    static var current: ValuationConfig {
        ValuationConfig(baseURL: ValuationSettings.baseURL, apiKey: APIKeyStore.load())
    }

    /// Configured enough to attempt a lookup (endpoint present and acceptable).
    var isConfigured: Bool {
        guard let baseURL else { return false }
        return ValuationConfig.isAcceptableEndpoint(baseURL)
    }

    /// HTTPS is required for real hosts. Plain HTTP is allowed ONLY for a local
    /// dev proxy (localhost / 127.0.0.1 / *.local) so you can test against the
    /// proxy on your Mac before it's behind TLS. Info.plist's
    /// NSAllowsLocalNetworking permits the cleartext connection for those hosts.
    static func isAcceptableEndpoint(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            guard let host = url.host?.lowercased() else { return false }
            return host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
        default:
            return false
        }
    }
}

/// Non-secret settings.
enum ValuationSettings {
    private static let baseURLKey = "valuation.baseURL"

    static var baseURL: URL? {
        get {
            guard let s = UserDefaults.standard.string(forKey: baseURLKey), !s.isEmpty else { return nil }
            return URL(string: s)
        }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: baseURLKey) }
    }
}

/// Minimal Keychain wrapper for the API key. Generic-password item, device-only
/// (`ThisDeviceOnly`), not synced to iCloud. Never printed or logged.
enum APIKeyStore {
    private static let service = "com.doony.cellar.valuation"
    private static let account = "api-key"

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return delete()
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static var hasKey: Bool { load() != nil }
}
