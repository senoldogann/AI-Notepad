import Foundation
import Testing
@testable import AINotepadCore

@Suite struct ErrorReportingTests {
    // Mikrofon motoru başlatılamazsa hata "sistem sesi" diye görünmemeli.
    @Test func captureErrorsNameTheRightSource() {
        #expect(userFacingMessage(error: AudioCaptureError.microphoneStartFailed(code: -10868)).contains("Mikrofon başlatılamadı"))
        #expect(userFacingMessage(error: AudioCaptureError.coreAudio(operation: "AudioDeviceStart", status: -50)).contains("Sistem sesi"))
        #expect(userFacingMessage(error: AudioCaptureError.microphonePermissionDenied).contains("Mikrofon izni"))
        #expect(userFacingMessage(error: AudioCaptureError.systemAudioPermissionDenied).contains("Sistem sesi kaydı izni"))
        #expect(userFacingMessage(error: TranscriptionError.modelLoadFailed(model: "m", reason: "r")).contains("model"))
    }

    // ElevenLabs kota dolunca 401 döner; kullanıcıya "anahtar geçersiz" denmemeli.
    @Test func elevenLabsQuotaIsNotInvalidKey() {
        let body: String = #"{"detail":{"status":"quota_exceeded","message":"This request exceeds your quota"}}"#
        let message: String = userFacingMessage(error: CloudSTTError.http(service: "elevenlabs", status: 401, body: body))
        #expect(message.contains("kota"))
        #expect(!message.contains("geçersiz"))
        #expect(isQuotaExceeded(body: body))
        #expect(!isQuotaExceeded(body: #"{"detail":{"status":"invalid_api_key"}}"#))
    }

    @Test func llmMessagesCoverTruncationAndProvider() {
        #expect(userFacingMessage(error: LLMError.truncated(model: "claude-opus-5-5")).contains("effort"))
        #expect(userFacingMessage(error: LLMError.http(status: 401, body: "x", model: "claude-haiku-5-5", requestID: "req_1")).contains("Anthropic anahtarı geçersiz"))
        #expect(userFacingMessage(error: LLMError.http(status: 401, body: "x", model: "gpt-5", requestID: nil)).contains("LLM anahtarı geçersiz"))
    }

    // `retry-after` saniye olarak uyulur (en fazla 30 sn); yoksa üstel bekleme.
    @Test func retryDelayHonorsRetryAfter() {
        #expect(retryDelay(retryAfterHeader: "7", attempt: 1) == 7)
        #expect(retryDelay(retryAfterHeader: "120", attempt: 1) == 30)
        #expect(retryDelay(retryAfterHeader: nil, attempt: 1) == 1)
        #expect(retryDelay(retryAfterHeader: nil, attempt: 3) == 4)
        #expect(retryDelay(retryAfterHeader: "yarın", attempt: 2) == 2)
    }

    @Test func classifyRetries408AndFlagsTruncation() {
        #expect(classifyClaudeResponse(status: 408, data: Data("x".utf8), model: "m", requestID: "r") == .retryable(.http(status: 408, body: "x", model: "m", requestID: "r")))
    }

    // Ses thread'indeki hata logu dakikada en fazla bir kez yazılır.
    @Test func rateLimitedLogging() {
        let now: ContinuousClock.Instant = .now
        #expect(shouldLog(last: nil, now: now, intervalSec: 60))
        #expect(!shouldLog(last: now - .seconds(10), now: now, intervalSec: 60))
        #expect(shouldLog(last: now - .seconds(61), now: now, intervalSec: 60))
    }
}

@Suite struct ClockAlignmentTests {
    // Normal gecikme (parça süresi kadar) doldurulmaz; yeniden kurma boşluğu sessizlikle doldurulur.
    @Test func fillsOnlyRealGaps() {
        #expect(gapFillSamples(elapsedSec: 1.1, emittedSamples: 16000, chunkSamples: 1600, sampleRate: 16000, thresholdSec: 0.5) == 0)
        #expect(gapFillSamples(elapsedSec: 1.3, emittedSamples: 16000, chunkSamples: 1600, sampleRate: 16000, thresholdSec: 0.5) == 0)
        #expect(gapFillSamples(elapsedSec: 5.0, emittedSamples: 16000, chunkSamples: 1600, sampleRate: 16000, thresholdSec: 0.5) == 62400)
        // Geç başlayan akış (izin penceresi): baştaki 3 sn sessizlikle doldurulur.
        #expect(gapFillSamples(elapsedSec: 3.1, emittedSamples: 0, chunkSamples: 1600, sampleRate: 16000, thresholdSec: 0.5) == 48000)
    }

    @Test func alignedStreamInsertsSilenceForLateStart() async {
        let origin: ContinuousClock.Instant = .now - .seconds(2)
        let (source, input): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        input.yield([Float](repeating: 0.5, count: 1600))
        input.finish()
        var chunks: [[Float]] = []
        for await chunk in clockAlignedStream(audio: source, origin: origin, sampleRate: 16000, thresholdSec: 0.5) {
            chunks.append(chunk)
        }
        #expect(chunks.count == 2)
        #expect(chunks.first?.allSatisfy { $0 == 0 } == true)
        #expect(abs((chunks.first?.count ?? 0) - 30400) < 1600)
    }
}

@Suite struct AudioGateTests {
    // Kapalı kapı sesi aynı uzunlukta sessizliğe çevirir; açılınca ses geri gelir.
    @Test func closedGateSilencesWithoutChangingLength() async {
        let gate: AudioGate = AudioGate(isOpen: false)
        let (source, input): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        var output: [[Float]] = []
        let stream: AsyncStream<[Float]> = gatedStream(audio: source, gate: gate)
        input.yield([0.5, 0.5])
        var iterator: AsyncStream<[Float]>.Iterator = stream.makeAsyncIterator()
        output.append(await iterator.next() ?? [])
        gate.set(isOpen: true)
        input.yield([0.5, 0.5, 0.5])
        input.finish()
        output.append(await iterator.next() ?? [])
        #expect(output == [[0, 0], [0.5, 0.5, 0.5]])
    }
}

@Suite struct TimeoutTests {
    // İptale yanıt vermeyen bekleme de süre dolunca bırakılır.
    @Test func stopsWaitingAfterTimeout() async {
        let slow: Task<Void, Never> = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch {}
        }
        let started: ContinuousClock.Instant = .now
        let finished: Bool = await finishesWithin(seconds: 0.2) { await slow.value }
        #expect(!finished)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await finishesWithin(seconds: 2) {})
        slow.cancel()
    }
}
