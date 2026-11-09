import Foundation
import ServiceManagement

@MainActor
enum UpdateServiceRecovery {
    static func restore(
        shouldRestore: () -> Bool,
        register: () throws -> Void,
        wait: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws {
        // macOS can return EPERM briefly even after unregister's completion.
        // https://developer.apple.com/forums/thread/783539
        for retry in 0...3 {
            try Task.checkCancellation()
            guard shouldRestore() else { return }
            do {
                try register()
                return
            } catch {
                let failure = error as NSError
                guard failure.domain == SMAppServiceErrorDomain, failure.code == Int(EPERM), retry < 3 else { throw error }
                try await wait(UInt64(1 << retry) * 1_000_000_000)
            }
        }
    }
}
