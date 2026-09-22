import Foundation
import Security

/// A short id for this install ("Ryc#j0"), generated once and kept in the
/// Keychain. It is sent with every price lookup so the pricing proxy can tell
/// one person's installs apart: enough to see who is spending provider credits,
/// cap a heavy user, or cut one off without rotating the token everyone shares.
///
/// It identifies an *install*, not a person: no name, no email, no device
/// fingerprint, nothing derived from the hardware. It is never attached to the
/// cellar itself — wines, bottles and notes never leave the phone at all.
///
/// Keychain rather than UserDefaults on purpose: Keychain items outlive an app
/// delete, so a reinstall keeps the same id and stays on the proxy's roster.
enum DeviceIdentity {
    private static let service = "com.doony.cellar.valuation"
    private static let account = "device-id"

    /// Unambiguous when read aloud or copied off a screen: no O/0, I/l/1 mix-ups.
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")

    /// This install's id, minted on first use. ~656 million possibilities, which
    /// is plenty to keep a handful of friends distinct.
    static var current: String {
        if let existing = load(), isValid(existing) { return existing }
        let fresh = make()
        save(fresh)
        return fresh
    }

    /// "Ryc#j0" — three characters, a hash, two more.
    static func make(randomCharacter: () -> Character = { alphabet.randomElement()! }) -> String {
        let head = String((0..<3).map { _ in randomCharacter() })
        let tail = String((0..<2).map { _ in randomCharacter() })
        return "\(head)#\(tail)"
    }

    /// The shape the proxy accepts: short, printable, safe in a header and a log.
    static func isValid(_ id: String) -> Bool {
        guard id.count >= 4, id.count <= 32 else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "#" || $0 == "_" || $0 == "-" }
    }

    // MARK: Keychain

    @discardableResult
    static func save(_ id: String) -> Bool {
        guard let data = id.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
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
}
