import Foundation
import os

/// Konuşmacısı belli bir kelime; zamanlar gönderilen sesin başından itibaren saniye.
public struct DiarizedWord: Sendable, Equatable {
    public let text: String
    public let startSec: Double
    public let endSec: Double
    /// ElevenLabs'in pencere içi etiketi (ör. "speaker_0"); pencereler arasında kalıcı değildir.
    public let speaker: String

    public init(text: String, startSec: Double, endSec: Double, speaker: String) {
        self.text = text
        self.startSec = startSec
        self.endSec = endSec
        self.speaker = speaker
    }
}

/// Bir konuşmacı ayırma isteğinin sonucu.
public struct DiarizationResult: Sendable, Equatable {
    public let words: [DiarizedWord]
    /// ISO 639-3 dil kodu (ör. "fin"); yanıtta yoksa nil.
    public let languageCode: String?
    public let languageProbability: Double?
}

/// ElevenLabs yanıtını ayrıştırır; yalnızca `type == "word"` öğeleri kelimedir.
public func parseElevenLabsResponse(data: Data) throws -> DiarizationResult {
    let body: String = String(decoding: data, as: UTF8.self)
    let raw: RawTranscription
    do {
        raw = try JSONDecoder().decode(RawTranscription.self, from: data)
    } catch {
        throw CloudSTTError.malformedMessage(service: "elevenlabs", body: body)
    }
    let words: [DiarizedWord] = try raw.words
        .filter { (word: RawWord) -> Bool in word.type == "word" }
        .map { (word: RawWord) -> DiarizedWord in
            guard let speaker = word.speaker_id, let start = word.start, let end = word.end else {
                throw CloudSTTError.malformedMessage(service: "elevenlabs", body: body)
            }
            return DiarizedWord(text: word.text, startSec: start, endSec: end, speaker: speaker)
        }
    return DiarizationResult(words: words, languageCode: raw.language_code, languageProbability: raw.language_probability)
}

/// Sabit dil için ElevenLabs dil kodu; Otomatik'te nil (ElevenLabs kendisi algılar).
public func elevenLabsLanguageCode(languageMode: LanguageMode) -> String? {
    switch languageMode {
    case .automatic: nil
    case .fixed(.finnish): "fin"
    case .fixed(.english): "eng"
    }
}

/// ElevenLabs dil kodunu toplantı diline çevirir; Fince/İngilizce dışında nil.
public func meetingLanguage(elevenLabsCode: String) -> MeetingLanguage? {
    switch elevenLabsCode {
    case "fin": .finnish
    case "eng": .english
    default: nil
    }
}

private let elevenLabsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "ElevenLabs")

/// Sesi (16 kHz mono) ElevenLabs Scribe v2'ye konuşmacı ayırma açık gönderir.
/// 3 deneme yapılır; 4xx yanıtlar (ör. geçersiz anahtar) yeniden denenmez.
public func diarizeWithElevenLabs(apiKey: String, samples: [Float], languageMode: LanguageMode) async throws -> DiarizationResult {
    let boundary: String = "AINotepad-\(UUID().uuidString)"
    var fields: [(name: String, value: String)] = [("model_id", "scribe_v2"), ("diarize", "true")]
    if let code = elevenLabsLanguageCode(languageMode: languageMode) {
        fields.append(("language_code", code))
    }
    // Sabit, geçerli adres.
    var request: URLRequest = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = multipartBody(boundary: boundary, fields: fields, wav: wavData(samples: samples, sampleRate: 16000))

    var result: DiarizationResult?
    var rejection: CloudSTTError?
    try await retryWithBackoff(
        attempts: 3,
        delaySec: 1,
        isolation: nil,
        operation: {
            let (data, response): (Data, URLResponse) = try await URLSession.shared.data(for: request)
            let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                result = try parseElevenLabsResponse(data: data)
            case 400..<500:
                // Yeniden denemenin anlamı yok; denemeyi bitir, aşağıda fırlat.
                rejection = .http(service: "elevenlabs", status: status, body: String(decoding: data, as: UTF8.self))
            default:
                throw CloudSTTError.http(service: "elevenlabs", status: status, body: String(decoding: data, as: UTF8.self))
            }
        },
        onFailure: { (attempt: Int, error: any Error) -> Void in
            elevenLabsLogger.warning("ElevenLabs isteği başarısız, deneme \(attempt, privacy: .public), örnek: \(samples.count, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    )
    if let rejection {
        throw rejection
    }
    guard let result else {
        throw CloudSTTError.malformedMessage(service: "elevenlabs", body: "boş sonuç")
    }
    return result
}

/// `multipart/form-data` gövdesi: metin alanları + `file` alanında WAV.
private func multipartBody(boundary: String, fields: [(name: String, value: String)], wav: Data) -> Data {
    var body: Data = Data()
    for field in fields {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n\(field.value)\r\n".utf8))
    }
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
    body.append(wav)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
}

// ElevenLabs JSON alan adları snake_case olduğu için ara tipler aynı adları kullanır.
private struct RawTranscription: Decodable {
    let language_code: String?
    let language_probability: Double?
    let words: [RawWord]
}

private struct RawWord: Decodable {
    let text: String
    let start: Double?
    let end: Double?
    let type: String
    let speaker_id: String?
}
