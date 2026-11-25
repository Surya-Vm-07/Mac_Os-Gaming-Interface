import Foundation
import Security

/// API keys live in the login Keychain, never in UserDefaults or plain files.
public enum SecretStore {
    public static let steamGridDBService = "com.aether.steamgriddb"
    static let account = "api-key"

    /// SteamGridDB key. The `STEAMGRIDDB_API_KEY` environment variable wins (handy in development),
    /// then the Keychain.
    public static func steamGridDBAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let fromEnvironment = environment["STEAMGRIDDB_API_KEY"], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        return read(service: steamGridDBService)
    }

    public static func read(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces any existing value. Returns the `OSStatus` of the add (`errSecSuccess` on success).
    @discardableResult
    public static func write(_ value: String, service: String) -> OSStatus {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(identity as CFDictionary)
        var attributes = identity
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrLabel as String] = "Aether – \(service)"
        return SecItemAdd(attributes as CFDictionary, nil)
    }
}
