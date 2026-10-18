import Testing
import Foundation
@testable import FHCPECore

/// Per-host icon pins: identity, persistence and the 30-day expiry.
@MainActor
struct DeviceGlyphStoreTests {
    private func store() -> DeviceGlyphStore {
        let suite = UserDefaults(suiteName: "glyph-tests-\(UUID().uuidString)")!
        return DeviceGlyphStore(defaults: suite)
    }

    private func device(_ name: String, mac: String? = nil, host: String? = nil) -> ConnectedDevice {
        ConnectedDevice(id: name, name: name, ip: "192.168.8.10", access: .wifi24G,
                        mac: mac, hostname: host)
    }

    @Test func macWinsOverHostname() {
        let a = device("Whatever", mac: "aa-bb-cc-dd-ee-ff")
        #expect(DeviceGlyphStore.identity(of: a) == "mac:AA:BB:CC:DD:EE:FF")
        let b = device("Whatever", host: "nas.local")
        #expect(DeviceGlyphStore.identity(of: b) == "host:nas.local")
    }

    @Test func assignmentPersists() {
        let store = store()
        let washer = device("ESP_1", mac: "11-22-33-44-55-66")
        store.assign(.washer, to: washer)
        #expect(store.glyph(for: washer) == .washer)
        store.assign(nil, to: washer)
        #expect(store.glyph(for: washer) == nil)
    }

    @Test func pinSurvivesAddressChange() {
        let store = store()
        store.assign(.refrigerator, to: device("fridge", mac: "aa-aa-aa-aa-aa-aa"))
        // Same MAC, different DHCP address and display name.
        let renamed = ConnectedDevice(id: "x", name: "Kitchen-Fridge", ip: "192.168.8.99",
                                      access: .wifi24G, mac: "AA:AA:AA:AA:AA:AA")
        #expect(store.glyph(for: renamed) == .refrigerator)
    }

    @Test func staleEntryExpiresAfterAMonth() {
        let store = store()
        let washer = device("washer", mac: "22-33-44-55-66-77")
        store.assign(.washer, to: washer, now: Date(timeIntervalSince1970: 0))
        // Seen again just under the window: kept.
        let kept = store.prune(keeping: [], now: Date(timeIntervalSince1970: 29 * 24 * 3600))
        #expect(kept == 0)
        #expect(store.glyph(for: washer) == .washer)
        // Past 30 days: dropped.
        let removed = store.prune(keeping: [], now: Date(timeIntervalSince1970: 31 * 24 * 3600))
        #expect(removed == 1)
        #expect(store.glyph(for: washer) == nil)
    }

    @Test func seenHostStaysPinned() {
        let store = store()
        let deviceA = device("a", mac: "33-44-55-66-77-88")
        store.assign(.dryer, to: deviceA, now: Date(timeIntervalSince1970: 0))
        // Still on the LAN after 40 days: lastSeen refreshes, so it is not pruned.
        let removed = store.prune(keeping: [deviceA], now: Date(timeIntervalSince1970: 40 * 24 * 3600))
        #expect(removed == 0)
        #expect(store.glyph(for: deviceA) == .dryer)
    }

    /// A pin recorded by MAC is still found when the device returns with the same hostname
    /// but a randomized MAC (and vice versa): the entry stores both aliases.
    @Test func pinSurvivesEitherAliasChanging() {
        let store = store()
        store.assign(.airPurifier, to: device("esp-old", mac: "aa-bb-cc-dd-ee-ff", host: "purifier.local"))
        // Same hostname, new MAC.
        let newMAC = device("esp-new", mac: "11-22-33-44-55-66", host: "PURIFIER.local")
        #expect(store.glyph(for: newMAC) == .airPurifier)
        // Same MAC, new hostname.
        let newHost = device("esp-new", mac: "AA:BB:CC:DD:EE:FF", host: "other.local")
        #expect(store.glyph(for: newHost) == .airPurifier)
    }

    /// Reassigning a pin must migrate it, not leave the old alias behind.
    @Test func reassignmentDoesNotLeaveAStaleAlias() {
        let store = store()
        let first = device("appliance", mac: "aa-bb-cc-dd-ee-ff", host: "appliance.local")
        store.assign(.washer, to: first)
        store.assign(.dryer, to: first)
        #expect(store.all().count == 1)
        let newMAC = device("appliance", mac: "11-22-33-44-55-66", host: "appliance.local")
        #expect(store.glyph(for: newMAC) == .dryer)
        store.assign(nil, to: newMAC)
        #expect(store.all().isEmpty)
    }

    /// Pruning must refresh the aliases too, so a later MAC/hostname change still matches.
    @Test func pruneRefreshesAliases() {
        let store = store()
        let first = device("purifier", mac: "aa-bb-cc-dd-ee-ff", host: "purifier.local")
        store.assign(.airPurifier, to: first, now: Date(timeIntervalSince1970: 0))
        let changed = device("purifier", mac: "11-22-33-44-55-66", host: "purifier.local")
        #expect(store.prune(keeping: [changed], now: Date(timeIntervalSince1970: 10)) == 0)
        let entry = store.all().values.first
        #expect(entry?.mac == "11:22:33:44:55:66")
    }

    @Test func everyGlyphHasATitleAndSymbol() {
        for glyph in DeviceGlyph.allCases {
            #expect(!glyph.title.isEmpty)
            #expect(!glyph.symbol.isEmpty)
        }
    }
}
