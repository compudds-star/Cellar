import Foundation
import Security

/// The caps the pricing server is enforcing.
struct ProxyLimits: Codable, Equatable {
    /// Billable lookups one device may make per day / per calendar month.
    var daily: Int
    var monthly: Int
    /// The ceiling across every device together — what actually bounds the bill
    /// when the server runs open, since a new device id would otherwise start a
    /// fresh allowance.
    var globalMonthly: Int
}

/// What the server is enforcing right now, plus how much of it has been used.
struct ProxyStatus: Codable, Equatable {
    struct Usage: Codable, Equatable {
        var month: String
        var count: Int
        var limit: Int
    }
    var limits: ProxyLimits
    var global: Usage
    var devices: Int?

    /// "412 of 1,500 lookups this month, across 6 devices"
    var summary: String {
        let used = global.count.formatted()
        let ceiling = global.limit > 0 ? global.limit.formatted() : "unlimited"
        let count = devices ?? 0
        return "\(used) of \(ceiling) lookups this month, across \(count) device\(count == 1 ? "" : "s")."
    }
}

/// Reads and changes the pricing server's caps from the owner's phone — the one
/// install holding the admin token. Everyone else's app never sees these calls.
enum ProxyAdmin {
    static func status() async throws -> ProxyStatus {
        try await send(method: "GET", body: nil)
    }

    /// Sends only the fields given, so raising the per-device cap leaves the
    /// service ceiling alone and vice versa.
    static func update(monthlyPerDevice: Int? = nil, serviceMonthly: Int? = nil) async throws -> ProxyStatus {
        var payload: [String: Int] = [:]
        if let monthlyPerDevice { payload["monthlyLimit"] = monthlyPerDevice }
        if let serviceMonthly { payload["globalMonthlyLimit"] = serviceMonthly }
        guard !payload.isEmpty else { return try await status() }
        return try await send(method: "PATCH", body: try JSONEncoder().encode(payload))
    }

    private static func send(method: String, body: Data?) async throws -> ProxyStatus {
        guard let base = ValuationSettings.baseURL else { throw ValuationError.notConfigured }
        guard ValuationConfig.isAcceptableEndpoint(base) else { throw ValuationError.insecureEndpoint }
        guard let token = AdminTokenStore.load(), !token.isEmpty else { throw ValuationError.notConfigured }

        var request = URLRequest(url: base.appendingPathComponent("admin/limits"))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ValuationError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ValuationError.http(http.statusCode)
        }
        return try JSONDecoder().decode(ProxyStatus.self, from: data)
    }
}

/// The admin credential, kept apart from the pricing token because it can change
/// what the server charges everyone. Only the owner's phone ever holds one, and
/// it is typed in by hand — it is never in the bundle and never in an invite.
enum AdminTokenStore {
    private static let service = "com.doony.cellar.valuation"
    private static let account = "admin-token"

    @discardableResult
    static func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return delete() }
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
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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

    static var hasToken: Bool { load() != nil }
}
