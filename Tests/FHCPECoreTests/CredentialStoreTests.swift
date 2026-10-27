import Foundation
import LocalAuthentication
import Security
import Testing
@testable import FHCPECore

private final class KeychainDouble: CredentialKeychainClient, @unchecked Sendable {
    var status: OSStatus = errSecSuccess
    var data: Data?
    var requests: [[String: Any]] = []
    var operations: [String] = []
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        requests.append(query); operations.append("copy"); return (status, data)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        requests.append(query); operations.append("update"); return status
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        requests.append(attributes); operations.append("add"); return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        requests.append(query); operations.append("delete"); return status
    }
}

struct CredentialStoreTests {
    private let credentials = Credentials(address: "192.0.2.1", username: "test", password: "test-only")

    @Test func successfulLoadIncludesAuthenticationContext() throws {
        let client = KeychainDouble()
        client.data = try JSONEncoder().encode(credentials)
        #expect(try CredentialStore(service: "test", keychain: client).load() == credentials)
        let query = try #require(client.requests.first)
        #expect(query[kSecUseAuthenticationUI as String] == nil)
        #expect(query[kSecUseAuthenticationContext as String] is LAContext)
    }

    @Test func lockedOrUntrustedItemNeverFallsBackToRecreatingIt() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed] {
            let client = KeychainDouble(); client.status = status
            #expect(throws: KeychainError.self) {
                try CredentialStore(service: "test", keychain: client).save(credentials)
            }
            #expect(client.operations == ["update"])
        }
    }

    @Test func savingAnExistingItemPreservesItsACL() throws {
        let client = KeychainDouble()
        try CredentialStore(service: "test", keychain: client).save(credentials)
        #expect(client.operations == ["update"])
        #expect(client.requests.allSatisfy { $0[kSecAttrAccess as String] == nil })
    }

    @Test func onlyAMissingItemCanBeAdded() throws {
        let client = KeychainDouble(); client.status = errSecItemNotFound
        try CredentialStore(service: "test", keychain: client).save(credentials)
        #expect(client.operations == ["update", "add"])
        #expect(client.requests.allSatisfy { $0[kSecAttrAccess as String] == nil })
        #expect(client.requests.allSatisfy { $0[kSecUseAuthenticationContext as String] is LAContext })
    }

    @Test func missingCredentialIsNotAnError() throws {
        let client = KeychainDouble(); client.status = errSecItemNotFound
        #expect(try CredentialStore(service: "test", keychain: client).load() == nil)
    }

    @Test func deletionIncludesAuthenticationContext() throws {
        let client = KeychainDouble()
        try CredentialStore(service: "test", keychain: client).delete()
        #expect(client.operations == ["delete"])
        #expect(client.requests.first?[kSecUseAuthenticationContext as String] is LAContext)
    }

    @Test func deniedReadDoesNotPreventALaterSuccessfulRead() throws {
        let client = KeychainDouble()
        let store = CredentialStore(service: "test", keychain: client)
        client.status = errSecInteractionNotAllowed
        #expect(throws: KeychainError.self) { try store.load() }
        client.status = errSecSuccess
        client.data = try JSONEncoder().encode(credentials)
        #expect(try store.load() == credentials)
        #expect(client.operations == ["copy", "copy"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FHCPE_KEYCHAIN_SMOKE"] == "1"))
    func systemKeychainRoundTripWithoutAuthenticationUI() throws {
        let store = CredentialStore(service: "local.fhcpem.app.tests.\(UUID().uuidString)")
        defer { try? store.delete() }
        try store.save(credentials)
        #expect(try store.load() == credentials)
        var updated = credentials
        updated.password = "another-test-only-value"
        try store.save(updated)
        #expect(try store.load() == updated)
        try store.delete()
        #expect(try store.load() == nil)
    }
}
