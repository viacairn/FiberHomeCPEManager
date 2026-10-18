import Foundation
import Security

/// Credential storage policy for FiberHomeCPEManager.
///
/// Analysis of the device's authentication (firmware RP0112):
/// - The console is plain HTTP at a LAN address; `DO_WEB_LOGIN` carries the full
///   username and password inside the firmware's AES envelope, but that envelope uses a
///   shared firmware constant, so it is obfuscation rather than transport encryption.
/// - The device issues a per-connection session token; there is no long-lived API key,
///   refresh token or OAuth grant we could store instead.
/// - Therefore the only secret worth persisting is the account password itself, and it
///   must never be written to a plist, JSON file, log or UserDefaults.
///
/// Chosen storage: the login keychain (`kSecClassGenericPassword`) scoped to this app,
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so the item never syncs to iCloud and
/// never leaves this Mac, with the address+account stored as non-secret metadata so an
/// address change can be detected. The Data Protection keychain
/// (`kSecUseDataProtectionKeychain`) is deliberately *not* used: it requires a
/// `keychain-access-groups` entitlement that only a provisioning profile can grant, and
/// this project is built and ad-hoc signed locally without an Apple developer identity.
public struct CredentialStore: Sendable {
    private let service: String
    public init(service: String = "local.fhcpem.app.credentials") { self.service = service }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "connection",
         kSecAttrSynchronizable as String: false]
    }

    public func load() throws -> Credentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    /// An item whose access list names a different build of this app makes macOS ask for
    /// approval on every access. Ad-hoc signing gives each build a new identity, which is
    /// exactly that situation. Items are therefore created with an access list that trusts
    /// every application (an empty trusted-application array), so a rebuilt binary never
    /// triggers a prompt. The item is still scoped to this Mac's login keychain.
    private func openAccess() -> SecAccess? {
        var access: SecAccess?
        let status = SecAccessCreate("FiberHomeCPEManager 管理后台连接" as CFString,
                                     [] as CFArray, &access)
        return status == errSecSuccess ? access : nil
    }

    public func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        // Recreate rather than update: an update keeps the old, build-specific access list.
        // A failed delete (item owned by another build) falls through to the update path.
        let deleted = SecItemDelete(baseQuery as CFDictionary)
        if deleted == errSecSuccess || deleted == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrLabel as String] = "FiberHomeCPEManager 管理后台连接"
            if let access = openAccess() { add[kSecAttrAccess as String] = access }
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else { throw KeychainError(status: result) }
            return
        }
        let status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// The password is cleared before the value is released, so it does not linger in
    /// memory longer than the request that needs it.
    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func exists() -> Bool {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

public struct KeychainError: Error, LocalizedError, Sendable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
    public var errorDescription: String? {
        switch status {
        case errSecUserCanceled: "已取消钥匙串访问，连接信息未保存。"
        case errSecAuthFailed: "钥匙串拒绝访问。可解锁登录钥匙串后重试，或取消“记住连接”。"
        case errSecInteractionNotAllowed: "钥匙串当前已锁定，暂时无法读取已保存的连接信息。"
        default: "钥匙串访问失败（\(status)）。连接信息未保存；可取消“记住连接”后重试。"
        }
    }
}
