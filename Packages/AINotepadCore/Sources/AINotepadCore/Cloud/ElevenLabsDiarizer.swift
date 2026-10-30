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
    case .fixed(let language): language.elevenLabsCode
    }
}

/// ElevenLabs dil kodunu (ISO 639-3; Çince için "zho" da gelebilir) toplantı diline çevirir; desteklenmeyen dilde nil.
/// Saf fonksiyondur.
public func meetingLanguage(elevenLabsCode: String) -> MeetingLanguage? {
    let code: String = elevenLabsCode.lowercased()
    if code == "zho" {
        return .chinese
    }
    return MeetingLanguage.allCases.first { $0.elevenLabsCode == code } ?? MeetingLanguage(rawValue: code)
}

private let elevenLabsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "ElevenLabs")

/// Sesi (16 kHz mono) ElevenLabs Scribe v2'ye konuşmacı ayırma açık gönderir.
/// 3 deneme yapılır; 4xx yanıtlar (ör. geçersiz anahtar) yeniden denenmez.
public func diarizeWithElevenLabs(apiKey: String, samples: [Float], languageMode: LanguageMode) async throws -> DiarizationResult {
    try await postToElevenLabs(
        apiKey: apiKey,
        audio: wavData(samples: samples, sampleRate: 16000),
        fileName: "audio.wav",
        mimeType: "audio/wav",
        languageMode: languageMode,
        // Canlı pencereler yalnızca konuşmacı etiketi için: ek ücretli alanlar gönderilmez.
        extraFields: [],
        timeoutSec: 60
    )
}

/// Son geçişin ek alanları: dolgu sözleri ve yarım başlangıçlar atılır (`no_verbatim`, not ve transkript temiz),
/// "(gülme)" gibi ses etiketleri yazılmaz, anahtar terimler (adlar, terimler; %20 ek ücret) verilir. Saf fonksiyondur.
public func finalPassFields(keyterms: [String]) -> [(name: String, value: String)] {
    [("no_verbatim", "true"), ("tag_audio_events", "false")] + keyterms.map { ("keyterms", $0) }
}

/// Kaydın tamamını (ör. `others.m4a`) tek istekle gönderir; uzun toplantı için zaman aşımı uzun tutulur.
public func diarizeFile(
    apiKey: String, fileURL: URL, mimeType: String, languageMode: LanguageMode, keyterms: [String], timeoutSec: Double
) async throws -> DiarizationResult {
    let audio: Data
    do {
        audio = try Data(contentsOf: fileURL)
    } catch {
        throw StorageError.readFailed(path: fileURL.path, reason: error.localizedDescription)
    }
    return try await postToElevenLabs(
        apiKey: apiKey,
        audio: audio,
        fileName: fileURL.lastPathComponent,
        mimeType: mimeType,
        languageMode: languageMode,
        extraFields: finalPassFields(keyterms: keyterms),
        timeoutSec: timeoutSec
    )
}

/// ElevenLabs Scribe v2 isteği: 3 deneme, 4xx denenmez. 2xx yanıt yeniden gönderilmez (yazıya dökme faturalanmıştır):
/// ayrıştırılamazsa hata hemen fırlatılır.
private func postToElevenLabs(
    apiKey: String,
    audio: Data,
    fileName: String,
    mimeType: String,
    languageMode: LanguageMode,
    extraFields: [(name: String, value: String)],
    timeoutSec: Double
) async throws -> DiarizationResult {
    let boundary: String = "AINotepad-\(UUID().uuidString)"
    var fields: [(name: String, value: String)] = [("model_id", "scribe_v2"), ("diarize", "true")] + extraFields
    if let code = elevenLabsLanguageCode(languageMode: languageMode) {
        fields.append(("language_code", code))
    }
    // Sabit, geçerli adres.
    var request: URLRequest = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
    request.httpMethod = "POST"
    request.timeoutInterval = timeoutSec
    request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = multipartBody(boundary: boundary, fields: fields, file: audio, fileName: fileName, mimeType: mimeType)

    var body: Data?
    var rejection: CloudSTTError?
    try await retryWithBackoff(
        attempts: 3,
        delaySec: 1,
        isolation: nil,
        operation: {
            let (data, response): (Data, URLResponse) = try await URLSession.shared.data(for: request)
            let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                // Ayrıştırma denemelerin dışında: bozuk yanıt aynı sesi yeniden faturalatmasın.
                body = data
            } else if isPermanentHTTPRejection(status: status) {
                // Yeniden denemenin anlamı yok; denemeyi bitir, aşağıda fırlat.
                rejection = .http(service: "elevenlabs", status: status, body: String(decoding: data, as: UTF8.self))
            } else {
                // 408, 429 ve 5xx geçici: geri çekilerek yeniden denenir (eşzamanlı içe aktarmalarda hız sınırı).
                throw CloudSTTError.http(service: "elevenlabs", status: status, body: String(decoding: data, as: UTF8.self))
            }
        },
        onFailure: { (attempt: Int, error: any Error) -> Void in
            elevenLabsLogger.warning("ElevenLabs isteği başarısız, deneme: \(attempt, privacy: .public), bayt: \(audio.count, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        }
    )
    if let rejection {
        throw rejection
    }
    guard let body else {
        throw CloudSTTError.malformedMessage(service: "elevenlabs", body: "boş sonuç")
    }
    return try parseElevenLabsResponse(data: body)
}

/// `multipart/form-data` gövdesi: metin alanları + `file` alanında WAV.
private func multipartBody(boundary: String, fields: [(name: String, value: String)], file: Data, fileName: String, mimeType: String) -> Data {
    var body: Data = Data()
    for field in fields {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n\(field.value)\r\n".utf8))
    }
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
    body.append(file)
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
