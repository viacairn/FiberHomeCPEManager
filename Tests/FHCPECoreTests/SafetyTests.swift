import Testing
import Foundation
@testable import FHCPECore

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
