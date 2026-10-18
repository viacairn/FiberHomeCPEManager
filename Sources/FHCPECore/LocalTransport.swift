import Foundation

public protocol DeviceRPC: Sendable {
    func call(_ method: String, data: JSONValue, publicAccess: Bool) async throws -> JSONValue
}
/// Each connection owns a private, memory-only cookie jar. Redirects never carry credentials elsewhere.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
public actor LocalTransport: DeviceRPC {
    private let address: DeviceAddress
    private let session: URLSession
    private var seed: String?
    /// Serialises RPC calls instead of failing them.
    ///
    /// The wire protocol derives one envelope per request and the firmware dislikes
    /// interleaved sessions, so only one call may run at a time. The previous version
    /// *rejected* the second caller with `CPEError.busy`, which surfaced to users as
    /// "另一项操作正在进行" whenever the 1 Hz snapshot collided with an SMS reload.
    /// Callers now queue.
    private var inFlight = false
    private var closed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init(address: DeviceAddress) {
        self.address = address
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 6; config.timeoutIntervalForResource = 12
        config.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: config, delegate: RedirectBlocker(), delegateQueue: nil)
    }
    public func close() { closed = true; session.invalidateAndCancel(); seed = nil }
    private func request(_ path: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: address.url)?.absoluteURL,
              url.host == address.url.host, url.scheme == address.url.scheme, url.port == address.url.port else { throw CPEError.invalidAddress }
        var r = URLRequest(url: url)
        r.httpMethod = body == nil ? "GET" : "POST"; r.httpBody = body
        r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        r.setValue(address.url.absoluteString + "/login.html", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: r)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw CPEError.malformedResponse }
        if [301,302,303,307,308,401,403,418].contains(response.statusCode) { throw CPEError.authentication }
        guard (200..<300).contains(response.statusCode) else { throw CPEError.http(response.statusCode) }
        guard data.count <= 8_000_000 else { throw CPEError.malformedResponse }
        return data
    }
    private func acquire() async {
        if !inFlight { inFlight = true; return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            inFlight = false
        } else {
            // The next waiter keeps `inFlight` true and takes ownership.
            waiters.removeFirst().resume()
        }
    }

    public func call(_ method: String, data: JSONValue = .null, publicAccess: Bool = false) async throws -> JSONValue {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if seed == nil {
            let negotiation = try Self.decodeObject(await request("/fh_api/tmp/FHNCAPIS?ajaxmethod=is_encrypt"))
            guard let envelope = negotiation["data"].text else { throw CPEError.crypto }
            seed = try FHCodec.negotiationSeed(envelope)
        }
        let tokenReply = try Self.decodeObject(await request("/fh_api/tmp/FHNCAPIS?ajaxmethod=get_refresh_sessionid"))
        guard let token = tokenReply["sessionid"].text, let seed else { throw CPEError.crypto }
        let key = try FHCodec.deriveKey(token: token, seed: seed)
        let envelope = JSONValue.object(["ajaxmethod": .string(method), "dataObj": data, "sessionid": .string(token)])
        let body = try JSONEncoder().encode(envelope)
        let prefix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
        let wire = prefix + (try FHCodec.encrypt(body, key: key))
        let sign = method == "DO_WEB_LOGIN" || method == "DO_WEB_LOGOUT"
        let path = sign ? "/fh_api/sign/\(method)" : "/fh_api/tmp/\(publicAccess ? "FHNCAPIS" : "FHAPIS")"
        let reply = try await request(path, body: Data(wire.utf8))
        if sign { return try Self.decodeObject(reply) }
        // Session middleware can return a plain rejection or a login page instead of
        // the encrypted RPC object. Decode those before trying to decrypt the body.
        let text = String(data: reply, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.hasPrefix("{") || text.hasPrefix("<") {
            _ = try Self.decodeObject(reply)
            throw CPEError.malformedResponse
        }
        guard let cipher = String(data: reply, encoding: .utf8), cipher.count > 6 else { throw CPEError.malformedResponse }
        do {
            return try Self.decodeObject(FHCodec.decrypt(String(cipher.dropFirst(6)), key: key))
        } catch {
            // Distinguish a real malformed SMS payload from a displaced/expired session.
            // This extra read is only made on a decoding failure, never for every sample.
            if !publicAccess {
                do { _ = try await request("/fh_api/tmp/heartbeat") }
                catch CPEError.authentication { throw CPEError.authentication }
                catch { /* Preserve the original decoding error. */ }
            }
            throw error
        }
    }
    public static func decodeObject(_ data: Data) throws -> JSONValue {
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if prefix.hasPrefix("<html") || prefix.hasPrefix("<!doctype html") {
            if prefix.contains("login") || prefix.contains("index.html") { throw CPEError.authentication }
            throw CPEError.malformedResponse
        }
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = object else { throw CPEError.malformedResponse }
        if object["ERRORSTATUS"] != .null {
            if let status = object["ERRORSTATUS"].text, ["401", "403", "418"].contains(status) { throw CPEError.authentication }
            throw CPEError.rejected
        }
        return object
    }
}
