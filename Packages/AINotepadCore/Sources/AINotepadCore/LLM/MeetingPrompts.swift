import Foundation

/// "Ne kaçırdım?" yanıtı.
public struct MissedSummary: Sendable, Equatable {
    public let topic: String
    public let decisions: [String]
    /// Kullanıcıdan ("Sen") istenenler.
    public let askedOfYou: [String]

    public init(topic: String, decisions: [String], askedOfYou: [String]) {
        self.topic = topic
        self.decisions = decisions
        self.askedOfYou = askedOfYou
    }
}

/// Soru-cevapta gönderilen en uzun transkript (maliyet ve bağlam sınırı).
let questionTranscriptLimitSec: Double = 7200

/// Bölümleri LLM'e verilecek satırlara çevirir: bölüm başına `[mm:ss] Etiket: metin` (zaman damgaları
/// cevaplarda doğru anı gösterebilsin). Metinsiz ve hatalı bölümler atlanır. Saf fonksiyondur.
public func transcriptLines(segments: [LiveSegment]) -> String {
    segments
        .filter { (segment: LiveSegment) -> Bool in segment.failureMessage == nil && !segment.text.isEmpty }
        .map { (segment: LiveSegment) -> String in
            "[\(timestamp(seconds: segment.startSec))] \(speakerLabel(speaker: segment.id.speaker, person: segment.person)): \(segment.text)"
        }
        .joined(separator: "\n")
}

/// Tek cümlelik canlı çeviri isteği; önceki cümleler yalnızca bağlam. Saf fonksiyondur.
public func translationRequest(sentence: String, context: [String]) -> ClaudeRequest {
    let contextText: String = context.isEmpty ? "(yok)" : context.joined(separator: "\n")
    return ClaudeRequest(
        model: .haiku,
        system: """
        Bir toplantının canlı çevirmenisin. Fince ya da İngilizce cümleyi doğal, akıcı Türkçeye çevir.
        Yalnızca çeviriyi yaz; açıklama, tırnak ya da başlık ekleme. Önceki cümleler yalnızca bağlam içindir, onları çevirme.
        """,
        userText: "Önceki cümleler:\n\(contextText)\n\nÇevrilecek cümle:\n\(sentence)",
        maxTokens: 1024,
        effort: "low",
        jsonSchema: nil,
        timeoutSec: 20
    )
}

/// Son `windowSec` saniyenin özeti için istek; pencere bölüm bazında seçilir (aynı konuşmacının uzun bloğu
/// tüm toplantıyı içeri almasın). Pencerede metin yoksa nil (istek atılmaz). Saf fonksiyondur.
public func missedSummaryRequest(segments: [LiveSegment], nowSec: Double, windowSec: Double) -> ClaudeRequest? {
    let recent: String = transcriptLines(segments: segments.filter { (segment: LiveSegment) -> Bool in
        segment.endSec >= nowSec - windowSec
    })
    guard !recent.isEmpty else {
        return nil
    }
    return ClaudeRequest(
        model: .opus,
        system: """
        Toplantıyı takip etmekte zorlanan Türkçe konuşan bir kullanıcıya yardım ediyorsun. Transkriptte "Sen" kullanıcıdır.
        Son dakikalarda konuşulanları Türkçe, kısa ve net özetle: konu (1–2 cümle), alınan kararlar ve kullanıcıdan istenenler.
        Transkriptte olmayan bir şey uydurma; karar ya da istek yoksa boş liste ver.
        """,
        userText: "Son \(Int(windowSec / 60)) dakikanın transkripti:\n\(recent)",
        maxTokens: 16000,
        effort: "medium",
        jsonSchema: """
        {"type":"object","properties":{"konu":{"type":"string"},"kararlar":{"type":"array","items":{"type":"string"}},\
        "sendenIstenenler":{"type":"array","items":{"type":"string"}}},"required":["konu","kararlar","sendenIstenenler"],\
        "additionalProperties":false}
        """,
        timeoutSec: 120
    )
}

/// "Ne kaçırdım?" yapılandırılmış yanıtını ayrıştırır.
public func parseMissedSummary(text: String) throws -> MissedSummary {
    guard let raw = try? JSONDecoder().decode(RawMissedSummary.self, from: Data(text.utf8)) else {
        throw LLMError.malformed(body: text)
    }
    return MissedSummary(topic: raw.konu, decisions: raw.kararlar, askedOfYou: raw.sendenIstenenler)
}

/// Toplantı hakkında Türkçe soru; transkriptin son 2 saati (bölüm bazında) gönderilir. Saf fonksiyondur.
public func questionRequest(segments: [LiveSegment], question: String) -> ClaudeRequest {
    let lastEnd: Double = segments.map(\.endSec).max() ?? 0
    let transcript: String = transcriptLines(segments: segments.filter { (segment: LiveSegment) -> Bool in
        segment.endSec >= lastEnd - questionTranscriptLimitSec
    })
    return ClaudeRequest(
        model: .opus,
        system: """
        Toplantıyı takip etmekte zorlanan Türkçe konuşan bir kullanıcının sorusunu yalnızca transkripte dayanarak cevapla.
        "Sen" kullanıcıdır. Türkçe, kısa cevap ver ve ilgili anların zaman damgalarını [mm:ss] biçiminde belirt.
        Cevap transkriptte yoksa bunu açıkça söyle; tahmin yürütme.
        """,
        userText: "Transkript:\n\(transcript.isEmpty ? "(henüz konuşma yok)" : transcript)\n\nSoru: \(question)",
        maxTokens: 16000,
        effort: "medium",
        jsonSchema: nil,
        timeoutSec: 120
    )
}

// Şemadaki Türkçe alan adları.
private struct RawMissedSummary: Decodable {
    let konu: String
    let kararlar: [String]
    let sendenIstenenler: [String]
}

/// Bir "Diğerleri" bölümünü çevirirken bağlam: ondan önceki son `count` metinli kesin "Diğerleri" bölümü. Saf fonksiyondur.
public func translationContext(transcript: [LiveSegment], before id: SegmentID, count: Int) -> [String] {
    transcript
        .filter { (segment: LiveSegment) -> Bool in
            segment.id.speaker == .others && segment.isFinal && !segment.text.isEmpty && segment.id.index < id.index
        }
        .suffix(count)
        .map(\.text)
}
