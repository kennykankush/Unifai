import Foundation
import Security

public protocol CredentialVault {
    func read(accountID: UUID) throws -> String?
    func write(_ credential: String, accountID: UUID) throws
    func delete(accountID: UUID) throws
}

public struct KeychainVault: CredentialVault {
    private let service: String
    public init(service: String = "dev.unifai.account-credentials.v1") { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    public func read(accountID: UUID) throws -> String? {
        var request = query(accountID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let credential = String(data: data, encoding: .utf8) else {
            throw ValidationError.message("The saved credential is unreadable. Replace it in account settings.")
        }
        return credential
    }
    public func write(_ credential: String, accountID: UUID) throws {
        let data = Data(credential.utf8)
        let status = SecItemUpdate(query(accountID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(accountID)
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            request[kSecAttrSynchronizable as String] = false
            try check(SecItemAdd(request as CFDictionary, nil))
        } else { try check(status) }
    }
    public func delete(accountID: UUID) throws {
        let status = SecItemDelete(query(accountID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw ValidationError.message("Keychain operation failed (\(status)). Unlock your login Keychain and try again.")
        }
    }
}

// Used only by tests and the explicitly labelled, network-disabled fixture workspace.
public final class MemoryVault: CredentialVault {
    private var credentials: [UUID: String] = [:]
    public init() {}
    public func read(accountID: UUID) throws -> String? { credentials[accountID] }
    public func write(_ credential: String, accountID: UUID) throws { credentials[accountID] = credential }
    public func delete(accountID: UUID) throws { credentials.removeValue(forKey: accountID) }
}
