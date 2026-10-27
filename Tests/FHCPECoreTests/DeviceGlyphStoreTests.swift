import Testing
import Foundation
@testable import FHCPECore

/// Per-device icon pins use the stable MAC or the device identifier.
@MainActor
struct DeviceGlyphStoreTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "glyph-tests-\(UUID().uuidString)")!
    }

    private func device(_ id: String, name: String = "Example", mac: String? = nil,
                        host: String? = nil, ip: String = "192.0.2.10") -> ConnectedDevice {
        ConnectedDevice(id: id, name: name, ip: ip, access: .wifi24G, mac: mac, hostname: host)
    }

    @Test func normalizedMACIsTheStableIdentity() {
        let endpoint = device("fixture", mac: " 02-ab-00-00-00-01 ")
        #expect(DeviceGlyphStore.identity(of: endpoint) == "02:AB:00:00:00:01")
    }

    @Test func missingMACUsesTheDeviceID() {
        let endpoint = device("stable-id", mac: " ", host: "host.invalid", ip: "")
        #expect(DeviceGlyphStore.identity(of: endpoint) == "stable-id")
    }

    @Test func assignmentPersistsAcrossStoreInstancesAndCanBeCleared() {
        let defaults = defaults()
        let endpoint = device("fixture", mac: "02:00:00:00:00:01")
        DeviceGlyphStore(defaults: defaults).assign(.washer, to: endpoint)
        let reloaded = DeviceGlyphStore(defaults: defaults)
        #expect(reloaded.glyph(for: endpoint) == .washer)
        reloaded.assign(nil, to: endpoint)
        #expect(DeviceGlyphStore(defaults: defaults).glyph(for: endpoint) == nil)
    }

    @Test func pinSurvivesAddressAndNameChangesWithTheSameMAC() {
        let store = DeviceGlyphStore(defaults: defaults())
        store.assign(.refrigerator, to: device("old", name: "Old", mac: "02-00-00-00-00-01", host: "old.invalid"))
        #expect(store.glyph(for: device("new", name: "New", mac: "02:00:00:00:00:01", host: "new.invalid", ip: "192.0.2.99")) == .refrigerator)
    }

    @Test func missingMACPinSurvivesAddressAndNameChangesWithTheSameID() {
        let store = DeviceGlyphStore(defaults: defaults())
        store.assign(.camera, to: device("stable", name: "Old", host: "old.invalid"))
        #expect(store.glyph(for: device("stable", name: "New", host: "new.invalid", ip: "192.0.2.99")) == .camera)
    }

    @Test func sharedHostnameDoesNotTransferAPinBetweenDeviceIDs() {
        let store = DeviceGlyphStore(defaults: defaults())
        store.assign(.washer, to: device("first", host: "android"))
        #expect(store.glyph(for: device("second", host: "android")) == nil)
    }

    @Test func assigningAndClearingAnotherMACPreservesTheOriginalPin() {
        let store = DeviceGlyphStore(defaults: defaults())
        let first = device("first", mac: "02:00:00:00:00:01", host: "android")
        let second = device("second", mac: "02:00:00:00:00:02", host: "android")
        store.assign(.washer, to: first)
        store.assign(.camera, to: second)
        #expect(store.all().count == 2)
        store.assign(nil, to: second)
        #expect(store.glyph(for: first) == .washer)
        #expect(store.glyph(for: second) == nil)
    }

    @Test func deviceIDWithoutAnAddressCanBePinned() {
        let store = DeviceGlyphStore(defaults: defaults())
        let endpoint = device("stable", ip: " ")
        store.assign(.dryer, to: endpoint)
        #expect(store.glyph(for: endpoint) == .dryer)
    }

    @Test func defaultsContainsOnlyTheGlyphDictionary() throws {
        let defaults = defaults()
        let endpoint = device("stable", mac: "02:00:00:00:00:01")
        DeviceGlyphStore(defaults: defaults).assign(.camera, to: endpoint)
        let data = try #require(defaults.data(forKey: "deviceGlyphOverrides"))
        #expect(try JSONDecoder().decode([String: DeviceGlyph].self, from: data) == ["02:00:00:00:00:01": .camera])
    }

    @Test func lookupInACachedDictionaryUsesTheSameStableIdentity() {
        let store = DeviceGlyphStore(defaults: defaults())
        let entries: [String: DeviceGlyph] = ["02:00:00:00:00:01": .washer, "stable": .camera]
        #expect(store.glyph(for: device("other", mac: "02-00-00-00-00-01"), in: entries) == .washer)
        #expect(store.glyph(for: device("stable"), in: entries) == .camera)
        #expect(store.glyph(for: device("unknown"), in: entries) == nil)
    }

    @Test func everyGlyphHasATitleAndSymbol() {
        for glyph in DeviceGlyph.allCases {
            #expect(!glyph.title.isEmpty)
            #expect(!glyph.symbol.isEmpty)
        }
    }
}
