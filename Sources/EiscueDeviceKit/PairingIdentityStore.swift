import Foundation
import Security

/// The host owns this store. Never log its returned data or persist it without protection.
public protocol PairingIdentityStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func remove() throws
}

/// Private, non-synchronizing Keychain item, excluded from device migration.
public struct KeychainPairingIdentityStore: PairingIdentityStore {
    public let service: String
    public let account: String
    public init(service: String = "org.eiscue.device.pairing", account: String = "remote-identity") {
        self.service = service; self.account = account
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    public func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw DeviceControlError.keychain(status) }
        return data
    }
    public func save(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw DeviceControlError.keychain(added) }
        } else if status != errSecSuccess { throw DeviceControlError.keychain(status) }
    }
    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceControlError.keychain(status) }
    }
}
