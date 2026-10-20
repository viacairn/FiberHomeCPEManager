import Foundation

/// Client-side password sanity checks.
///
/// Input methods can convert ASCII punctuation into full-width forms. Validate before
/// sending credentials so unintended characters do not consume authentication attempts.
public enum PasswordInputIssue: Equatable, Sendable {
    case empty
    /// A full-width character (for example "，" U+FF0C) was found.
    case fullWidth(Character)
    /// The password starts or ends with whitespace.
    case surroundingWhitespace

    public var message: String {
        switch self {
        case .empty:
            return "请输入密码后再连接"
        case .fullWidth(let character):
            return "密码里有全角字符「\(character)」，请使用英文半角（例如逗号应为 ,）"
        case .surroundingWhitespace:
            return "密码首尾有空格，请删除空格后重试"
        }
    }
}

public enum PasswordInput {
    public static func issue(in password: String) -> PasswordInputIssue? {
        if password.isEmpty { return .empty }
        if let scalar = password.unicodeScalars.first(where: isFullWidth) {
            return .fullWidth(Character(scalar))
        }
        if password != password.trimmingCharacters(in: .whitespacesAndNewlines) {
            return .surroundingWhitespace
        }
        return nil
    }

    /// True for the full-width forms a Chinese IME produces (U+FF01…U+FF5E) and for the
    /// ideographic space/comma. ASCII passwords should never contain these.
    public static func isFullWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000, 0x3001: return true       // ideographic space, 、
        case 0xFF01...0xFF5E: return true      // ！ … ～ (includes ，)
        default: return false
        }
    }

    /// Converts full-width ASCII forms to their ASCII equivalents. Offered to the user as
    /// an explicit "改为半角" action; never applied silently.
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
