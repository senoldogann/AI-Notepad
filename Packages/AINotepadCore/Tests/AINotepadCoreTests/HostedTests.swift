import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

/// Verilen süre ve hızda stereo sinüs kaydı (Float32) yazar; dosya yolu döner.
private func writeSineRecording(directory: URL, seconds: Double, sampleRate: Double) throws -> URL {
    let url: URL = directory.appending(path: "kayit.caf")
    let format: AVAudioFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
    let frames: AVAudioFrameCount = AVAudioFrameCount(seconds * sampleRate)
    let buffer: AVAudioPCMBuffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    for channel in 0..<2 {
        let samples: UnsafeMutablePointer<Float> = try #require(buffer.floatChannelData?[channel])
        for frame in 0..<Int(frames) {
            samples[frame] = 0.3 * sin(2 * Float.pi * 440 * Float(frame) / Float(sampleRate))
        }
    }
    let file: AVAudioFile = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
}

/// Küçük uçlu tam sayı okur.
private func littleEndian32(_ data: Data, at offset: Int) -> Int {
    data[offset..<(offset + 4)].enumerated().reduce(0) { (sum: Int, item: (offset: Int, element: UInt8)) -> Int in
        sum | Int(item.element) << (8 * item.offset)
    }
}

private func word(_ text: String, _ start: Double, _ end: Double, _ speaker: String) -> DiarizedWord {
    DiarizedWord(text: text, startSec: start, endSec: end, speaker: speaker)
}

private func tokens(accessExpiresAt: Date) -> HostedTokens {
    HostedTokens(accessToken: "erisim", refreshToken: "yenileme", accessExpiresAt: accessExpiresAt, userId: "kullanici")
}

private func llmRequest(tier: LLMTier, schema: String?) -> LLMRequest {
    LLMRequest(tier: tier, system: "sistem", userText: "metin", maxTokens: 2048, jsonSchema: schema, timeoutSec: 20)
}

