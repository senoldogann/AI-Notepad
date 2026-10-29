import Foundation
import os

/// Akışlı yanıtta o ana kadar görünen metin (tamamı, parça değil); arayüz her çağrıda metni yeniler.
public typealias LLMTextHandler = @Sendable (String) async -> Void

private let streamLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "LLM")
private let streamAttempts: Int = 3

/// Akışta gösterilecek metin: baştaki `<think>…</think>` bölümü (akıl yürüten yerel modeller) bitene kadar boş, sonra
/// bölümün ardı. Etiketin yarısı gelmişken ("<thi") de boş (düşünme metni bir anlığına görünmesin). Saf fonksiyondur.
public func visibleStreamText(accumulated: String) -> String {
    let trimmed: String = String(accumulated.drop { $0.isWhitespace })
    if "<think>".hasPrefix(trimmed) {
        return ""
    }
    guard trimmed.hasPrefix("<think>") else {
        return trimmed
    }
    guard let end = trimmed.range(of: "</think>") else {
        return ""
    }
    return String(trimmed[end.upperBound...].drop { $0.isWhitespace })
}

/// İsteği akışla (SSE) gönderir: metin geldikçe `onText` o ana kadarki görünen metinle çağrılır; bitince tüm akış
/// sağlayıcının kurallarıyla doğrulanır (kesilme, reddetme, yarım akış hata) ve tam metin döner. Metin görünmeye
/// başlamadan önceki 408/429/5xx/ağ hataları 3 deneme (uyarı logu); metin göründükten sonraki hata yeniden denenmez
/// (kullanıcı yarım cevabı görmüştür), fırlatılır.
public func streamLLM(provider: LLMProvider, request: LLMRequest, onText: LLMTextHandler) async throws -> String {
    let claudeDelta: @Sendable (Substring) -> String? = { (line: Substring) -> String? in claudeTextDelta(line: line) }
    switch provider {
    case .anthropic(let config):
        return try await streamPreparedLLM(call: try prepareClaudeCall(config: config, request: request), textDelta: claudeDelta, onText: onText)
    case .openAICompatible(let config):
        return try await streamPreparedLLM(
            call: try prepareOpenAIStreamCall(config: config, request: request),
            textDelta: { (line: Substring) -> String? in openAITextDelta(line: line) }, onText: onText
        )
    case .onDevice(let config):
        return try await streamOnDevice(config: config, request: request, onText: onText)
    case .hosted(let config):
        // Sunucu Anthropic'in akış olaylarını aynen iletir. Jeton 401 ile reddedilirse (metin görünmeden) bir kez
        // yenilenip yeniden denenir.
        do {
            return try await streamPreparedLLM(call: try await prepareHostedCall(config: config, request: request), textDelta: claudeDelta, onText: onText)
        } catch LLMError.hosted(let error) where error.status == 401 {
            streamLogger.warning("Abonelik sunucusu jetonu reddetti, yenilenip yeniden deneniyor, kod: \(error.rawCode, privacy: .public)")
            try await config.credentials.refreshAccessToken()
            return try await streamPreparedLLM(call: try await prepareHostedCall(config: config, request: request), textDelta: claudeDelta, onText: onText)
        }
    }
}

/// Hazırlanmış akış çağrısını gönderir (yeniden deneme kuralları `streamLLM`'deki gibi).
private func streamPreparedLLM(call: PreparedLLMCall, textDelta: @escaping @Sendable (Substring) -> String?, onText: LLMTextHandler) async throws -> String {
    var lastError: any Error = LLMError.empty
    for attempt in 1...streamAttempts {
        var retryAfter: String?
        var shown: Bool = false
        do {
            let (bytes, response): (URLSession.AsyncBytes, URLResponse) = try await URLSession.shared.bytes(for: call.urlRequest)
            let http: HTTPURLResponse? = response as? HTTPURLResponse
            let status: Int = http?.statusCode ?? 0
            let requestID: String? = http?.value(forHTTPHeaderField: call.requestIDHeader)
            var raw: Data = Data()
            var accumulated: String = ""
            for try await line in bytes.lines {
                raw.append(Data((line + "\n").utf8))
                guard (200..<300).contains(status), let delta = textDelta(Substring(line)) else {
                    continue
                }
                accumulated += delta
                let visible: String = visibleStreamText(accumulated: accumulated)
                if !visible.isEmpty {
                    shown = true
                    await onText(visible)
                }
            }
            switch call.classify(status, raw, requestID) {
            case .success(let text):
                return text
            case .final(let error):
                throw error
            case .retryable(let error):
                guard !shown else {
                    throw error
                }
                lastError = error
                retryAfter = http?.value(forHTTPHeaderField: "retry-after")
            }
        } catch let error as URLError where error.code != .cancelled && !shown {
            lastError = error
        }
        try Task.checkCancellation()
        // Hata gövdesi toplantı metni içerebilir: yalnızca özel (private) loglanır.
        streamLogger.warning("LLM akışı başarısız, deneme: \(attempt, privacy: .public), model: \(call.model, privacy: .public), hata: \(String(describing: lastError), privacy: .private)")
        if attempt < streamAttempts {
            try await Task.sleep(for: .seconds(retryDelay(retryAfterHeader: retryAfter, attempt: attempt)))
        }
    }
    throw lastError
}
