import Foundation

/// Deepgram'ın bir sonuç mesajı; zamanlar bağlantı başından itibaren saniye.
public struct DeepgramResult: Sendable, Equatable {
    public let startSec: Double
    public let endSec: Double
    public let transcript: String
    public let isFinal: Bool

    public init(startSec: Double, endSec: Double, transcript: String, isFinal: Bool) {
        self.startSec = startSec
        self.endSec = endSec
        self.transcript = transcript
        self.isFinal = isFinal
    }
}

/// Deepgram akışından gelen mesaj türleri.
public enum DeepgramMessage: Sendable, Equatable {
    case results(DeepgramResult)
    case metadata(requestID: String)
    case other(type: String)
}

/// Deepgram WebSocket mesajını ayrıştırır.
public func parseDeepgramMessage(data: Data) throws -> DeepgramMessage {
    let decoder: JSONDecoder = JSONDecoder()
    do {
        let envelope: Envelope = try decoder.decode(Envelope.self, from: data)
        switch envelope.type {
        case "Results":
            let raw: RawResults = try decoder.decode(RawResults.self, from: data)
            return .results(DeepgramResult(
                startSec: raw.start,
                endSec: raw.start + raw.duration,
                transcript: raw.channel.alternatives.first?.transcript ?? "",
                isFinal: raw.is_final
            ))
        case "Metadata":
            return .metadata(requestID: try decoder.decode(RawMetadata.self, from: data).request_id)
        default:
            return .other(type: envelope.type)
        }
    } catch {
        throw CloudSTTError.malformedMessage(service: "deepgram", body: String(decoding: data, as: UTF8.self))
    }
}

/// Canlı dinleme adresi. Dil: Fince → `fi`, İngilizce → `en`, Otomatik → `multi`.
public func deepgramListenURL(languageMode: LanguageMode) -> URL {
    var components: URLComponents = URLComponents()
    components.scheme = "wss"
    components.host = "api.deepgram.com"
    components.path = "/v1/listen"
    components.queryItems = [
        URLQueryItem(name: "model", value: "nova-3"),
        URLQueryItem(name: "language", value: deepgramLanguage(languageMode: languageMode)),
        URLQueryItem(name: "encoding", value: "linear16"),
        URLQueryItem(name: "sample_rate", value: "16000"),
        URLQueryItem(name: "channels", value: "1"),
        URLQueryItem(name: "interim_results", value: "true"),
        URLQueryItem(name: "smart_format", value: "true"),
    ]
    // Sabit bileşenlerden üretildiği için her zaman geçerlidir.
    return components.url!
}

private func deepgramLanguage(languageMode: LanguageMode) -> String {
    switch languageMode {
    case .automatic: "multi"
    case .fixed(let language): language.rawValue
    }
}

// Deepgram JSON alan adları snake_case olduğu için ara tipler aynı adları kullanır.
private struct Envelope: Decodable { let type: String }
private struct RawMetadata: Decodable { let request_id: String }
private struct RawResults: Decodable {
    let start: Double
    let duration: Double
    let is_final: Bool
    let channel: RawChannel
}
private struct RawChannel: Decodable { let alternatives: [RawAlternative] }
private struct RawAlternative: Decodable { let transcript: String }
