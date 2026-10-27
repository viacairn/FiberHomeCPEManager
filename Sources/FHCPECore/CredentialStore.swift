import Foundation
import LocalAuthentication
import Security

/// Opt-in system Keychain storage. Never stores a decryption key beside a password
/// file, broadens an item's ACL, or invokes an authentication dialog in the background.
public struct CredentialStore: Sendable {
    private let service: String
    private let keychain: any CredentialKeychainClient

    public init(service: String = "local.fhcpem.app.credentials") {
        self.service = service
        self.keychain = SystemCredentialKeychain()
    }
    init(service: String, keychain: any CredentialKeychainClient) {
        self.service = service
        self.keychain = keychain
    }
    private var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "connection",
                kSecAttrSynchronizable as String: false,
                kSecUseAuthenticationContext as String: context]
    }
    public func load() throws -> Credentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = keychain.copy(request)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data else { throw KeychainError(status: errSecDecode) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }
    public func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        // Updating preserves the user's existing access decision. Never delete and
        // recreate on login, or replace the ACL with an all-applications access list.
        let status = keychain.update(query, attributes: [kSecValueData as String: data])
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "FiberHome CPE Manager 管理后台连接"
        let added = keychain.add(item)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }
    public func delete() throws {
        let status = keychain.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
    public func exists() -> Bool {
        var request = query
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return keychain.copy(request).0 == errSecSuccess
    }
}

protocol CredentialKeychainClient: Sendable {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemCredentialKeychain: CredentialKeychainClient {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

public struct KeychainError: Error, LocalizedError, Sendable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
    public var errorDescription: String? {
        switch status {
        case errSecUserCanceled: "钥匙串访问已取消，请手动输入连接密码。"
        case errSecAuthFailed, errSecInteractionNotAllowed:
            "当前应用无法静默访问已保存的密码，请手动输入。重新签名的开发构建可能需要重新授权。"
        default: "钥匙串访问失败（\(status)），当前连接仍可使用；密码未保存。"
        }
    }
}
