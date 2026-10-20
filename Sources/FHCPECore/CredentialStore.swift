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
                kSecUseAuthenticationContext as String: context,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
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
    private static let gate = CredentialAccessGate()
    /// The app uses the legacy login Keychain. Suppress its optional UI as well as the
    /// LAContext UI, serializing our synchronous calls and restoring the process setting.
    private func withoutAuthenticationUI(_ body: () -> OSStatus) -> OSStatus {
        Self.gate.perform {
            var previous: DarwinBoolean = true
            let read = SecKeychainGetUserInteractionAllowed(&previous)
            guard read == errSecSuccess else { return read }
            let disabled = SecKeychainSetUserInteractionAllowed(false)
            guard disabled == errSecSuccess else { return disabled }
            defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
            return body()
        }
    }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = withoutAuthenticationUI { SecItemCopyMatching(query as CFDictionary, &result) }
        return (status, result as? Data)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        withoutAuthenticationUI { SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        withoutAuthenticationUI { SecItemAdd(attributes as CFDictionary, nil) }
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        withoutAuthenticationUI { SecItemDelete(query as CFDictionary) }
    }
}

/// A denied background request closes access for the rest of this process. All store
/// instances share this gate, so reconnects, reads, or repeated save attempts cannot
/// keep asking securityd for an item this build is not allowed to access.
final class CredentialAccessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var deniedStatus: OSStatus?

    func perform(_ operation: () -> OSStatus) -> OSStatus {
        lock.withLock {
            if let deniedStatus { return deniedStatus }
            let status = operation()
            if [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled,
                errSecNotAvailable, errSecMissingEntitlement].contains(status) {
                deniedStatus = status
            }
            return status
        }
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
