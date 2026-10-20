import Testing
import Foundation
@testable import FHCPECore

/// Per-device icon pins: conservative identity, persistence and the 30-day expiry.
@MainActor
struct DeviceGlyphStoreTests {
    private func store() -> DeviceGlyphStore {
        let suite = UserDefaults(suiteName: "glyph-tests-\(UUID().uuidString)")!
        return DeviceGlyphStore(defaults: suite)
    }

    private func device(_ name: String, mac: String? = nil, host: String? = nil,
                        ip: String = "192.0.2.10", id: String? = nil) -> ConnectedDevice {
        ConnectedDevice(id: id ?? name, name: name, ip: ip, access: .wifi24G,
                        mac: mac, hostname: host)
    }

    @Test func macWinsOverHostname() {
        let a = device("Example", mac: "02-00-00-00-00-01")
        #expect(DeviceGlyphStore.identity(of: a) == "mac:02:00:00:00:00:01")
        let b = device("Example", host: "example.invalid")
        #expect(DeviceGlyphStore.identity(of: b) == "host:example.invalid|ip:192.0.2.10")
    }

    @Test func assignmentPersists() {
        let store = store()
        let endpoint = device("Example", mac: "02-00-00-00-00-01")
        store.assign(.washer, to: endpoint)
        #expect(store.glyph(for: endpoint) == .washer)
        store.assign(nil, to: endpoint)
        #expect(store.glyph(for: endpoint) == nil)
    }

    @Test func pinSurvivesAddressAndNameChangesWithTheSameMAC() {
        let store = store()
        store.assign(.refrigerator, to: device("Example-Old", mac: "02-00-00-00-00-01", host: "old.example.invalid"))
        let renamed = ConnectedDevice(id: "renamed", name: "Example-New", ip: "192.0.2.99",
                                      access: .wifi24G, mac: "02:00:00:00:00:01", hostname: "new.example.invalid")
        #expect(store.glyph(for: renamed) == .refrigerator)
    }

    @Test func sharedHostnameDoesNotTransferAPinToAnotherMAC() {
        let store = store()
        let first = device("Example-First", mac: "02:00:00:00:00:01", host: "android")
        let second = device("Example-Second", mac: "02:00:00:00:00:02", host: "ANDROID")
        store.assign(.airPurifier, to: first)
        #expect(store.glyph(for: second) == nil)
    }

    @Test func sharedDisplayNameDoesNotTransferAPinToAnotherMAC() {
        let store = store()
        store.assign(.washer, to: device("Example", mac: "02:00:00:00:00:01"))
        #expect(store.glyph(for: device("Example", mac: "02:00:00:00:00:02")) == nil)
    }

    @Test func assigningAnotherMACDoesNotReplaceTheOriginalPin() {
        let store = store()
        let first = device("Example", mac: "02:00:00:00:00:01", host: "android")
        let second = device("Example", mac: "02:00:00:00:00:02", host: "android")
        store.assign(.washer, to: first)
        store.assign(.camera, to: second)
        #expect(store.all().count == 2)
        #expect(store.glyph(for: first) == .washer)
        #expect(store.glyph(for: second) == .camera)
    }

    @Test func clearingAnotherMACDoesNotRemoveTheOriginalPin() {
        let store = store()
        let first = device("Example", mac: "02:00:00:00:00:01", host: "android")
        let second = device("Example", mac: "02:00:00:00:00:02", host: "android")
        store.assign(.washer, to: first)
        store.assign(nil, to: second)
        #expect(store.glyph(for: first) == .washer)
        #expect(store.all().count == 1)
    }

    @Test func missingMACDoesNotMatchAPinWithAKnownMAC() {
        let store = store()
        store.assign(.camera, to: device("Example", mac: "02:00:00:00:00:01", host: "android"))
        #expect(store.glyph(for: device("Example", host: "android")) == nil)
    }

    @Test func fallbackIdentitiesWorkWhenNeitherSideHasAMAC() {
        let store = store()
        store.assign(.camera, to: device("Example-Old", host: "endpoint.example.invalid"))
        #expect(store.glyph(for: device("Example-New", host: "ENDPOINT.example.invalid")) == .camera)
        store.assign(.speaker, to: device("Example-Unnamed"))
        #expect(store.glyph(for: device("Example-Unnamed")) == .speaker)
        #expect(store.glyph(for: device("Example-New", mac: "02:00:00:00:00:01", host: "endpoint.example.invalid")) == nil)
    }

