import Foundation
import Testing
@testable import AINotepadCore

/// Test için sayılabilir hata.
struct FlakyError: Error, Equatable {
    let attempt: Int
}

@MainActor
@Suite struct RetryTests {
    @Test func succeedsAfterTransientFailures() async throws {
        var attempts: Int = 0
        var warnings: [Int] = []
        try await retryWithBackoff(
            attempts: 3,
            delaySec: 0.01,
            isolation: MainActor.shared,
            operation: {
                attempts += 1
                if attempts < 3 { throw FlakyError(attempt: attempts) }
            },
            onFailure: { (attempt: Int, _: any Error) -> Void in warnings.append(attempt) }
        )
        #expect(attempts == 3)
        #expect(warnings == [1, 2])
    }

    @Test func throwsLastErrorWhenAllAttemptsFail() async {
        var attempts: Int = 0
        await #expect(throws: FlakyError(attempt: 3)) {
            try await retryWithBackoff(
                attempts: 3,
                delaySec: 0.01,
                isolation: MainActor.shared,
                operation: {
                    attempts += 1
                    throw FlakyError(attempt: attempts)
                },
                onFailure: { (_: Int, _: any Error) -> Void in }
            )
        }
        #expect(attempts == 3)
    }

    @Test func asyncOperationIsAwaited() async throws {
        var attempts: Int = 0
        try await retryWithBackoff(
            attempts: 3,
            delaySec: 0.01,
            isolation: MainActor.shared,
            operation: {
                try await Task.sleep(for: .milliseconds(10))
                attempts += 1
                if attempts < 2 { throw FlakyError(attempt: attempts) }
            },
            onFailure: { (_: Int, _: any Error) -> Void in }
        )
        #expect(attempts == 2)
    }
}
