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

/// Canlı dinleme adresinin dil ve terimler dışındaki seçenekleri.
public struct DeepgramListenOptions: Sendable, Equatable {
    public let model: String
    /// Deepgram'ın model geliştirme programından çıkılır (`mip_opt_out=true`): ses ve metin yalnızca istek işlenirken
    /// tutulur, model eğitiminde kullanılmaz.
    public let optOutOfModelImprovement: Bool

    public init(model: String, optOutOfModelImprovement: Bool) {
        self.model = model
        self.optOutOfModelImprovement = optOutOfModelImprovement
    }
}

/// Geliştirici sürümünün (kullanıcının kendi Deepgram anahtarı) seçenekleri: Nova-3, hesabın kendi veri ayarı.
public let developerDeepgramListenOptions: DeepgramListenOptions = DeepgramListenOptions(model: "nova-3", optOutOfModelImprovement: false)

/// Geliştirici sürümünün canlı dinleme adresi (bkz. `deepgramListenURL(language:keyterms:options:)`).
public func deepgramListenURL(language: MeetingLanguage, keyterms: [String]) -> URL {
    deepgramListenURL(language: language, keyterms: keyterms, options: developerDeepgramListenOptions)
}

/// Canlı dinleme adresi. Her zaman somut dil kullanılır: `multi` ölçümde güvenilmez çıktı. Saf fonksiyondur.
public func deepgramListenURL(language: MeetingLanguage, keyterms: [String], options: DeepgramListenOptions) -> URL {
    var components: URLComponents = URLComponents()
    components.scheme = "wss"
    components.host = "api.deepgram.com"
    components.path = "/v1/listen"
    let privacy: [URLQueryItem] = options.optOutOfModelImprovement ? [URLQueryItem(name: "mip_opt_out", value: "true")] : []
    components.queryItems = [
        URLQueryItem(name: "model", value: options.model),
        URLQueryItem(name: "language", value: language.rawValue),
        URLQueryItem(name: "encoding", value: "linear16"),
        URLQueryItem(name: "sample_rate", value: "16000"),
        URLQueryItem(name: "channels", value: "1"),
        URLQueryItem(name: "interim_results", value: "true"),
        URLQueryItem(name: "smart_format", value: "true"),
        // Biçimlendirme için (sayı, tarih) metni 3 sn'ye kadar bekletmesin: canlı metin konuşmayla başa baş gelsin.
        // Son geçiş metni zaten yeniden yazar.
        URLQueryItem(name: "no_delay", value: "true"),
    // Adlar ve terimler (keyterm prompting, nova-3): her terim ayrı parametre.
    ] + privacy + keyterms.map { URLQueryItem(name: "keyterm", value: $0) }
    // Sabit bileşenlerden üretildiği için her zaman geçerlidir.
    return components.url!
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