    @Test(arguments: ["", "android"])
    func sameWeakNameAtAnotherIPDoesNotInheritAPin(_ host: String) {
        let store = store()
        let first = device("Example", host: host, ip: "192.0.2.10", id: "first")
        let second = device("Example", host: host, ip: "192.0.2.11", id: "second")
        store.assign(.washer, to: first)
        #expect(store.glyph(for: second) == nil)
    }

    @Test(arguments: ["", "android"])
    func assigningTheSameWeakNameAtAnotherIPPreservesBothPins(_ host: String) {
        let store = store()
        let first = device("Example", host: host, ip: "192.0.2.10", id: "first")
        let second = device("Example", host: host, ip: "192.0.2.11", id: "second")
        store.assign(.washer, to: first)
        store.assign(.camera, to: second)
        #expect(store.glyph(for: first) == .washer)
        #expect(store.glyph(for: second) == .camera)
        #expect(store.all().count == 2)
    }

    @Test(arguments: ["", "android"])
    func clearingTheSameWeakNameAtAnotherIPPreservesTheOriginalPin(_ host: String) {
        let store = store()
        let first = device("Example", host: host, ip: "192.0.2.10", id: "first")
        let second = device("Example", host: host, ip: "192.0.2.11", id: "second")
        store.assign(.washer, to: first)
        store.assign(nil, to: second)
        #expect(store.glyph(for: first) == .washer)
        #expect(store.all().count == 1)
    }

    @Test(arguments: ["", "android"])
    func theSameWeakNameAtAnotherIPDoesNotKeepAStalePinAlive(_ host: String) {
        let store = store()
        let first = device("Example", host: host, ip: "192.0.2.10", id: "first")
        let second = device("Example", host: host, ip: "192.0.2.11", id: "second")
        store.assign(.washer, to: first, now: Date(timeIntervalSince1970: 0))
        #expect(store.prune(keeping: [second], now: Date(timeIntervalSince1970: 10)) == 0)
        #expect(store.all().values.first?.lastSeen == Date(timeIntervalSince1970: 0))
        #expect(store.prune(keeping: [second], now: Date(timeIntervalSince1970: 31 * 24 * 3600)) == 1)
        #expect(store.glyph(for: second) == nil)
    }

    @Test func weakIdentityDoesNotSurviveAnIPChangeEvenWhenTheIDIsUnchanged() {
        let store = store()
        store.assign(.washer, to: device("Example", host: "android", ip: "192.0.2.10", id: "same"))
        #expect(store.glyph(for: device("Example", host: "android", ip: "192.0.2.11", id: "same")) == nil)
    }

    @Test func aWeakIdentityWithoutACurrentIPIsNotPersisted() {
        let store = store()
        let endpoint = device("Example", host: "android", ip: " ")
        store.assign(.washer, to: endpoint)
        #expect(store.glyph(for: endpoint) == nil)
        #expect(store.all().isEmpty)
    }

    @Test func legacyWeakPinsWithoutAnIPDoNotMigrateAndExpireNormally() throws {
        let defaults = UserDefaults(suiteName: "glyph-tests-\(UUID().uuidString)")!
        let entries = [
            "host:android": DeviceGlyphStore.Entry(glyph: .washer, lastSeen: Date(timeIntervalSince1970: 0), hostname: "android"),
            "name:example": DeviceGlyphStore.Entry(glyph: .dryer, lastSeen: Date(timeIntervalSince1970: 0))
        ]
        defaults.set(try JSONEncoder().encode(entries), forKey: "deviceGlyphOverrides")
        let store = DeviceGlyphStore(defaults: defaults)
        let endpoint = device("Example", host: "android")
        #expect(store.glyph(for: endpoint) == nil)
        #expect(store.glyph(for: device("Example")) == nil)
        #expect(store.prune(keeping: [endpoint], now: Date(timeIntervalSince1970: 10)) == 0)
        #expect(store.all() == entries)
        store.assign(.camera, to: endpoint, now: Date(timeIntervalSince1970: 20 * 24 * 3600))
        #expect(store.all().count == 3)
        #expect(store.prune(keeping: [endpoint], now: Date(timeIntervalSince1970: 31 * 24 * 3600)) == 2)
        #expect(store.glyph(for: endpoint) == .camera)
    }

    @Test func staleEntryExpiresAfterAMonth() {
        let store = store()
        let endpoint = device("Example", mac: "02:00:00:00:00:01")
        store.assign(.washer, to: endpoint, now: Date(timeIntervalSince1970: 0))
        #expect(store.prune(keeping: [], now: Date(timeIntervalSince1970: 29 * 24 * 3600)) == 0)
        #expect(store.glyph(for: endpoint) == .washer)
        #expect(store.prune(keeping: [], now: Date(timeIntervalSince1970: 31 * 24 * 3600)) == 1)
        #expect(store.glyph(for: endpoint) == nil)
    }

