import Foundation
import Security

public struct CredentialStore {
    private let service: String
    public init(service: String = "local.fhcpem.app.connection") { self.service = service }
    private var query: [String: Any] { [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String:"connection", kSecAttrSynchronizable as String:false] }
    public func load() throws -> Credentials? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }
    public func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let result = SecItemAdd(q as CFDictionary, nil)
            guard result == errSecSuccess else { throw KeychainError(status: result) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
public struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    public var errorDescription: String? { "钥匙串访问失败（\(status)）。连接信息未保存；可取消记住连接后重试。" }
}
