import Foundation
import Testing
@testable import FHCPECore
@testable import FHCPEM

@MainActor @Suite(.serialized)
struct AppStoreOrchestrationTests {
    private func connectedStore(_ body: @MainActor (AppStore, FakeCPE) async throws -> Void) async throws {
        let server = try FakeCPE()
        let port = try server.start()
        defer { server.stop() }
        let suite = "fhcpem.orchestration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(preferences: Preferences(defaults: defaults), widgetStore: nil)
        defer { store.shutdown() }
        store.model.draftAddress = "http://127.0.0.1:\(port)"
        store.model.draftPassword = "test-password"
        store.connect()
        try await waitUntil { store.model.data.isLive && !store.model.busy }
        try await body(store, server)
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await clock.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test func pollingRenewsExpiredAuthenticationOnceAndPreservesDraft() async throws {
        try await connectedStore { store, server in
            store.model.draftBody = "unsent draft"
            server.expireSession()
            await store.refreshOnce()
            try await waitUntil { !store.model.busy && server.requestCount("DO_WEB_LOGIN") == 2 }
            #expect(store.model.route == .main)
            #expect(store.model.data.isLive)
            #expect(store.model.draftBody == "unsent draft")
            #expect(server.requestCount("DO_WEB_LOGIN") == 2)
            #expect(store.model.connectError == nil)
        }
    }

    @Test func failedSilentRenewalReturnsToLoginAfterOneAttempt() async throws {
        try await connectedStore { store, server in
            store.model.draftBody = "unsent draft"
            server.refuseSubsequentLogins()
            server.expireSession()
            await store.refreshOnce()
            try await waitUntil { store.model.route == .connect && !store.model.busy }
            #expect(server.requestCount("DO_WEB_LOGIN") == 2)
            #expect(store.model.connectError != nil)
            #expect(store.model.draftBody == "unsent draft")
            #expect(!store.model.data.isLive)
        }
    }

    @Test func settingsOperationRenewsExpiredAuthenticationQuietly() async throws {
        try await connectedStore { store, server in
            server.expireSession()
            store.model.saveLED(true)
            try await waitUntil { !store.model.busy && server.requestCount("DO_WEB_LOGIN") == 2 }
            #expect(store.model.data.isLive)
            #expect(store.model.route == .main)
            #expect(!store.model.settingsBusy)
            #expect(!store.model.notices.notices.contains { $0.message == CPEError.authentication.errorDescription })
        }
    }

    @Test(arguments: [UplinkTarget.cellular, .ethernet, .aggregation])
    func acknowledgedUplinkRemainsSelectedWhenFirmwareReadbackLags(_ target: UplinkTarget) async throws {
        try await connectedStore { store, _ in
            try await waitUntil { store.model.settings != nil }
            store.switchUplink(target)
            try await waitUntil { !store.model.settingsBusy }
            #expect(store.model.settings?.activeUplink == target)
            #expect(store.model.uplinkSwitchTarget == nil)
        }
    }

    @Test func rebootIsSentOnceThenAutomaticallyReconnects() async throws {
        try await connectedStore { store, server in
            store.model.tab = 2
            store.rebootDevice()
            #expect(store.model.rebooting)
            try await waitUntil { !store.model.data.isLive && server.requestCount("device_reboot") == 1 }
            #expect(store.model.settingsBusy)
            try await waitUntil(timeout: .seconds(20)) { !store.model.rebooting && store.model.data.isLive }
            #expect(server.requestCount("device_reboot") == 1)
            #expect(server.requestCount("DO_WEB_LOGIN") == 2)
            #expect(store.model.tab == 2)
            #expect(store.model.route == .main)
        }
    }
}
