import Testing
import Foundation
@testable import FHCPECore

actor FakeLock: LockBackend {
    var mode: LockMode = .bands(lte: [3], nr: [])
    var failDisable = false, mismatch = false, writes = 0
    init(failDisable: Bool = false, mismatch: Bool = false) { self.failDisable = failDisable; self.mismatch = mismatch }
    func readMode() -> LockMode { mode }
    func disableLocks() throws { if failDisable { throw CPEError.rejected }; mode = .automatic }
    func apply(_ requested: LockMode) { writes += 1; if !mismatch { mode = requested } }
}
@Test func unlockFailureNeverAppliesOtherLock() async {
    let backend = FakeLock(failDisable: true), desired = LockMode.cell(rat: 2, arfcn: 627264, pci: 1)
    await #expect(throws: Error.self) { try await LockCoordinator(backend: backend).change(to: desired) }
    #expect(await backend.writes == 0)
}
@Test func readbackMismatchIsNotSuccess() async {
    let backend = FakeLock(mismatch: true)
    await #expect(throws: Error.self) { try await LockCoordinator(backend: backend).change(to: .cell(rat: 2, arfcn: 627264, pci: 1)) }
}
@Test func lockSwitchConfirmsNewMode() async throws {
    let backend = FakeLock(), desired = LockMode.cell(rat: 2, arfcn: 627264, pci: 1)
    try await LockCoordinator(backend: backend).change(to: desired)
    #expect(await backend.mode == desired)
}
@Test func loginPageCannotMasqueradeAsData() {
    #expect(throws: Error.self) { try LocalTransport.decodeObject(Data("<html>Login</html>".utf8)) }
    #expect(throws: Error.self) { try LocalTransport.decodeObject(Data("[]".utf8)) }
}

@Test func expiredLoginHTMLIsAnAuthenticationFailure() {
    #expect(throws: CPEError.authentication) {
        try LocalTransport.decodeObject(Data("<!doctype html><html><form action=\"/login.html\">Login</form></html>".utf8))
    }
}

@Test func smsMayContainHTMLWithoutBecomingALoginResponse() throws {
    let reply = try LocalTransport.decodeObject(Data("{\"session_item_1\":{\"session_phone\":\"10010\",\"message_item_1\":{\"msg_content\":\"<html>Login</html>\"}}}".utf8))
    #expect(reply["session_item_1"]["message_item_1"]["msg_content"].text == "<html>Login</html>")
}
