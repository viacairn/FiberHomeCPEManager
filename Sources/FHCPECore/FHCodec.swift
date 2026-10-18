import Foundation
import CommonCrypto
import Security

/// Independently implemented from RP0112 frontend wire behavior. No JavaScript is shipped or evaluated.
public enum FHCodec {
    private static let iv = Data("opqrstuvwxyz{|}~".utf8)
    public static func deriveKey(token: String, seed: String) throws -> String {
        let t = Array(token.utf8), s = Array(seed.utf8)
        guard t.count >= 32, s.count == 5, t.allSatisfy({ $0 >= 32 && $0 < 127 }), s.allSatisfy({ $0 >= 32 && $0 < 127 }) else { throw CPEError.crypto }
        var key: [UInt8] = [], index = 0
        for i in 0..<16 {
            let value: Int
            if [5, 7, 10, 11, 13].contains(i) {
                value = Int(s[index]) + Int(t[1]) % 3 - 1; index += 1
            } else if t.count > i * 4 + 2 { value = Int(t[t.count - 2 - i * 4]) - 1 }
            else { value = Int(t[i * 4 - 31]) + 1 }
            guard (1...127).contains(value) else { throw CPEError.crypto }
            key.append(UInt8(value))
        }
        return String(decoding: key, as: UTF8.self)
    }
    public static func encrypt(_ data: Data, key: String) throws -> String {
        try crypt(data, key: key, operation: CCOperation(kCCEncrypt)).map { String(format: "%02x", $0) }.joined()
    }
    public static func decrypt(_ hex: String, key: String) throws -> Data {
        let chars = Array(hex.utf8)
        guard !chars.isEmpty, chars.count % 32 == 0, chars.count <= 16_000_000 else { throw CPEError.crypto }
        var bytes = Data(); bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(decoding: chars[i...i+1], as: UTF8.self), radix: 16) else { throw CPEError.crypto }
            bytes.append(byte)
        }
        return try crypt(bytes, key: key, operation: CCOperation(kCCDecrypt))
    }
    private static func crypt(_ data: Data, key: String, operation: CCOperation) throws -> Data {
        let keyData = Data(key.utf8)
        guard keyData.count == 16 else { throw CPEError.crypto }
        var output = Data(count: data.count + 16), written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in data.withUnsafeBytes { input in keyData.withUnsafeBytes { key in iv.withUnsafeBytes { iv in
            CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key.baseAddress, 16, iv.baseAddress, input.baseAddress, data.count, out.baseAddress, capacity, &written)
        }}}}
        guard status == kCCSuccess else { throw CPEError.crypto }
        output.count = written; return output
    }
    /// The firmware's shared protocol constant as DER. It is protocol metadata (used to
    /// unwrap the negotiation seed), not a user secret or a TLS identity.
    public static func protocolKeyDER() -> Data? {
        guard let path = Bundle.module.url(forResource: "firmware-protocol", withExtension: "der") else { return nil }
        return try? Data(contentsOf: path)
    }

    public static func negotiationSeed(_ envelope: String) throws -> String {
        guard envelope.count > 6, let encrypted = Data(base64Encoded: String(envelope.dropFirst(6))),
              let path = Bundle.module.url(forResource: "firmware-protocol", withExtension: "der") else { throw CPEError.crypto }
        let der = try Data(contentsOf: path)
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes, &error),
              let plain = SecKeyCreateDecryptedData(key, .rsaEncryptionPKCS1, encrypted as CFData, &error) as Data?,
              let seed = String(data: plain, encoding: .utf8), seed.utf8.count == 5 else { throw CPEError.crypto }
        return seed
    }
}