    @Test func seenHostStaysPinned() {
        let store = store()
        let endpoint = device("Example", mac: "02:00:00:00:00:01")
        store.assign(.dryer, to: endpoint, now: Date(timeIntervalSince1970: 0))
        #expect(store.prune(keeping: [endpoint], now: Date(timeIntervalSince1970: 40 * 24 * 3600)) == 0)
        #expect(store.glyph(for: endpoint) == .dryer)
    }

    @Test func differentMACWithTheSameHostnameDoesNotKeepAStalePinAlive() {
        let store = store()
        let first = device("Example", mac: "02:00:00:00:00:01", host: "android")
        let second = device("Example", mac: "02:00:00:00:00:02", host: "android")
        store.assign(.airPurifier, to: first, now: Date(timeIntervalSince1970: 0))
        #expect(store.prune(keeping: [second], now: Date(timeIntervalSince1970: 10)) == 0)
        #expect(store.all().values.first?.mac == "02:00:00:00:00:01")
        #expect(store.prune(keeping: [second], now: Date(timeIntervalSince1970: 31 * 24 * 3600)) == 1)
        #expect(store.glyph(for: second) == nil)
    }

    @Test func reassignmentDoesNotLeaveAStaleEntry() {
        let store = store()
        let endpoint = device("Example", mac: "02:00:00:00:00:01", host: "endpoint.example.invalid")
        store.assign(.washer, to: endpoint)
        store.assign(.dryer, to: endpoint)
        #expect(store.all().count == 1)
        #expect(store.glyph(for: endpoint) == .dryer)
        store.assign(nil, to: endpoint)
        #expect(store.all().isEmpty)
    }

    @Test func pruneRefreshesMetadataOnlyForTheSameMAC() {
        let store = store()
        let first = device("Example-Old", mac: "02:00:00:00:00:01", host: "old.example.invalid")
        let renamed = device("Example-New", mac: "02-00-00-00-00-01", host: "new.example.invalid")
        store.assign(.airPurifier, to: first, now: Date(timeIntervalSince1970: 0))
        #expect(store.prune(keeping: [renamed], now: Date(timeIntervalSince1970: 10)) == 0)
        #expect(store.all().values.first?.hostname == "new.example.invalid")
        #expect(store.glyph(for: renamed) == .airPurifier)
    }

    @Test func legacyMACKeyStillPreventsHostnameAliasesFromCrossingMACs() {
        let store = store()
        let entries = ["mac:02:00:00:00:00:01": DeviceGlyphStore.Entry(
            glyph: .washer, lastSeen: Date(), hostname: "android")]
        #expect(store.glyph(for: device("Example", mac: "02:00:00:00:00:01"), in: entries) == .washer)
        #expect(store.glyph(for: device("Example", mac: "02:00:00:00:00:02", host: "android"), in: entries) == nil)
    }

    @Test func originalMACKeyWinsOverMetadataChangedByLegacyHostnameMatching() {
        let store = store()
        let entries = ["mac:02:00:00:00:00:01": DeviceGlyphStore.Entry(
            glyph: .washer, lastSeen: Date(), mac: "02:00:00:00:00:02", hostname: "android")]
        #expect(store.glyph(for: device("Example", mac: "02:00:00:00:00:01"), in: entries) == .washer)
        #expect(store.glyph(for: device("Example", mac: "02:00:00:00:00:02", host: "android"), in: entries) == nil)
    }

    @Test func assigningAFallbackIdentityPreservesALegacyPinWithKnownMAC() throws {
        let defaults = UserDefaults(suiteName: "glyph-tests-\(UUID().uuidString)")!
        let entries = ["host:android": DeviceGlyphStore.Entry(
            glyph: .washer, lastSeen: Date(), mac: "02:00:00:00:00:01", hostname: "android")]
        defaults.set(try JSONEncoder().encode(entries), forKey: "deviceGlyphOverrides")
        let store = DeviceGlyphStore(defaults: defaults)
        let fallback = device("Example", host: "android")
        store.assign(.camera, to: fallback)
        #expect(store.glyph(for: fallback) == .camera)
        #expect(store.glyph(for: device("Example", mac: "02:00:00:00:00:01")) == .washer)
        #expect(store.all().count == 2)
    }

    @Test func everyGlyphHasATitleAndSymbol() {
        for glyph in DeviceGlyph.allCases {
            #expect(!glyph.title.isEmpty)
            #expect(!glyph.symbol.isEmpty)
        }
    }
}
