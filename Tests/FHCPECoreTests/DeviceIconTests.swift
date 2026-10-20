import Testing
import Foundation
@testable import FHCPECore

/// Inference uses explicit category or product-family clues, never a household inventory.
struct DeviceIconTests {
    private func device(_ name: String, type: String? = nil, hostname: String? = nil,
                        mac: String? = nil) -> ConnectedDevice {
        ConnectedDevice(id: name, name: name, ip: "192.0.2.10", access: .wifi24G,
                        mac: mac, hostname: hostname, deviceType: type)
    }

    @Test func explicitApplianceCategories() {
        #expect(device("Example-Washer").icon == .washer)
        #expect(device("Example-Washing-Machine").icon == .washer)
        #expect(device("Example-Vacuum").icon == .vacuum)
        #expect(device("Example-Camera").icon == .camera)
        #expect(device("Example-AirConditioner").icon == .airConditioner)
        #expect(device("Example-Air-Conditioner").icon == .airConditioner)
        #expect(device("Example-RangeHood").icon == .hood)
        #expect(device("Example-TanklessHeater").icon == .heater)
        #expect(device("示例洗衣机").icon == .washer)
        #expect(device("示例摄像头").icon == .camera)
    }

    @Test(arguments: ["Roborock", "Roborock-Example", "Aqara", "Midea", "Apple",
                      "Samsung", "Tuya", "Espressif"])
    func vendorAloneDoesNotIdentifyADeviceCategory(_ name: String) {
        #expect(device(name).icon == .unknown)
    }

    @Test(arguments: ["Example-H1-Air", "Example-WM-Device", "machine", "dispatch",
                      "switch", "roadwatch", "hoodie", "tvstand", "robot", "mousepad", "pcie"])
    func ambiguousNamesAndEmbeddedSubstringsStayUnknown(_ name: String) {
        #expect(device(name).icon == .unknown)
    }

    @Test func macAddressDoesNotDetermineCategory() {
        #expect(device("Example-Endpoint", mac: "02:00:00:00:00:01").icon == .unknown)
        #expect(device("Example-Endpoint", mac: "02:00:00:00:00:02").icon == .unknown)
    }

    /// Some firmware reports appliances as phones; explicit category names take priority.
    @Test func reportedPhoneTypeDoesNotOverrideAppliance() {
        let aircon = device("Example-AirConditioner", type: "Phone")
        #expect(aircon.icon == .airConditioner)
        #expect(aircon.systemSymbol == "air.conditioner.horizontal")
    }

    @Test func commonProductFamiliesAndExplicitTypes() {
        #expect(device("Example-iPhone").icon == .phone)
        #expect(device("Example-iPhone16").icon == .phone)
        #expect(device("Example-iPad13").icon == .tablet)
        #expect(device("Example-Watch").icon == .watch)
        #expect(device("Example-iMac").icon == .desktop)
        #expect(device("Example-Mac-mini").icon == .desktop)
        #expect(device("Example-MacBook-Pro").icon == .laptop)
        #expect(device("Example-AppleTV").icon == .tv)
        #expect(device("Example-PlayStation5").icon == .gamepad)
        #expect(device("Example-Nintendo-Switch").icon == .gamepad)
        #expect(device("Example-Endpoint", type: "Laptop").icon == .laptop)
        #expect(device("Example-Endpoint", type: "Tablet").icon == .tablet)
        #expect(device("Example-Endpoint", type: "IPCamera").icon == .camera)
    }

    @Test func unrecognizedFirmwareTypeStaysUnknown() {
        #expect(device("Example-Endpoint", type: "notphone").icon == .unknown)
        #expect(device("Example-Endpoint", type: "HPC").icon == .unknown)
    }

    @Test func displayNameIsUsedWhenHostnameIsGeneric() {
        let camera = device("Example-Camera", hostname: "android-example")
        #expect(camera.icon == .camera)
    }

    @Test func explicitCategoryCanComeFromHostname() {
        #expect(device("Example-Endpoint", hostname: "example-vacuum").icon == .vacuum)
    }

    @Test func separateFieldsDoNotFormACategory() {
        #expect(device("air", hostname: "conditioner").icon == .unknown)
    }

    @Test func unknownFallsBackToDashedQuestionMark() {
        #expect(device("Example-Endpoint").icon == .unknown)
        #expect(device("Example-Endpoint").systemSymbol == "questionmark.square.dashed")
    }

    @Test func inferredCategoriesResolveToSymbols() {
        #expect(device("Example-Washer").systemSymbol == "washer")
        #expect(device("Example-Camera").systemSymbol == "web.camera")
        #expect(device("Example-Vacuum").systemSymbol == "fan.floor")
    }
}
