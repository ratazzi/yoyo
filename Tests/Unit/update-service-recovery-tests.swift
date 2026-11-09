import Foundation

@main
struct UpdateServiceRecoveryTests {
    @MainActor static func main() async throws {
        let transient = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        var attempts = 0
        var waits: [UInt64] = []
        try await UpdateServiceRecovery.restore(shouldRestore: { true }, register: {
            attempts += 1
            if attempts == 1 { throw transient }
        }, wait: { waits.append($0) })
        assert(attempts == 2 && waits == [1_000_000_000], "Recover the observed post-update registration failure")

        attempts = 0; waits = []
        do {
            try await UpdateServiceRecovery.restore(shouldRestore: { true }, register: {
                attempts += 1; throw transient
            }, wait: { waits.append($0) })
            fatalError("Persistent failures must be reported")
        } catch { assert((error as NSError).domain == transient.domain) }
        assert(attempts == 4 && waits == [1_000_000_000, 2_000_000_000, 4_000_000_000])

        attempts = 0; waits = []
        do {
            try await UpdateServiceRecovery.restore(shouldRestore: { true }, register: {
                attempts += 1; throw NSError(domain: "SMAppServiceErrorDomain", code: 3)
            }, wait: { waits.append($0) })
            fatalError("Other service errors must not be retried")
        } catch { assert((error as NSError).code == 3) }
        assert(attempts == 1 && waits.isEmpty)

        attempts = 0
        var enabled = true
        try await UpdateServiceRecovery.restore(shouldRestore: { enabled }, register: {
            attempts += 1; throw transient
        }, wait: { _ in enabled = false })
        assert(attempts == 1, "Do not restore a service the user disabled while waiting")
        print("Update service recovery: transient failure, bounded retries, permanent error, user disable: PASS")
    }
}
