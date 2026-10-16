import Foundation

/// The adapter must supply firmware-proven reads and writes. No transport guesses here.
public protocol LockBackend: Sendable {
    func readMode() async throws -> LockMode
    func disableLocks() async throws
    func apply(_ mode: LockMode) async throws
}
public actor LockCoordinator {
    private let backend: any LockBackend
    private var busy = false
    public init(backend: any LockBackend) { self.backend = backend }
    public func change(to desired: LockMode) async throws {
        guard desired != .unknown else { throw CPEError.rejected }
        guard !busy else { throw CPEError.busy }; busy = true; defer { busy = false }
        let current = try await backend.readMode()
        guard current != .unknown else { throw CPEError.uncertain }
        if current == desired { return }
        if current != .automatic {
            try await backend.disableLocks()
            guard try await backend.readMode() == .automatic else { throw CPEError.uncertain }
        }
        try Task.checkCancellation()
        if desired != .automatic { try await backend.apply(desired) }
        guard try await backend.readMode() == desired else { throw CPEError.uncertain }
    }
}