@Suite struct HostedAudioTests {
    @Test func chunkSpansCoverRecordingWithoutGaps() {
        #expect(wavChunkSpans(totalSamples: 10, maxSamples: 4, overlapSamples: 0) == [
            WavChunkSpan(startSample: 0, sampleCount: 4), WavChunkSpan(startSample: 4, sampleCount: 4), WavChunkSpan(startSample: 8, sampleCount: 2),
        ])
        #expect(wavChunkSpans(totalSamples: 0, maxSamples: 4, overlapSamples: 1).isEmpty)
        #expect(wavChunkSpans(totalSamples: 4, maxSamples: 4, overlapSamples: 1) == [WavChunkSpan(startSample: 0, sampleCount: 4)])
        // Örtüşen parçalar: her parça öncekinin son örneğiyle başlar.
        #expect(wavChunkSpans(totalSamples: 10, maxSamples: 4, overlapSamples: 1) == [
            WavChunkSpan(startSample: 0, sampleCount: 4), WavChunkSpan(startSample: 3, sampleCount: 4), WavChunkSpan(startSample: 6, sampleCount: 4),
        ])
    }

    // 95 MB'lık WAV, 16 kHz mono 16 bitte ~49 dakikadır; başlıkla birlikte sınırı aşmaz.
    @Test func chunkLimitFitsServerMaximum() {
        let samples: Int = maxSamplesPerWavChunk(maxBytes: hostedTranscribeMaxBytes)
        #expect(44 + samples * 2 <= hostedTranscribeMaxBytes)
        let minutes: Double = Double(samples) / Double(hostedTranscribeSampleRate) / 60
        #expect(minutes > 49 && minutes < 50)
    }

    // 48 kHz stereo kayıt 16 kHz mono WAV parçalarına bölünür: her parça sınırda, başlık gerçek boyutu taşır, konumlar ardışık.
    @Test func recordingIsWrittenAsBoundedWavChunks() throws {
        let directory: URL = FileManager.default.temporaryDirectory.appending(path: "hosted-wav-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source: URL = try writeSineRecording(directory: directory, seconds: 2.5, sampleRate: 48000)
        let maxBytes: Int = 44 + 16000 * 2
        let overlap: Int = 4000
        let chunks: [WavChunkFile] = try writeHostedWavChunks(source: source, directory: directory, maxBytes: maxBytes, overlapSamples: overlap)
        #expect(chunks.count == 3)
        var expectedStart: Int = 0
        var previousTail: Data?
        for chunk in chunks {
            let data: Data = try Data(contentsOf: chunk.url)
            #expect(data.count <= maxBytes)
            #expect(data.count == 44 + chunk.span.sampleCount * 2)
            #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
            #expect(littleEndian32(data, at: 4) == data.count - 8)
            #expect(littleEndian32(data, at: 24) == hostedTranscribeSampleRate)
            #expect(littleEndian32(data, at: 40) == chunk.span.sampleCount * 2)
            #expect(chunk.span.startSample == expectedStart)
            // Parça öncekinin son çeyrek saniyesiyle başlar (aynı örnekler).
            if let previousTail {
                #expect(data.subdata(in: 44..<(44 + overlap * 2)) == previousTail)
            }
            previousTail = data.subdata(in: (data.count - overlap * 2)..<data.count)
            expectedStart += chunk.span.sampleCount - overlap
        }
        #expect(chunks.map { $0.span.offsetSec(sampleRate: hostedTranscribeSampleRate) }.prefix(2) == [0, 0.75])
        // Örnek hızı dönüştürücüsü uçlarda birkaç örnek oynatabilir.
        #expect(abs(expectedStart + overlap - 40000) < 200)
        try FileManager.default.removeItem(at: directory)
    }

    // Ortak dakikada aynı kelimeleri söyleyen etiketler aynı kişidir (ElevenLabs etiketleri parçada farklı olsa da);
    // ortak bölgede konuşmayan kişi yeni kişi kalır; ortak bölgenin kelimeleri bir kez yazılır.
    @Test func overlappingChunksKeepSpeakersAcrossBoundary() {
        let first: DiarizationResult = DiarizationResult(words: [
            word("Aino1", 10, 11, "speaker_0"), word("Mika1", 2950, 2951, "speaker_1"),
            word("Aino2", 2970, 2972, "speaker_0"), word("Mika2", 2990, 2992, "speaker_1"), word("Aino3", 3010, 3012, "speaker_0"),
        ], languageCode: "fin", languageProbability: 0.9)
        // İkinci parça 2968'de başlar, 60 sn örtüşür; etiketler yer değiştirmiş, yeni bir kişi (speaker_2) var.
        let second: DiarizationResult = DiarizationResult(words: [
            word("Aino2", 2, 4, "speaker_1"), word("Mika2", 22, 24, "speaker_0"), word("Aino3", 42, 44, "speaker_1"),
            word("Mika3", 70, 71, "speaker_0"), word("Uusi", 80, 81, "speaker_2"),
        ], languageCode: "fin", languageProbability: 0.8)
        let merged: DiarizationResult = mergeChunkTranscriptions(chunks: [
            ChunkTranscription(offsetSec: 0, overlapSec: 0, result: first),
            ChunkTranscription(offsetSec: 2968, overlapSec: 60, result: second),
        ])
        #expect(merged.words.map(\.text) == ["Aino1", "Mika1", "Aino2", "Mika2", "Aino3", "Mika3", "Uusi"])
        #expect(merged.words.map(\.speaker) == ["speaker_0", "speaker_1", "speaker_0", "speaker_1", "speaker_0", "speaker_1", "2:speaker_2"])
        // Karışık ya da az oy eşleme yapmaz.
        #expect(overlapSpeakerMapping(previous: [word("a", 0, 1, "x")], current: [word("a", 0, 1, "y")]).isEmpty)
    }

    // Parça sonuçları kaydın zamanına kaydırılır; ortak konuşma yoksa konuşmacılar parçalar arasında karışmaz; dil en olası parçanınki.
    @Test func chunkResultsMergeWithOffsets() {
        let merged: DiarizationResult = mergeChunkTranscriptions(chunks: [
            ChunkTranscription(offsetSec: 0, overlapSec: 0, result: DiarizationResult(words: [word("Hei", 0.5, 0.9, "speaker_0")], languageCode: "fin", languageProbability: 0.6)),
            ChunkTranscription(offsetSec: 2968.5, overlapSec: 0, result: DiarizationResult(
                words: [word("Moi", 1, 1.4, "speaker_0"), word("Joo", 2, 2.2, "speaker_1")], languageCode: "swe", languageProbability: 0.9
            )),
        ])
        #expect(merged.words == [
            word("Hei", 0.5, 0.9, "speaker_0"), word("Moi", 2969.5, 2969.9, "2:speaker_0"), word("Joo", 2970.5, 2970.7, "2:speaker_1"),
        ])
        #expect(merged.languageCode == "swe")
        #expect(merged.languageProbability == 0.9)
        // Son geçiş bölümlerinde ikinci parçanın konuşmacısı ilkinden ayrı kişidir.
        #expect(finalSegments(words: merged.words, gapSec: 1.5).map(\.person) == [1, 2, 3])
    }

    @Test func keytermsMatchServerRules() {
        #expect(hostedKeyterms(terms: [" Aino ", "aino", "", "a{b}", String(repeating: "x", count: 50), "bir iki üç dört beş altı", "Kone Oyj"], limit: 5) == ["Aino", "Kone Oyj"])
        #expect(hostedKeyterms(terms: ["a", "b", "c"], limit: 2) == ["a", "b"])
    }

    // Anahtar terimler adreste değil, başlıkta: UTF-8 JSON dizisinin dolgusuz base64url'i.
    @Test func transcribeKeytermsGoInHeader() throws {
        let url: URL = hostedTranscribeURL(baseURL: try #require(URL(string: "http://localhost:8787")), languageCode: "fin")
        #expect(url.absoluteString == "http://localhost:8787/v1/transcribe?language_code=fin&diarize=true")
        #expect(try hostedKeytermsHeader(keyterms: []) == nil)
        let header: String = try #require(try hostedKeytermsHeader(keyterms: ["C++ & Go", "Äino?"]))
        #expect(!header.contains("=") && !header.contains("+") && !header.contains("/"))
        let standard: String = header.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded: String = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        let decoded: [String] = try JSONDecoder().decode([String].self, from: try #require(Data(base64Encoded: padded)))
        #expect(decoded == ["C++ & Go", "Äino?"])
    }
}

@Suite struct HostedErrorTests {
    @Test func everyServerCodeHasActionableMessage() {
        for code in HostedErrorCode.allCases {
            let message: String = hostedErrorMessage(error: HostedAPIError(code: code, rawCode: code.rawValue, status: 400, serverMessage: "", path: "/v1/x"))
            #expect(!message.isEmpty, "mesaj yok: \(code.rawValue)")
        }
    }

    @Test func specificCodesSayWhatToDo() {
        func message(_ code: HostedErrorCode, _ status: Int) -> String {
            hostedErrorMessage(error: HostedAPIError(code: code, rawCode: code.rawValue, status: status, serverMessage: "", path: "/v1/meetings/start"))
        }
        #expect(message(.trialExhausted, 402).contains("abone ol"))
        // Deneme koşulları sunucu ayarından gelir; hata metnine sabit yazılmaz.
        #expect(!message(.trialExhausted, 402).contains("7 gün"))
        #expect(message(.trialNotStarted, 403).contains("önce bir toplantı"))
        #expect(message(.trialIPLimit, 429).contains("Yarın"))
        #expect(message(.trialDeviceUsed, 403).contains("abone ol"))
        #expect(hostedDeviceCheckMessage(error: .unsupported).contains("Abone"))
        #expect(message(.monthlyCapReached, 429).contains("ay başında"))
        #expect(message(.subscriptionExists, 409).contains("Hesabı yönet"))
        #expect(message(.spendCeilingReached, 503).contains("yoğun"))
        #expect(message(.trialCapacityReached, 503).contains("abone ol"))
        #expect(message(.meetingNotActive, 409).contains("Tekrar işle"))
        #expect(message(.transcriptionClosed, 409).contains("Canlı metin"))
    }

    @Test func parsesServerErrorBody() {
        let error: HostedAPIError = parseHostedAPIError(status: 402, data: Data(#"{"error":{"code":"trial_exhausted","message":"Deneme bitti."}}"#.utf8), path: "/v1/meetings/start")
        #expect(error == HostedAPIError(code: .trialExhausted, rawCode: "trial_exhausted", status: 402, serverMessage: "Deneme bitti.", path: "/v1/meetings/start"))
        let unknown: HostedAPIError = parseHostedAPIError(status: 418, data: Data(#"{"error":{"code":"yeni_kod","message":"?"}}"#.utf8), path: "/v1/me")
        #expect(unknown.code == nil && unknown.rawCode == "yeni_kod")
        let proxy: HostedAPIError = parseHostedAPIError(status: 502, data: Data("<html>Bad gateway</html>".utf8), path: "/v1/me")
        #expect(proxy.code == nil && proxy.rawCode == "http_502" && proxy.serverMessage.contains("Bad gateway"))
        // Kullanıcı metninde teknik ayrıntı (HTTP kodu) yok; ne yapılacağı yazar. Kod loglarda ve Tanılama'da kalır.
        #expect(!hostedErrorMessage(error: proxy).contains("502") && hostedErrorMessage(error: proxy).contains("yeniden dene"))
    }

    // Hız sınırı ve geçici sunucu hataları yeniden denenir; harcama tavanı (503) ve kotalar denenmez.
    @Test func onlyTransientErrorsRetry() {
        func error(_ code: HostedErrorCode?, _ status: Int) -> HostedAPIError {
            HostedAPIError(code: code, rawCode: code?.rawValue ?? "http_\(status)", status: status, serverMessage: "", path: "/v1/llm/messages")
        }
        #expect(isRetryableHostedError(error: error(.rateLimited, 429)))
        #expect(isRetryableHostedError(error: error(.upstreamUnavailable, 502)))
        #expect(isRetryableHostedError(error: error(nil, 503)))
        #expect(!isRetryableHostedError(error: error(.spendCeilingReached, 503)))
        #expect(!isRetryableHostedError(error: error(.monthlyCapReached, 429)))
        #expect(!isRetryableHostedError(error: error(.meetingNotActive, 409)))
    }

    @Test func closedAccessStopsLiveTranslation() {
        func hosted(_ code: HostedErrorCode) -> LLMError {
            .hosted(HostedAPIError(code: code, rawCode: code.rawValue, status: 409, serverMessage: "", path: "/v1/llm/messages"))
        }
        #expect(stopsLiveTranslation(error: hosted(.meetingBudgetExhausted)))
        #expect(stopsLiveTranslation(error: hosted(.spendCeilingReached)))
        #expect(stopsLiveTranslation(error: HostedClientError.noActiveMeeting))
        #expect(stopsLiveTranslation(error: LLMError.http(status: 401, body: "", model: "m", requestID: nil)))
        #expect(!stopsLiveTranslation(error: hosted(.upstreamUnavailable)))
        #expect(!stopsLiveTranslation(error: HostedClientError.network(path: "/v1/llm/messages", reason: "zaman aşımı")))
        #expect(!stopsLiveTranslation(error: LLMError.http(status: 500, body: "", model: "m", requestID: nil)))
    }
}

@Suite struct HostedLLMTests {
    // Canlı çeviri, "Ne kaçırdım?" ve toplantı sorusu `low`; not ve düzenleme `medium` (sunucu yalnızca ikisini kabul eder).
    @Test func effortFollowsTier() {
        #expect(hostedEffort(tier: .fast) == .low)
        #expect(hostedEffort(tier: .live) == .low)
        #expect(hostedEffort(tier: .smart) == .medium)
        #expect(translationRequest(sentence: "Hei", context: [], language: .turkish).tier == .fast)
    }

    @Test func requestCarriesEffortMeetingAndAllowedFieldsOnly() throws {
        let schema: String = #"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"],"additionalProperties":false}"#
        let urlRequest: URLRequest = try hostedLLMURLRequest(
            baseURL: try #require(URL(string: "http://localhost:8787")),
            credentials: HostedLLMCredentials(accessToken: "jeton", meetingID: "6f1c2b8e-1d2a-4c55-9a9e-2b6a0f4d8c11"),
            request: llmRequest(tier: .smart, schema: schema)
        )
        #expect(urlRequest.url?.absoluteString == "http://localhost:8787/v1/llm/messages")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "authorization") == "Bearer jeton")
        #expect(urlRequest.value(forHTTPHeaderField: "x-meeting-id") == "6f1c2b8e-1d2a-4c55-9a9e-2b6a0f4d8c11")
        let body: [String: Any] = try jsonObject(try #require(urlRequest.httpBody))
        #expect(Set(body.keys) == ["effort", "system", "messages", "max_tokens", "output_config", "stream"])
        #expect(body["effort"] as? String == "medium")
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 2048)
        // Sunucu sınırının üstündeki istek sınıra iner (toplantı 8192, hesap 6144).
        let large: LLMRequest = LLMRequest(tier: .smart, system: "s", userText: "u", maxTokens: 16_000, jsonSchema: nil, timeoutSec: 30)
        let local: URL = try #require(URL(string: "http://localhost:8787"))
        let meetingRequest: URLRequest = try hostedLLMURLRequest(baseURL: local, credentials: HostedLLMCredentials(accessToken: "j", meetingID: "m"), request: large)
        let largeMeeting: [String: Any] = try jsonObject(try #require(meetingRequest.httpBody))
        #expect(largeMeeting["max_tokens"] as? Int == hostedMeetingMaxTokens)
        let accountRequest: URLRequest = try hostedLLMURLRequest(baseURL: local, credentials: HostedLLMCredentials(accessToken: "j", meetingID: nil), request: large)
        let largeAccount: [String: Any] = try jsonObject(try #require(accountRequest.httpBody))
        #expect(largeAccount["max_tokens"] as? Int == hostedAccountMaxTokens)
        let messages: [[String: Any]] = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1 && messages[0]["role"] as? String == "user")
        let format: [String: Any] = try #require((body["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")

        let live: URLRequest = try hostedLLMURLRequest(
            baseURL: try #require(URL(string: "https://api.ornek.fi")),
            credentials: HostedLLMCredentials(accessToken: "jeton", meetingID: "m"),
            request: llmRequest(tier: .live, schema: nil)
        )
        let liveBody: [String: Any] = try jsonObject(try #require(live.httpBody))
        #expect(liveBody["effort"] as? String == "low")
        #expect(liveBody["output_config"] == nil)

        // Hesap çağrısı (Sor, notu yeniden yazma…) toplantı başlığı taşımaz.
        let account: URLRequest = try hostedLLMURLRequest(
            baseURL: try #require(URL(string: "https://api.ornek.fi")),
            credentials: HostedLLMCredentials(accessToken: "jeton", meetingID: nil),
            request: llmRequest(tier: .smart, schema: nil)
        )
        #expect(account.value(forHTTPHeaderField: "x-meeting-id") == nil)
        #expect(account.value(forHTTPHeaderField: "authorization") == "Bearer jeton")
    }

    // Sunucu Anthropic akışını aynen iletir; hata gövdesi sunucunun kodudur.
    @Test func classifiesProxiedStreamAndServerErrors() {
        let ok: LLMOutcome = classifyHostedLLMResponse(status: 200, data: completeStream(texts: ["Mer", "haba"], stopReason: "end_turn"), requestID: nil)
        #expect(ok == .success("Merhaba"))
        let budget: LLMOutcome = classifyHostedLLMResponse(status: 402, data: Data(#"{"error":{"code":"meeting_budget_exhausted","message":"x"}}"#.utf8), requestID: nil)
        guard case .final(.hosted(let error)) = budget else {
            Issue.record("bütçe hatası kesin olmalı: \(budget)")
            return
        }
        #expect(error.code == .meetingBudgetExhausted)
        let limited: LLMOutcome = classifyHostedLLMResponse(status: 429, data: Data(#"{"error":{"code":"rate_limited","message":"x"}}"#.utf8), requestID: nil)
        guard case .retryable(.hosted) = limited else {
            Issue.record("hız sınırı yeniden denenmeli: \(limited)")
            return
        }
    }
}

@Suite struct HostedTokenTests {
    @Test func actionDependsOnExpiry() {
        let now: Date = Date(timeIntervalSince1970: 1_000_000)
        #expect(hostedTokenAction(tokens: nil, now: now, leewaySec: 60) == .signedOut)
        #expect(hostedTokenAction(tokens: tokens(accessExpiresAt: now.addingTimeInterval(600)), now: now, leewaySec: 60) == .use(accessToken: "erisim"))
        #expect(hostedTokenAction(tokens: tokens(accessExpiresAt: now.addingTimeInterval(30)), now: now, leewaySec: 60) == .refresh(refreshToken: "yenileme"))
        #expect(hostedTokenAction(tokens: tokens(accessExpiresAt: now.addingTimeInterval(-5)), now: now, leewaySec: 60) == .refresh(refreshToken: "yenileme"))
    }

    // Yeni jetonlar saklanır; 401 (süresi dolmuş, çıkılmış ya da yeniden kullanıldığı için tüm aile düşmüş) oturumu
    // bitirir; geçici hata oturumu korur.
    @Test func refreshOutcomes() throws {
        let received: Date = Date(timeIntervalSince1970: 2_000_000)
        let body: Data = Data(#"{"accessToken":"a2","refreshToken":"r2","tokenType":"Bearer","expiresIn":900,"userId":"u"}"#.utf8)
        #expect(try hostedRefreshResult(status: 200, data: body, receivedAt: received)
            == .refreshed(HostedTokens(accessToken: "a2", refreshToken: "r2", accessExpiresAt: received.addingTimeInterval(900), userId: "u")))
        let reused: HostedRefreshResult = try hostedRefreshResult(status: 401, data: Data(#"{"error":{"code":"invalid_token","message":"x"}}"#.utf8), receivedAt: received)
        guard case .revoked(let error) = reused else {
            Issue.record("401 oturumu bitirmeli: \(reused)")
            return
        }
        #expect(error.code == .invalidToken)
        guard case .failed = try hostedRefreshResult(status: 503, data: Data(#"{"error":{"code":"internal_error","message":"x"}}"#.utf8), receivedAt: received) else {
            Issue.record("geçici hata oturumu korumalı")
            return
        }
        #expect(throws: HostedClientError.self) {
            try hostedRefreshResult(status: 200, data: Data("{}".utf8), receivedAt: received)
        }
    }

    // Toplantı başlatma ve nonce ile giriş zaman aşımında yinelenmez; yenileme tekrarı zararsız isteklerdendir (sunucu
    // yanıtı kaybolan yenilemenin jetonunu 10 dakika yeniden kabul eder).
    @Test func oneShotRequestsRetryOnlyWhenNotSent() {
        #expect(isRetryableOneShotRequest(failure: .network(.cannotConnectToHost)))
        #expect(!isRetryableOneShotRequest(failure: .network(.timedOut)))
        #expect(isRetryableOneShotRequest(failure: .server(HostedAPIError(code: .rateLimited, rawCode: "rate_limited", status: 429, serverMessage: "", path: "/v1/auth/refresh"))))
        #expect(!isRetryableOneShotRequest(failure: .server(HostedAPIError(code: .internalError, rawCode: "internal_error", status: 500, serverMessage: "", path: "/v1/auth/refresh"))))
        #expect(isRetryableRepeatableRequest(failure: .network(.timedOut)))
        #expect(!isRetryableRepeatableRequest(failure: .network(.cancelled)))
    }

    @Test func entitlementsDecodeAndStatus() throws {
        let json: String = #"""
        {"userId":"u","plan":"subscription","trialMeetingsTotal":3,"trialMeetingsLeft":1,"accountTrialMeetingsLeft":1,"deviceTrialMeetingsLeft":null,
         "monthlyHoursUsed":2.5,"monthlyHoursCap":10,
         "subscription":{"status":"past_due","complimentary":false,"currentPeriodEnd":"2026-10-01T00:00:00.000Z","access":"grace","graceEndsAt":"2026-10-08T00:00:00.000Z"}}
        """#
        let entitlements: HostedEntitlements = try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(json.utf8))
        #expect(entitlements.monthlyHoursUsed == 2.5)
        // Eski sunucu `liveEngine` göndermez: Deepgram açılmaz.
        #expect(hostedLiveEngine(entitlements: entitlements) == .whisperKit)
        let deepgram: String = json.replacingOccurrences(of: #""monthlyHoursCap":10,"#, with: #""monthlyHoursCap":10,"liveEngine":"deepgram","accountTokensUsed":15,"accountTokensCap":1500000,"accountTokensPeriod":"month","accountTokensResetsAt":"2026-11-01T00:00:00.000Z","monthlyResetsAt":"2026-11-01T00:00:00.000Z","#)
        let withEngine: HostedEntitlements = try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(deepgram.utf8))
        #expect(hostedLiveEngine(entitlements: withEngine) == .deepgram)
        #expect(withEngine.accountTokensUsed == 15 && withEngine.accountTokensCap == 1_500_000)
        // Eski sunucu `trialEndsAt` göndermez; yeni sunucu ISO 8601 gönderir.
        #expect(entitlements.trialEndsAt == nil)
        let withEnd: String = json.replacingOccurrences(of: #""deviceTrialMeetingsLeft":null"#, with: #""deviceTrialMeetingsLeft":null,"trialEndsAt":"2026-11-05T12:00:00.000Z""#)
        #expect(try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(withEnd.utf8)).trialEndsAt == (try Date.ISO8601FormatStyle().parse("2026-11-05T12:00:00Z")))
        #expect(hostedPlanStatus(entitlements: entitlements) == .grace(endsAt: try Date.ISO8601FormatStyle().parse("2026-10-08T00:00:00Z")))
        let trial: String = json.replacingOccurrences(of: #""access":"grace""#, with: #""access":"none""#)
        #expect(hostedPlanStatus(entitlements: try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(trial.utf8))) == .trial(left: 1, total: 3))
        // İptal edilmiş ama dönemi süren abonelik "sona eriyor"dur, yenilenmez.
        let ending: String = json
            .replacingOccurrences(of: #""access":"grace","graceEndsAt":"2026-10-08T00:00:00.000Z""#, with: #""access":"active","graceEndsAt":null"#)
            .replacingOccurrences(of: #""status":"past_due","#, with: #""status":"active","cancelAt":"2026-10-01T00:00:00.000Z","#)
        #expect(hostedPlanStatus(entitlements: try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(ending.utf8))) == .ending(endsAt: try Date.ISO8601FormatStyle().parse("2026-10-01T00:00:00Z")))
        // Toplantı dışı yapay zekâ payı yeni alan: yoksa nil, varsa okunur.
        #expect(entitlements.accountTokensCap == nil)
        let withTokens: String = json.replacingOccurrences(of: #""monthlyHoursCap":10,"#, with: #""monthlyHoursCap":10,"accountTokensUsed":250,"accountTokensCap":1000,"#)
        let tokens: HostedEntitlements = try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(withTokens.utf8))
        #expect(tokens.accountTokensUsed == 250 && tokens.accountTokensCap == 1000)
    }

    // Sunucu denemeyi bu Mac'te reddettiyse denemedeki hesap 0 kalan gösterir (başlat engeli de devreye girer); abone
    // etkilenmez.
    @Test func trialRefusedOnThisMac() throws {
        let trialJSON: String = #"""
        {"userId":"u","plan":"trial","trialMeetingsTotal":3,"trialMeetingsLeft":3,"accountTrialMeetingsLeft":3,"deviceTrialMeetingsLeft":null,
         "monthlyHoursUsed":0,"monthlyHoursCap":10,"subscription":null}
        """#
        let trial: HostedEntitlements = try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(trialJSON.utf8))
        let refused: HostedEntitlements = hostedEntitlementsOnThisMac(entitlements: trial, trialRefusedOnThisMac: true)
        #expect(hostedPlanStatus(entitlements: refused) == .trial(left: 0, total: 3))
        #expect(hostedStartBlock(entitlements: refused) == .trialEnded)
        #expect(hostedEntitlementsOnThisMac(entitlements: trial, trialRefusedOnThisMac: false) == trial)
        let subscriberJSON: String = trialJSON
            .replacingOccurrences(of: #""plan":"trial""#, with: #""plan":"subscription""#)
            .replacingOccurrences(of: #""subscription":null"#, with: #""subscription":{"status":"active","complimentary":false,"currentPeriodEnd":"2026-11-29T00:00:00.000Z","access":"active"}"#)
        let subscriber: HostedEntitlements = try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(subscriberJSON.utf8))
        #expect(hostedEntitlementsOnThisMac(entitlements: subscriber, trialRefusedOnThisMac: true) == subscriber)
    }

    // Abone olma teklifi: denemede günde en çok bir, deneme bitince hesap başına bir kez; abonede hiç.
    @Test func upsellMoments() throws {
        let trialJSON: String = #"""
        {"userId":"u","plan":"trial","trialMeetingsTotal":3,"trialMeetingsLeft":2,"accountTrialMeetingsLeft":2,"deviceTrialMeetingsLeft":null,
         "monthlyHoursUsed":0,"monthlyHoursCap":10,"subscription":null}
        """#
        let now: Date = Date(timeIntervalSince1970: 2_000_000)
        let trial: HostedEntitlements = try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(trialJSON.utf8))
        #expect(hostedUpsellMoment(entitlements: trial, lastShownAt: nil, trialEndedShown: false, trialEndingShown: false, now: now, intervalSec: hostedUpsellIntervalSec) == .trialNoteReady)
        #expect(hostedUpsellMoment(entitlements: trial, lastShownAt: now.addingTimeInterval(-3600), trialEndedShown: false, trialEndingShown: false, now: now, intervalSec: hostedUpsellIntervalSec) == nil)
        #expect(hostedUpsellMoment(entitlements: trial, lastShownAt: now.addingTimeInterval(-hostedUpsellIntervalSec), trialEndedShown: false, trialEndingShown: false, now: now, intervalSec: hostedUpsellIntervalSec) == .trialNoteReady)
        let ended: HostedEntitlements = try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(trialJSON.replacingOccurrences(of: #""trialMeetingsLeft":2"#, with: #""trialMeetingsLeft":0"#).utf8))
        // Deneme bitince günlük aralık beklenmez, ama yalnızca bir kez.
        #expect(hostedUpsellMoment(entitlements: ended, lastShownAt: now.addingTimeInterval(-60), trialEndedShown: false, trialEndingShown: false, now: now, intervalSec: hostedUpsellIntervalSec) == .trialEnded)
        #expect(hostedUpsellMoment(entitlements: ended, lastShownAt: nil, trialEndedShown: true, trialEndingShown: false, now: now, intervalSec: hostedUpsellIntervalSec) == nil)
        let subscriber: HostedEntitlements = try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(trialJSON
            .replacingOccurrences(of: #""plan":"trial""#, with: #""plan":"subscription""#)
            .replacingOccurrences(of: #""subscription":null"#, with: #""subscription":{"status":"active","complimentary":false,"currentPeriodEnd":"2026-11-29T00:00:00.000Z","access":"active"}"#).utf8))
        #expect(hostedUpsellMoment(entitlements: subscriber, lastShownAt: nil, trialEndedShown: false, trialEndingShown: false, now: now, intervalSec: hostedUpsellIntervalSec) == nil)
        // Son toplantı kaldı: günlük aralık beklenmeden bir kez "bitmek üzere"; gösterildiyse günlük teklif sürer.
        let lastOne: HostedEntitlements = try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(trialJSON.replacingOccurrences(of: #""trialMeetingsLeft":2"#, with: #""trialMeetingsLeft":1"#).utf8))
        #expect(hostedUpsellMoment(entitlements: lastOne, lastShownAt: now.addingTimeInterval(-60), trialEndedShown: false, trialEndingShown: false, now: now, intervalSec: hostedUpsellIntervalSec) == .trialEnding)
        #expect(hostedUpsellMoment(entitlements: lastOne, lastShownAt: nil, trialEndedShown: false, trialEndingShown: true, now: now, intervalSec: hostedUpsellIntervalSec) == .trialNoteReady)
    }

    // Abonelik planı yanıttan okunur; tanınmayan ya da eksik plan hak yanıtını bozmaz.
    @Test func subscriptionPlanDecodes() throws {
        func subscription(_ plan: String) throws -> HostedSubscription {
            let json: String = #"{"status":"active","complimentary":false,"currentPeriodEnd":"2026-11-29T00:00:00.000Z","access":"active""# + plan + "}"
            return try hostedJSONDecoder().decode(HostedSubscription.self, from: Data(json.utf8))
        }
        #expect(try subscription(#","plan":"yearly""#).billingPlan == .yearly)
        #expect(try subscription(#","plan":"monthly""#).billingPlan == .monthly)
        #expect(try subscription(#","plan":null"#).billingPlan == nil)
        #expect(try subscription(#","plan":"weekly""#).billingPlan == nil)
        #expect(try subscription("").billingPlan == nil)
    }

    // Fiyat hesapları ve davet kodunun biçimi (sunucuyla aynı kural).
    @Test func planPricesAndReferralCodes() {
        #expect(hostedYearlyMonthlyEquivalentCents() == 408)
        #expect(hostedYearlySavingsPercent() == 32)
        #expect(hostedReferralFirstPaymentCents(plan: .monthly) == 0)
        #expect(hostedReferralFirstPaymentCents(plan: .yearly) == 4301)
        #expect(normalizedHostedReferralCode(input: " k7m2-qx9d ") == "K7M2QX9D")
        #expect(isWellFormedHostedReferralCode(code: "K7M2QX9D"))
        #expect(!isWellFormedHostedReferralCode(code: "K7M2QX9"))
        #expect(!isWellFormedHostedReferralCode(code: "K7M2QX0D"))
    }

    // İçe aktarma toplantının ses hakkını aşarsa kuyruğa alınmadan reddedilir; eski sunucu (alan yok) denetlenmez.
    @Test func importLongerThanMeetingAllowanceIsRejected() throws {
        let json: String = #"""
        {"userId":"u","plan":"trial","trialMeetingsTotal":3,"trialMeetingsLeft":2,"accountTrialMeetingsLeft":2,"deviceTrialMeetingsLeft":null,
         "monthlyHoursUsed":0,"monthlyHoursCap":10,"meetingMaxMinutes":90,"subscription":null}
        """#
        let entitlements: HostedEntitlements = try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(json.utf8))
        try requireHostedImportFits(durationSec: 90 * 60, entitlements: entitlements)
        #expect(throws: HostedImportError.longerThanMeetingAllowance(durationMinutes: 91, maxMinutes: 90)) {
            try requireHostedImportFits(durationSec: 90 * 60 + 1, entitlements: entitlements)
        }
        let old: HostedEntitlements = try hostedJSONDecoder().decode(
            HostedEntitlements.self, from: Data(json.replacingOccurrences(of: #""meetingMaxMinutes":90,"#, with: "").utf8)
        )
        try requireHostedImportFits(durationSec: 10 * 3600, entitlements: old)
        // Örtüşme hesaba katılır: 90 dk'lık dosya 2 parça (+60 sn) gönderir; sunucunun payı da 60 sn.
        #expect(hostedUploadedAudioSec(durationSec: 90 * 60) == 90 * 60 + hostedChunkOverlapSec)
        #expect(hostedServerOverlapAllowanceSec(seconds: 90 * 60) == 60)
        #expect(hostedUploadedAudioSec(durationSec: 30 * 60) == 30 * 60)
        // 4 saatlik toplantı: 5 parça, 4 sınır; sunucunun payı 4 dakika.
        #expect(hostedUploadedAudioSec(durationSec: 240 * 60) == 240 * 60 + 4 * hostedChunkOverlapSec)
        #expect(hostedServerOverlapAllowanceSec(seconds: 240 * 60) == 240)
    }

    // Son geçiş yapılamadığında uyarı hangi metnin kaldığını doğru söyler: yeniden işlemede önceki son geçiş korunur.
    @Test func finalPassNoticesTellWhichTranscriptRemains() {
        #expect(skippedFinalPassNotice(reason: "x", hasFinalTranscript: true).contains("Önceki son geçiş metni korundu"))
        #expect(skippedFinalPassNotice(reason: "x", hasFinalTranscript: false).contains("Canlı metin kullanıldı"))
        let error: HostedAPIError = HostedAPIError(code: .reprocessLimitReached, rawCode: "reprocess_limit_reached", status: 409, serverMessage: "", path: "/v1/transcribe")
        #expect(failedFinalPassNotice(error: error, hasFinalTranscript: true).contains("Önceki son geçiş metni korundu"))
        #expect(failedFinalPassNotice(error: error, hasFinalTranscript: false).contains("canlı metinden"))
        let me: StoredSegment = StoredSegment(key: "final-0", speaker: .me, person: nil, startSec: 0, endSec: 1, text: "a", words: nil)
        let base: MeetingRecord = MeetingRecord(
            id: "k", title: "T", startedAt: Date(), endedAt: Date(), language: nil, status: .done, failureMessage: nil, liveSegments: [],
            finalSegments: [me], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        #expect(!hasOthersFinalTranscript(record: base))
    }

    // Canlı kaydın başlatması `deferred` alanını hiç göndermez (eski sunucu bilinmeyen alanı reddeder); bekleyen kayıt gönderir.
    @Test func meetingStartOmitsDeferredUnlessTrue() throws {
        let live: String = String(decoding: try meetingStartBody(device: nil, deviceCheckToken: nil, clientRef: "k", deferred: false), as: UTF8.self)
        #expect(!live.contains("deferred"))
        let pending: String = String(decoding: try meetingStartBody(device: nil, deviceCheckToken: nil, clientRef: "k", deferred: true), as: UTF8.self)
        #expect(pending.contains(#""deferred":true"#))
        #expect(hostedClientMessage(error: .serverOutdated(path: "/v1/meetings/{id}/reprocess")).contains("Tekrar işle"))
    }

    // Yükleme anahtarı sunucunun beklediği biçimde (32 bayt, dolgusuz base64url) ve her parçada farklı.
    @Test func uploadKeysAreUniqueBase64URL() throws {
        let first: String = try makeUploadKey()
        let second: String = try makeUploadKey()
        #expect(first != second)
        #expect(first.wholeMatch(of: /[A-Za-z0-9_-]{43}/) != nil)
    }

    // Ölçer düzeyleri, ay sıfırlanması (UTC) ve bildirimler: abonede %80 ve %100, denemede son toplantı ve bitiş.
    @Test func usageLevelsAndNotices() throws {
        #expect(hostedUsageLevel(fraction: hostedUsageFraction(used: 3.4, cap: 10)) == .normal)
        #expect(hostedUsageLevel(fraction: hostedUsageFraction(used: 8, cap: 10)) == .warning)
        #expect(hostedUsageLevel(fraction: hostedUsageFraction(used: 12, cap: 10)) == .full)
        #expect(hostedUsageFraction(used: 1, cap: 0) == 1)
        let now: Date = try Date.ISO8601FormatStyle().parse("2026-10-31T23:30:00Z")
        #expect(hostedMonthResetDate(now: now) == (try Date.ISO8601FormatStyle().parse("2026-11-01T00:00:00Z")))
        #expect(hostedPeriodKey(now: now) == "2026-10")
        func decoded(_ text: String) throws -> HostedEntitlements {
            try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(text.utf8))
        }
        let subscriber: String = #"""
        {"userId":"u","plan":"subscription","trialMeetingsTotal":3,"trialMeetingsLeft":0,"accountTrialMeetingsLeft":0,"deviceTrialMeetingsLeft":null,
         "monthlyHoursUsed":8.5,"monthlyHoursCap":10,
         "subscription":{"status":"active","complimentary":false,"currentPeriodEnd":"2026-11-20T00:00:00.000Z","access":"active","graceEndsAt":null}}
        """#
        #expect(hostedUsageNotice(entitlements: try decoded(subscriber)) == .monthlyWarning)
        #expect(hostedUsageNotice(entitlements: try decoded(subscriber.replacingOccurrences(of: "8.5", with: "10"))) == .monthlyFull)
        #expect(hostedUsageNotice(entitlements: try decoded(subscriber.replacingOccurrences(of: "8.5", with: "2"))) == nil)
        // Hiç abone olmamış deneme hesabı (eski abone "abonelik sona erdi" görür; bkz. HostedOfflineTests).
        let trial: String = subscriber.replacingOccurrences(
            of: #"{"status":"active","complimentary":false,"currentPeriodEnd":"2026-11-20T00:00:00.000Z","access":"active","graceEndsAt":null}"#, with: "null"
        )
        #expect(hostedUsageNotice(entitlements: try decoded(trial)) == .trialEnded)
        #expect(hostedUsageNotice(entitlements: try decoded(trial.replacingOccurrences(of: #""trialMeetingsLeft":0"#, with: #""trialMeetingsLeft":1"#))) == .trialOneLeft)
        #expect(hostedNoticeStorageKey(notice: .monthlyWarning, userId: "u", now: now) == "hosted.notice.monthlyWarning.u.2026-10")
        #expect(hostedNoticeStorageKey(notice: .trialEnded, userId: "u", now: now) == "hosted.notice.trialEnded.u")
        #expect(hostedMinutesLeft(deadline: now.addingTimeInterval(61), now: now) == 2)
    }
}

/// İmzasız, JWT biçiminde deneme jetonu (imza sunucuda doğrulanır; burada yalnızca biçim ve nonce).
private func googleTestToken(claims: String) -> String {
    func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    return "\(base64URL(#"{"alg":"RS256","typ":"JWT"}"#)).\(base64URL(claims)).imza"
}

@Suite struct HostedConfigTests {
    @Test func baseURLValidation() throws {
        #expect(try parseHostedBaseURL(value: "http://localhost:8787").absoluteString == "http://localhost:8787")
        #expect(throws: HostedClientError.invalidBaseURL(value: "https://api.example.invalid")) { try parseHostedBaseURL(value: "https://api.example.invalid") }
        #expect(throws: HostedClientError.self) { try parseHostedBaseURL(value: "ftp://ornek.fi") }
        #expect(throws: HostedClientError.self) { try parseHostedBaseURL(value: "") }
        #expect(throws: HostedClientError.insecureBaseURL(url: "http://localhost:8787")) {
            try requireSecureHostedBaseURL(url: try parseHostedBaseURL(value: "http://localhost:8787"))
        }
        try requireSecureHostedBaseURL(url: try parseHostedBaseURL(value: "https://api.ornek.fi"))
    }

    // Giriş sayfası adresi: site kökü + /sign-in, app=1, nonce'un SHA-256'sı ve uygulamada seçilen sağlayıcı.
    @Test func browserSignInPage() throws {
        let page: URL = hostedBrowserSignInPage(siteBase: try parseHostedBaseURL(value: "https://gistsmith.com"), nonceHash: hostedNonceHash(nonce: "abc"), provider: .google)
        #expect(page.absoluteString == "https://gistsmith.com/sign-in?app=1&nonce=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad&provider=google")
    }

    // Avatar: Google jetonundaki https resim adresi alınır; resim yoksa (Apple) ya da https değilse nil.
    @Test func identityTokenPicture() throws {
        let google: String = googleTestToken(claims: #"{"sub":"1","picture":"https://lh3.googleusercontent.com/a/abc=s96-c"}"#)
        #expect(try hostedIDTokenPicture(identityToken: google)?.absoluteString == "https://lh3.googleusercontent.com/a/abc=s96-c")
        #expect(try hostedIDTokenPicture(identityToken: googleTestToken(claims: #"{"sub":"1"}"#)) == nil)
        #expect(try hostedIDTokenPicture(identityToken: googleTestToken(claims: #"{"sub":"1","picture":"http://ornek.fi/a.png"}"#)) == nil)
    }

    // Dönüş yalnızca bekleyen, süresi geçmemiş denemeyle ve aynı nonce'la kabul edilir; adres sıkı çözülür, sağlayıcı
    // yoldan (Apple ya da Google) okunur.
    @Test func browserCallbackResolution() throws {
        let started: Date = Date(timeIntervalSince1970: 1_000_000)
        let attempt: HostedBrowserSignInAttempt = HostedBrowserSignInAttempt(rawNonce: "ham-nonce", startedAt: started)
        let token: String = googleTestToken(claims: #"{"sub":"1","nonce":"\#(hostedNonceHash(nonce: "ham-nonce"))"}"#)
        let url: URL = try #require(URL(string: "com.senoldogan.ainotepad.hosted://auth/google#idToken=\(token)"))
        let resolved: HostedBrowserSignInCallback = try resolveHostedBrowserCallback(url: url, pending: attempt, now: started.addingTimeInterval(599), lifetimeSec: hostedBrowserSignInLifetimeSec)
        #expect(resolved == HostedBrowserSignInCallback(provider: .google, identityToken: token, rawNonce: "ham-nonce"))
        let appleURL: URL = try #require(URL(string: "com.senoldogan.ainotepad.hosted://auth/apple#idToken=\(token)"))
        let apple: HostedBrowserSignInCallback = try resolveHostedBrowserCallback(url: appleURL, pending: attempt, now: started, lifetimeSec: hostedBrowserSignInLifetimeSec)
        #expect(apple == HostedBrowserSignInCallback(provider: .apple, identityToken: token, rawNonce: "ham-nonce"))
        #expect(throws: HostedBrowserSignInError.noPendingAttempt) {
            try resolveHostedBrowserCallback(url: url, pending: nil, now: started, lifetimeSec: hostedBrowserSignInLifetimeSec)
        }
        #expect(throws: HostedBrowserSignInError.attemptExpired) {
            try resolveHostedBrowserCallback(url: url, pending: attempt, now: started.addingTimeInterval(601), lifetimeSec: hostedBrowserSignInLifetimeSec)
        }
        let other: HostedBrowserSignInAttempt = HostedBrowserSignInAttempt(rawNonce: "baska-nonce", startedAt: started)
        #expect(throws: HostedBrowserSignInError.nonceMismatch) {
            try resolveHostedBrowserCallback(url: url, pending: other, now: started, lifetimeSec: hostedBrowserSignInLifetimeSec)
        }
        let noNonce: String = googleTestToken(claims: #"{"sub":"1"}"#)
        for bad in [
            "com.senoldogan.ainotepad://auth/google#idToken=\(token)",
            "com.senoldogan.ainotepad.hosted://auth/email#idToken=\(token)",
            "com.senoldogan.ainotepad.hosted://auth/#idToken=\(token)",
            "com.senoldogan.ainotepad.hosted://auth/apple/x#idToken=\(token)",
            "com.senoldogan.ainotepad.hosted://auth/google?idToken=\(token)",
            "com.senoldogan.ainotepad.hosted://auth/google?x=1#idToken=\(token)",
            "com.senoldogan.ainotepad.hosted://auth/google#idToken=\(token)&extra=1",
            "com.senoldogan.ainotepad.hosted://auth/google#token=\(token)",
            "com.senoldogan.ainotepad.hosted://auth/google#idToken=a.b",
            "com.senoldogan.ainotepad.hosted://auth/google#idToken=a.b%2B.c",
            "com.senoldogan.ainotepad.hosted://auth/google",
            "com.senoldogan.ainotepad.hosted://auth/google#idToken=\(noNonce)",
        ] {
            #expect(throws: HostedBrowserSignInError.self) {
                try resolveHostedBrowserCallback(url: try #require(URL(string: bad)), pending: attempt, now: started, lifetimeSec: hostedBrowserSignInLifetimeSec)
            }
        }
    }

    @Test func nonceHashIsLowercaseSHA256Hex() throws {
        #expect(hostedNonceHash(nonce: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let nonce: String = try makeHostedNonce()
        #expect(nonce.count == 64)
        #expect(try makeHostedNonce() != nonce)
    }
}

@Suite struct HostedRecordingLimitTests {
    @Test func deadlineIsEarlierOfServerAndLocalLimit() {
        let requested: Date = Date(timeIntervalSince1970: 1_000_000)
        // Sunucunun saati 2 dk geride: yerel hesap (90 dk) daha erken.
        #expect(hostedRecordingDeadline(requestedAt: requested, maxDurationMinutes: 90, serverEndsAt: requested.addingTimeInterval(92 * 60))
            == requested.addingTimeInterval(90 * 60))
        // Sunucunun saati ileride: sunucunun bitişi daha erken.
        #expect(hostedRecordingDeadline(requestedAt: requested, maxDurationMinutes: 90, serverEndsAt: requested.addingTimeInterval(89 * 60))
            == requested.addingTimeInterval(89 * 60))
    }

    @Test func warnsFiveMinutesBeforeAndStopsAtLimit() {
        let deadline: Date = Date(timeIntervalSince1970: 2_000_000)
        func state(_ secondsBefore: Double) -> HostedRecordingLimitState {
            hostedRecordingLimitState(now: deadline.addingTimeInterval(-secondsBefore), deadline: deadline, warningLeadSec: hostedLimitWarningLeadSec)
        }
        #expect(state(3600) == .running)
        #expect(state(300.5) == .running)
        #expect(state(300) == .warning)
        #expect(state(1) == .warning)
        #expect(state(0) == .reached)
        #expect(state(-10) == .reached)
    }
}
