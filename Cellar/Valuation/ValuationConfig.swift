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

    /// A setup link — `cellar://configure?endpoint=…&token=…` — so handing the app
    /// to someone is "tap this link", not "type a URL and a token into Settings".
    /// Parsing only: nothing is stored until the person confirms the prompt, because
    /// a link can come from anywhere and it decides where wine queries are sent.
    struct Invite: Equatable {
        var endpoint: URL
        var token: String?

        /// Host shown in the confirmation prompt.
        var host: String { endpoint.host ?? endpoint.absoluteString }

        /// The link that sets a friend's app up. The token rides in it, so it is as
        /// sensitive as the token itself — see `InviteFriendView` for the warning
        /// the sharing screen shows.
        var url: URL? {
            var comps = URLComponents()
            comps.scheme = "cellar"
            comps.host = "configure"
            var items = [URLQueryItem(name: "endpoint", value: endpoint.absoluteString)]
            if let token, !token.isEmpty {
                items.append(URLQueryItem(name: "token", value: token))
            }
            comps.queryItems = items
            return comps.url
        }
    }

    /// Nil unless the link is a `configure` link carrying an endpoint the app would
    /// accept anyway (HTTPS, or plain HTTP on a local network).
    static func invite(from url: URL) -> Invite? {
        guard url.scheme?.lowercased() == "cellar",
              (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                  .lowercased() == "configure",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let raw = value("endpoint"), !raw.isEmpty,
              let endpoint = URL(string: raw),
              isAcceptableEndpoint(endpoint) else { return nil }
        let token = value("token")
        return Invite(endpoint: endpoint, token: (token?.isEmpty ?? true) ? nil : token)
    }

    /// Applies a confirmed invite: endpoint to UserDefaults, token to the Keychain.
    static func apply(_ invite: Invite) {
        ValuationSettings.baseURL = invite.endpoint
        if let token = invite.token { APIKeyStore.save(token) }
    }

    /// What this device can hand to a friend: its own endpoint, and its token if
    /// it has one. Nil when no pricing server is set up, so there is nothing to share.
    static var shareableInvite: Invite? {
        guard let endpoint = ValuationSettings.baseURL else { return nil }
        return Invite(endpoint: endpoint, token: APIKeyStore.load())
    }

    /// Configured enough to attempt a lookup (endpoint present and acceptable).
    var isConfigured: Bool {
        guard let baseURL else { return false }
        return ValuationConfig.isAcceptableEndpoint(baseURL)
    }

    /// HTTPS is required for real hosts. Plain HTTP is allowed ONLY for a local
    /// dev proxy so you can test against the proxy on your Mac before it's behind
    /// TLS: localhost / 127.0.0.1 (simulator), or *.local / a private LAN IPv4
    /// address (a physical iPhone reaching the Mac over Wi-Fi). Info.plist's
    /// NSAllowsLocalNetworking permits cleartext to local names; ATS doesn't
    /// apply to IP literals.
    static func isAcceptableEndpoint(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            guard let host = url.host?.lowercased() else { return false }
            return host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
                || isPrivateIPv4(host)
        default:
            return false
        }
    }

    /// 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16.
    static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        default: return false
        }
    }
}

/// Non-secret settings.
enum ValuationSettings {
    private static let baseURLKey = "valuation.baseURL"

    /// Baked into the build so a new install already knows where to look up prices.
    /// The endpoint is NOT a secret — the access token is, and it is never in here:
    /// it reaches a phone through Settings or a `cellar://configure` link and lives
    /// in the Keychain. Leave empty to ship with online pricing off.
    static let bundledBaseURL = "https://cellar.orangeeaglesa.com"

    /// The endpoint in use. Never set → the bundled default; set to empty →
    /// deliberately off, which is how someone turns pricing off for good.
    static var baseURL: URL? {
        get {
            guard let s = UserDefaults.standard.string(forKey: baseURLKey) else {
                return URL(string: bundledBaseURL)
            }
            return s.isEmpty ? nil : URL(string: s)
        }
        set { UserDefaults.standard.set(newValue?.absoluteString ?? "", forKey: baseURLKey) }
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
