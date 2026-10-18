import Foundation
import SystemConfiguration

/// Reads the current default gateway from the system's network state.
///
/// Used by the login page's 探测网关 button: the CPE is almost always the Mac's default
/// router, so this saves the user from looking the address up on the sticker.
public enum GatewayDetector {
    public static func defaultGateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "local.fhcpem.app" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString),
              let dictionary = value as? [String: Any],
              let router = dictionary["Router"] as? String,
              !router.isEmpty
        else { return nil }
        return router
    }
}
