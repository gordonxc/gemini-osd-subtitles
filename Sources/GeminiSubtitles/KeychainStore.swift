import Foundation
import Security

/// Thin wrapper around the macOS Keychain Services API for storing the
/// user's Gemini API key. Uses `kSecAttrAccessibleWhenUnlocked` so the key
/// can only be read while the user is logged in and the keychain unlocked.
enum KeychainStore {
    private static let service = "com.gemini-subtitles.apikey"
    private static let account = "default"

    enum KeychainError: Error, LocalizedError {
        case osStatus(OSStatus, String)
        case unexpectedData

        var errorDescription: String? {
            switch self {
            case .osStatus(let status, let context):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain \(context) failed: \(msg) (\(status))"
            case .unexpectedData:
                return "Keychain returned unexpected data"
            }
        }
    }

    static func getAPIKey() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    static func setAPIKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else { return }
        // Try to update first; if not present, add.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributesToUpdate: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw KeychainError.osStatus(addStatus, "add")
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.osStatus(updateStatus, "update")
        }
    }

    static func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.osStatus(status, "delete")
        }
    }
}
