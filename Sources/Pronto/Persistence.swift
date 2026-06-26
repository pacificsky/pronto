import Foundation
import Security

/// Minimal Keychain wrapper for a single stored blob.
enum Keychain {
    private static let service = "blog.pacificsky.pronto"

    static func set(_ value: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Everything secret, stored as one Keychain item so the app prompts at most once.
private struct Secrets: Codable {
    var username = ""
    var password = ""
    var installationId = ""
    var installationKeyRaw = "" // base64
}

/// Public view of stored configuration.
struct StoredConfig {
    var username: String
    var password: String
    var selectedSerial: String?

    var isComplete: Bool { !username.isEmpty && !password.isEmpty }
}

enum Persistence {
    /// Single Keychain account holding all secrets.
    private static let secretsAccount = "lm.secrets"
    /// Legacy per-field accounts from v1 (cleaned up on first run).
    private static let legacyAccounts = ["lm.username", "lm.password", "lm.installationId", "lm.installationKeyRaw"]

    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let selectedSerial = "selectedSerial"
        static let registered = "installationRegistered"
        static let migratedV2 = "secretsConsolidatedV2"
    }

    /// In-memory cache so we read the Keychain only once per launch.
    private static var cache: Secrets = {
        // One-time cleanup of the old multi-item layout (delete needs no prompt).
        if !defaults.bool(forKey: Keys.migratedV2) {
            legacyAccounts.forEach(Keychain.delete)
            defaults.set(true, forKey: Keys.migratedV2)
        }
        if let data = Keychain.get(secretsAccount),
           let decoded = try? JSONDecoder().decode(Secrets.self, from: data) {
            return decoded
        }
        return Secrets()
    }()

    private static func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            Keychain.set(data, account: secretsAccount)
        }
    }

    // MARK: Credentials

    static func loadConfig() -> StoredConfig {
        StoredConfig(
            username: cache.username,
            password: cache.password,
            selectedSerial: defaults.string(forKey: Keys.selectedSerial)
        )
    }

    static func saveCredentials(username: String, password: String) {
        cache.username = username
        cache.password = password
        persist()
    }

    static func saveSelectedSerial(_ serial: String?) {
        defaults.set(serial, forKey: Keys.selectedSerial)
    }

    static func clearAll() {
        cache = Secrets()
        Keychain.delete(secretsAccount)
        legacyAccounts.forEach(Keychain.delete)
        defaults.removeObject(forKey: Keys.selectedSerial)
        defaults.removeObject(forKey: Keys.registered)
    }

    // MARK: Installation key

    /// Load the existing installation identity, or generate + persist a new one.
    static func loadOrCreateInstallationKey() -> InstallationKey {
        if !cache.installationId.isEmpty,
           let raw = Data(base64Encoded: cache.installationKeyRaw),
           let key = InstallationKey(installationId: cache.installationId, privateKeyRaw: raw) {
            return key
        }
        let key = InstallationKey.generate()
        cache.installationId = key.installationId
        cache.installationKeyRaw = key.privateKeyRaw.base64EncodedString()
        persist()
        defaults.set(false, forKey: Keys.registered) // new key needs registration
        return key
    }

    static var isRegistered: Bool {
        get { defaults.bool(forKey: Keys.registered) }
        set { defaults.set(newValue, forKey: Keys.registered) }
    }
}
