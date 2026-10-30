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
            options: developerDeepgramListenOptions, language: .finnish, keyterms: [], onConnectionEvent: { (_: DeepgramConnectionEvent) -> Void in }, audio: audio
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

    // Kısa ağ kesintisinde jeton alınamazsa bağlanma bütçesi içinde yeniden denenir (Mac'e hemen geçilmez); sunucunun
    // bilerek verdiği ret (ör. Deepgram bütçesi doldu) hemen bildirilir.
    @Test func transientTokenFailuresAreRetried() async throws {
        let calls: Counter = Counter()
        let audio: AsyncStream<[Float]> = AsyncStream { (continuation: AsyncStream<[Float]>.Continuation) -> Void in
            Task {
                try? await Task.sleep(for: .seconds(4))
                continuation.finish()
            }
        }
        let rejection: HostedAPIError = HostedAPIError(code: .rateLimited, rawCode: "rate_limited", status: 429, serverMessage: "", path: "/v1/live/deepgram-token")
        let stream: DeepgramStream = startDeepgramStream(
            token: { () async throws -> String in
                let call: Int = await calls.increment()
                if call <= 2 {
                    throw HostedClientError.network(path: "/v1/live/deepgram-token", reason: "çevrimdışı")
                }
                throw rejection
            },
            options: developerDeepgramListenOptions, language: .finnish, keyterms: [], onConnectionEvent: { (_: DeepgramConnectionEvent) -> Void in }, audio: audio
        )
        var failures: [String] = []
        for await event in stream.events {
            if case .failed(let message) = event {
                failures.append(message)
            }
        }
        #expect(await calls.value == 3)
        #expect(failures == [userFacingMessage(error: rejection)])
        #expect(isTransientDeepgramTokenFailure(error: DeepgramTokenError(underlying: URLError(.notConnectedToInternet))))
        #expect(isTransientDeepgramTokenFailure(error: DeepgramTokenError(underlying: HostedAPIError(code: nil, rawCode: "http_502", status: 502, serverMessage: "", path: "/"))))
        #expect(!isTransientDeepgramTokenFailure(error: DeepgramTokenError(underlying: rejection)))
    }
}

/// Eşzamanlı sayaç (testte jeton çağrıları).
private actor Counter {
    private(set) var value: Int = 0

    func increment() -> Int {
        value += 1
        return value
    }
}
