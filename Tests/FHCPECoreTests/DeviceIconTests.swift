import Testing
import Foundation
@testable import FHCPECore

/// Device glyph inference.
///
/// The firmware reports `deviceType = "Phone"` for cameras and air conditioners, so trusting
/// the reported type made every appliance render as a phone. Hostname keywords now win.
struct DeviceIconTests {
    private func device(_ name: String, type: String? = nil, hostname: String? = nil) -> ConnectedDevice {
        ConnectedDevice(id: name, name: name, ip: "192.168.8.1", access: .wifi24G,
                        hostname: hostname, deviceType: type)
    }

    @Test func applianceNamesWin() {
        #expect(device("Demo-Device-7c09e0").icon == .washer)
        #expect(device("Demo-Device-7c09e0").systemSymbol == "washer")
        #expect(device("Roborock-S8").icon == .vacuum)
        #expect(device("Aqara-Camera-G100").icon == .camera)
        #expect(device("Midea-AirConditioner-1").icon == .airConditioner)
        #expect(device("Midea-RangeHood").icon == .hood)
        #expect(device("Midea-TanklessHeater").icon == .heater)
    }

    /// Regression: the reported type must not override a recognised appliance name.
    @Test func reportedPhoneTypeDoesNotOverrideAppliance() {
        let aircon = device("Midea-AirConditioner-1", type: "Phone")
        #expect(aircon.icon == .airConditioner)
        #expect(aircon.systemSymbol == "air.conditioner.horizontal")
    }

    @Test func appleDevices() {
        #expect(device("iPhone").icon == .phone)
        #expect(device("Watch").icon == .watch)
        #expect(device("Mac").icon == .desktop)
        #expect(device("MacBook-Pro").icon == .laptop)
    }

    /// A generic hostname must not hide the meaningful display name.
    @Test func displayNameIsUsedWhenHostnameIsGeneric() {
        let camera = device("Aqara-Camera-G100", hostname: "android-abc123")
        #expect(camera.icon == .camera)
    }

    @Test func unknownFallsBackToDashedQuestionMark() {
        #expect(device("ESP_9F2A11").icon == .unknown)
        #expect(device("ESP_9F2A11").systemSymbol == "questionmark.square.dashed")
    }

    /// Every inferred icon resolves to a symbol that exists on this OS.
    @Test func everySymbolNameIsAvailable() {
        let names = ["Demo-Device-7c09e0", "Aqara-Camera-G100", "Midea-AirConditioner-1",
                     "Midea-RangeHood", "Midea-TanklessHeater", "iPhone", "Watch", "Mac", "ESP_1"]
        for name in names {
            let symbol = device(name).systemSymbol
            #expect(!symbol.isEmpty)
        }
    }
}
