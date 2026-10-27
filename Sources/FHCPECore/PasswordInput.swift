import Foundation

/// Client-side password sanity checks.
///
/// Input methods can convert ASCII punctuation into full-width forms. Validate before
/// sending credentials so unintended characters do not consume authentication attempts.
public enum PasswordInputIssue: Equatable, Sendable {
    case empty

    public var message: String {
        switch self {
        case .empty:
            return "请输入密码后再连接"

        }
    }
}

public enum PasswordInput {
    public static func issue(in password: String) -> PasswordInputIssue? {
        if password.isEmpty { return .empty }
        return nil
    }

    /// Converts full-width ASCII forms to their ASCII equivalents for login entry and
    /// submission, including punctuation produced by an input method.
    public static func halfWidth(_ password: String) -> String {
        var result = ""
        for scalar in password.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E:
                if let converted = Unicode.Scalar(scalar.value - 0xFEE0) {
                    result.unicodeScalars.append(converted)
                }
            case 0x3000:
                result.append(" ")
            case 0x3001:
                result.append(",")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
