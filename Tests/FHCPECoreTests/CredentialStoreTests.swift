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

    @Test func successfulLoadUsesNoninteractiveAuthentication() throws {
        let client = KeychainDouble()
        client.data = try JSONEncoder().encode(credentials)
        #expect(try CredentialStore(service: "test", keychain: client).load() == credentials)
        let query = try #require(client.requests.first)
        #expect(query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
        #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
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
        #expect(client.requests.allSatisfy {
            ($0[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
        })
    }

    @Test func missingCredentialIsNotAnError() throws {
        let client = KeychainDouble(); client.status = errSecItemNotFound
        #expect(try CredentialStore(service: "test", keychain: client).load() == nil)
    }

    @Test func deletionAlsoPreventsAuthenticationUI() throws {
        let client = KeychainDouble()
        try CredentialStore(service: "test", keychain: client).delete()
        #expect(client.operations == ["delete"])
        #expect((client.requests.first?[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
    }

    @Test func deniedAccessStopsAllFurtherBackgroundRequests() {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled,
                       errSecNotAvailable, errSecMissingEntitlement] {
            let gate = CredentialAccessGate()
            var requests = 0
            for _ in 0..<50 {
                #expect(gate.perform { requests += 1; return status } == status)
            }
            #expect(requests == 1)
        }
    }

    @Test func missingItemDoesNotPreventAddingAndReadingIt() {
        let gate = CredentialAccessGate()
        var requests = 0
        #expect(gate.perform { requests += 1; return errSecItemNotFound } == errSecItemNotFound)
        #expect(gate.perform { requests += 1; return errSecSuccess } == errSecSuccess)
        #expect(gate.perform { requests += 1; return errSecSuccess } == errSecSuccess)
        #expect(requests == 3)
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
