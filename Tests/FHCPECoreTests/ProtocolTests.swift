import Testing
import Foundation
@testable import FHCPECore

@Test func addressValidation() throws {
    #expect(try DeviceAddress("192.168.8.1").url.absoluteString == "http://192.168.8.1")
    #expect(try DeviceAddress("https://router.local:8443/").url.port == 8443)
    for value in ["file:///etc/passwd", "http://user:pass@192.168.8.1", "http://192.168.8.1/path", "http://example.com?token=x", "http://192.168.8.1:0"] {
        #expect(throws: Error.self) { try DeviceAddress(value) }
    }
}
@Test func firmwareGoldenCrypto() throws {
    let token = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    let key = try FHCodec.deriveKey(token: token, seed: "hU3S9")
    #expect(key == "73/VRiJVB74Tv:nj")
    let plain = Data("{\"method\":\"get_device_info\",\"sessionid\":\"test\"}".utf8)
    let cipher = try FHCodec.encrypt(plain, key: key)
    #expect(cipher == "a9c08d6e7256f9948ced9c6bd23ca2e78b39fff3244084cb8efdc3851bff522d4c1687bf3515c5cd153298910ef2a7bd")
    #expect(try FHCodec.decrypt(cipher, key: key) == plain)
}
@Test func malformedCryptoFailsClosed() {
    #expect(throws: Error.self) { try FHCodec.deriveKey(token: "short", seed: "abcde") }
    #expect(throws: Error.self) { try FHCodec.decrypt("zz", key: "0123456789abcdef") }
}
@Test func trafficResetDoesNotSpike() {
    var counter = TrafficCounter()
    #expect(counter.update(bytes: 1000, time: 1) == nil)
    #expect(counter.update(bytes: 1600, time: 3) == 300)
    #expect(counter.update(bytes: 20, time: 4) == nil)
    #expect(counter.update(bytes: 220, time: 6) == 100)
}

@Test func optionalReadOnlyHardwareProbe() async throws {
    guard ProcessInfo.processInfo.environment["FHCPEM_PROBE"] == "1" else { return }
    let transport = LocalTransport(address: try DeviceAddress("http://192.168.8.1"))
    let model = try await LG6851Adapter(rpc: transport).identify()
    #expect(model == "LG6851F")
    await transport.close()
}

@Test func recordedNegotiation() throws {
 #expect(try FHCodec.negotiationSeed("L5HSr1TPszXtmvU0Y6kJXa0EwWv3edCAOzOCDJSovuLqGvBMkubOg22BPMu+ZI4743ld1t4n/hXpwOzE1hk9lFgnQm9MwXrmcthyudBJALDrDUovVvBy1W0Wc3+6noDa6o5yXl78Iy9+5Zm77uef+34BPgls5JkWQvBchbBfFNncC9p+IJ8yZyKSmiN7TGC8Nwi2t8LOQM0bxkp7HHFEUX7oUmP7IWRTN5mP7RvNMuiYhLp/XBr3AfDHR+WL+m80cRFJmz2yL2fslOYvD/MSnrUxV8FaJPphlvRcjApEDNiJl6my6axrfocjMoxMiDXgVmdzA6JYGZT5LfI6B9fcjffgOlGQ==") == "hU3S9")
}
