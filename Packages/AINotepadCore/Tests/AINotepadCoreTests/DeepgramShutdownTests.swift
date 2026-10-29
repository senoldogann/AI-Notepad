import Foundation
import Testing
@testable import AINotepadCore

@Suite struct DeepgramShutdownTests {
    // Jeton kapanış süresi (5 sn) dolduktan sonra gelirse geçersiz kılınmış oturumda WebSocket açılmaz (önceden
    // `NSGenericException` ile çöküyordu); akış ağa gitmeden sessizce biter.
    @Test func lateTokenAfterCloseDoesNotOpenSocket() async throws {
        let audio: AsyncStream<[Float]> = chunkedStream(samples: [], chunkSize: 1)
        let stream: DeepgramStream = startDeepgramStream(
            token: { () async throws -> String in
                try await Task.sleep(for: .seconds(6.5))
                return "gec-gelen-jeton"
            },
            options: developerDeepgramListenOptions, language: .finnish, keyterms: [], audio: audio
        )
        var failures: [String] = []
        for await event in stream.events {
            if case .failed(let message) = event {
                failures.append(message)
            }
        }
        #expect(failures.isEmpty)
        // Akış kapanış süresinde biter; jeton ondan sonra gelir ve bağlanma denenir: süreç o ana dek yaşamalı.
        try await Task.sleep(for: .seconds(2.5))
        #expect(!canOpenConnection(sessionInvalidated: true, closeDeadlinePassed: false, hasFailed: false))
        #expect(canOpenConnection(sessionInvalidated: false, closeDeadlinePassed: false, hasFailed: false))
    }
}
