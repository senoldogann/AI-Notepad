import Foundation

/// Bir kişinin ses izi: SpeakerKit (Pyannote) konuşmacı gömmelerinin konuşma süresiyle ağırlıklı, birim uzunluğa
/// getirilmiş ortalaması. Ses değil, yalnızca sayılar saklanır.
public struct Voiceprint: Sendable, Equatable, Codable {
    public let embedding: [Float]
    /// İzin dayandığı konuşma süresi; birleştirmede ağırlık.
    public let seconds: Double

    public init(embedding: [Float], seconds: Double) {
        self.embedding = embedding
        self.seconds = seconds
    }
}

/// Ses izi eşikleri; Fince toplantı kayıtlarında ölçüldü (2 dk'lık pencereler, 6 kişilik basın toplantısı):
/// en az 15 sn konuşmada, uzaklık 0,30'un altındaysa doğru kişi %87, yeni kişinin yanlışlıkla eşlenmesi %5; ikinci
/// en yakına en az 0,10 fark şartı yanlış eşlemeyi daha da azaltır. Emin olunmayan durumda eşleme yapılmaz.
public enum VoiceMatching {
    /// Bu uzaklığın altındaki iz aynı kişi sayılabilir (kosinüs uzaklığı, 0 = aynı).
    public static let maxDistance: Double = 0.30
    /// En yakın ile ikinci en yakın arasındaki en az fark.
    public static let minMargin: Double = 0.10
    /// Eşleme kararı için gereken en az konuşma.
    public static let minDecisionSeconds: Double = 15
    /// İzi güncellemek için gereken en az konuşma (kısa parçalar izi bozmasın).
    public static let minUpdateSeconds: Double = 8
    /// Bir ElevenLabs etiketinin konuşmasının bu kadarı tek bir SpeakerKit konuşmacısına düşmeli (ve tersi).
    public static let minDominance: Double = 0.8
}

/// Birim uzunluğa getirilmiş vektör; sıfır vektörde boş. Saf fonksiyondur.
public func normalizedEmbedding(values: [Float]) -> [Float] {
    let length: Float = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return length > 0 ? values.map { $0 / length } : []
}

/// İki birim vektörün kosinüs uzaklığı; boyutlar farklıysa (model değişti) en uzak (2). Saf fonksiyondur.
public func voiceDistance(_ left: Voiceprint, _ right: Voiceprint) -> Double {
    guard left.embedding.count == right.embedding.count, !left.embedding.isEmpty else {
        return 2
    }
    return 1 - Double(zip(left.embedding, right.embedding).reduce(Float(0)) { $0 + $1.0 * $1.1 })
}

/// İki izin süre ağırlıklı birleşimi (aynı kişi). Boyutlar farklıysa yeni iz kalır. Saf fonksiyondur.
public func mergedVoiceprint(_ old: Voiceprint, _ new: Voiceprint) -> Voiceprint {
    guard old.embedding.count == new.embedding.count else {
        return new
    }
    let total: Double = old.seconds + new.seconds
    let sum: [Float] = zip(old.embedding, new.embedding).map { (pair: (Float, Float)) -> Float in
        pair.0 * Float(old.seconds / total) + pair.1 * Float(new.seconds / total)
    }
    return Voiceprint(embedding: normalizedEmbedding(values: sum), seconds: total)
}

/// İzin en yakın adayı; uzaklık eşiğin altında ve ikinci en yakından yeterince farklıysa, yoksa nil. Saf fonksiyondur.
public func confidentMatch<Key: Hashable & Comparable>(voice: Voiceprint, candidates: [Key: Voiceprint]) -> Key? {
    let ranked: [(key: Key, distance: Double)] = candidates
        .map { (key: $0.key, distance: voiceDistance(voice, $0.value)) }
        .sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.key < $1.key }
    guard let best = ranked.first, best.distance < VoiceMatching.maxDistance else {
        return nil
    }
    if ranked.count > 1, ranked[1].distance - best.distance < VoiceMatching.minMargin {
        return nil
    }
    return best.key
}

/// SpeakerKit'in bir ses parçasındaki konuşmacısı: konuştuğu aralıklar (parçanın başından saniye) ve gömme merkezi.
public struct VoiceCluster: Sendable, Equatable {
    public let turns: [ClosedRange<Double>]
    public let centroid: [Float]

    public init(turns: [ClosedRange<Double>], centroid: [Float]) {
        self.turns = turns
        self.centroid = centroid
    }
}

/// Zaman aralığı + etiket: ses izinin kime ait olduğunu bulmak için (ElevenLabs kelimesi ya da son geçiş kelimesi).
public struct LabeledSpan<Label: Hashable & Sendable>: Sendable, Equatable {
    public let label: Label
    public let startSec: Double
    public let endSec: Double

    public init(label: Label, startSec: Double, endSec: Double) {
        self.label = label
        self.startSec = startSec
        self.endSec = endSec
    }
}

/// Etiketlerin (ör. ElevenLabs konuşmacısı) ses izleri: konuşmasının en az `minDominance`'ı tek bir etikete düşen
/// SpeakerKit konuşmacıları o etikete aittir (SpeakerKit bir kişiyi ikiye bölebilir; ikisi de aynı etikete aitse
/// ikisi de sayılır). Etiketin izi, ait olan konuşmacıların merkezlerinin kesişim süresiyle ağırlıklı ortalamasıdır.
/// Birden çok kişinin karıştığı konuşmacılar hiçbir etikete yazılmaz (yanlış kişiye iz yazılmasın). Zamanlar aynı
/// başlangıca göre. Saf fonksiyondur.
public func labelVoiceprints<Label: Hashable & Sendable>(spans: [LabeledSpan<Label>], clusters: [VoiceCluster]) -> [Label: Voiceprint] {
    clusters.reduce(into: [Label: Voiceprint]()) { (result: inout [Label: Voiceprint], cluster: VoiceCluster) -> Void in
        let shared: [Label: Double] = spans.reduce(into: [Label: Double]()) { (totals: inout [Label: Double], span: LabeledSpan<Label>) -> Void in
            let overlap: Double = cluster.turns.reduce(0) { $0 + max(0, min($1.upperBound, span.endSec) - max($1.lowerBound, span.startSec)) }
            if overlap > 0 {
                totals[span.label, default: 0] += overlap
            }
        }
        let total: Double = shared.values.reduce(0, +)
        let embedding: [Float] = normalizedEmbedding(values: cluster.centroid)
        guard let owner = shared.max(by: { $0.value < $1.value }), total > 0, owner.value / total >= VoiceMatching.minDominance, !embedding.isEmpty else {
            return
        }
        let voice: Voiceprint = Voiceprint(embedding: embedding, seconds: owner.value)
        result[owner.key] = result[owner.key].map { mergedVoiceprint($0, voice) } ?? voice
    }
}

/// Ses izi çıkaran servis (SpeakerKit); testlerde ve yerel model yokken kullanılmaz.
public protocol VoiceEmbedder: Sendable {
    /// 16 kHz mono parçadaki konuşmacılar ve gömme merkezleri.
    func clusters(samples: [Float]) async throws -> [VoiceCluster]
}

/// Kaydedilmiş toplantıdaki kişilerin ses izleri: kayıt `windowSec`'lik parçalara bölünür, her parçada SpeakerKit
/// konuşmacıları son geçiş kelimeleriyle (kelime yoksa bölüm zamanlarıyla) kişilere eşlenir, parçaların izleri kişi
/// başına birleştirilir. Kısa konuşmalı parçalar katılmaz.
public func meetingVoiceprints(samples: [Float], segments: [StoredSegment], embedder: any VoiceEmbedder, windowSec: Double) async throws -> [Int: Voiceprint] {
    let sampleRate: Double = 16000
    let spans: [LabeledSpan<Int>] = segments.filter { $0.speaker == .others }.flatMap { (segment: StoredSegment) -> [LabeledSpan<Int>] in
        guard let person = segment.person else {
            return []
        }
        if let words = segment.words, !words.isEmpty {
            return words.map { LabeledSpan(label: person, startSec: $0.startSec, endSec: $0.endSec) }
        }
        return [LabeledSpan(label: person, startSec: segment.startSec, endSec: segment.endSec)]
    }
    var voices: [Int: Voiceprint] = [:]
    var start: Int = 0
    let windowSamples: Int = Int(windowSec * sampleRate)
    // Çok kısa son parça atlanır (gömme güvenilmez).
    while start + Int(20 * sampleRate) <= samples.count {
        let end: Int = min(samples.count, start + windowSamples)
        let offset: Double = Double(start) / sampleRate
        let clusters: [VoiceCluster] = try await embedder.clusters(samples: Array(samples[start..<end]))
        let local: [LabeledSpan<Int>] = spans
            .filter { $0.endSec > offset && $0.startSec < Double(end) / sampleRate }
            .map { LabeledSpan(label: $0.label, startSec: $0.startSec - offset, endSec: $0.endSec - offset) }
        for (person, voice) in labelVoiceprints(spans: local, clusters: clusters) where voice.seconds >= VoiceMatching.minUpdateSeconds {
            voices[person] = voices[person].map { mergedVoiceprint($0, voice) } ?? voice
        }
        start += windowSamples
    }
    return voices
}

/// Kayıtlı (adlandırılmış) bir ses. İz, her kaynağın (toplantı ve kişi numarası) izinin birleşimidir; kaynaklar ayrı
/// saklandığı için yanlış verilen ad düzeltilince o toplantının katkısı tam olarak geri alınabilir. Kaynakları
/// saklanmayan eski kayıtlarda iz tek parçadır (`legacyVoiceSource`).
public struct RegisteredVoice: Sendable, Equatable, Codable {
    public let name: String
    public let voiceprint: Voiceprint
    public let updatedAt: Date
    /// Kaynak ("toplantı#kişi") → o kaynağın izi; eski kayıtlarda nil.
    public let contributions: [String: Voiceprint]?

    public init(name: String, voiceprint: Voiceprint, updatedAt: Date, contributions: [String: Voiceprint]?) {
        self.name = name
        self.voiceprint = voiceprint
        self.updatedAt = updatedAt
        self.contributions = contributions
    }
}

/// Kaynakları saklanmayan eski izin kaynak adı.
let legacyVoiceSource: String = "eski"

/// Bir toplantıdaki kişinin ses kaynağı adı. Saf fonksiyondur.
public func voiceSource(meetingID: String, person: Int) -> String {
    "\(meetingID)#\(person)"
}

/// Kaynak izlerinin süre ağırlıklı birleşimi (anahtar sırasıyla, her seferinde aynı); kaynak yoksa nil. Saf fonksiyondur.
func combinedVoiceprint(contributions: [String: Voiceprint]) -> Voiceprint? {
    contributions.keys.sorted().compactMap { contributions[$0] }.reduce(nil) { (result: Voiceprint?, voice: Voiceprint) -> Voiceprint? in
        result.map { mergedVoiceprint($0, voice) } ?? voice
    }
}

/// Adı verilen kişinin izini kayıtlı seslere ekler: aynı ad (büyük/küçük harf duyarsız) varsa kaynak eklenir ya da
/// (aynı kaynak yeniden adlandırılınca) yenilenir, iz kaynaklardan yeniden hesaplanır. Saf fonksiyondur.
public func registering(voices: [RegisteredVoice], name: String, voiceprint: Voiceprint, source: String, now: Date) -> [RegisteredVoice] {
    let trimmed: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return voices
    }
    guard let index = voices.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
        return voices + [RegisteredVoice(name: trimmed, voiceprint: voiceprint, updatedAt: now, contributions: [source: voiceprint])]
    }
    let existing: RegisteredVoice = voices[index]
    var contributions: [String: Voiceprint] = existing.contributions ?? [legacyVoiceSource: existing.voiceprint]
    contributions[source] = voiceprint
    var updated: [RegisteredVoice] = voices
    updated[index] = RegisteredVoice(
        name: existing.name, voiceprint: combinedVoiceprint(contributions: contributions) ?? voiceprint, updatedAt: now, contributions: contributions
    )
    return updated
}

/// Bir kaynağın katkısını adın sesinden çıkarır (ad yanlış verilmişti): iz kalan kaynaklardan yeniden hesaplanır,
/// kaynak kalmazsa ses silinir. Kaynakları saklanmayan eski seste ya da kaynak yoksa değişmez. Saf fonksiyondur.
public func unregistering(voices: [RegisteredVoice], name: String, source: String, now: Date) -> [RegisteredVoice] {
    guard let index = voices.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
          var contributions = voices[index].contributions, contributions[source] != nil else {
        return voices
    }
    contributions[source] = nil
    guard let combined = combinedVoiceprint(contributions: contributions) else {
        return voices.enumerated().filter { $0.offset != index }.map(\.element)
    }
    var updated: [RegisteredVoice] = voices
    updated[index] = RegisteredVoice(name: voices[index].name, voiceprint: combined, updatedAt: now, contributions: contributions)
    return updated
}

/// Toplantıdaki kişilere kayıtlı seslerden ad: yalnızca yeterli konuşması olan ve emin olunan eşleşmeler; bir ad en
/// fazla bir kişiye (en yakın olana) verilir. Saf fonksiyondur.
public func recognizedNames(voiceprints: [Int: Voiceprint], registry: [RegisteredVoice]) -> [Int: String] {
    let candidates: [Int: Voiceprint] = Dictionary(uniqueKeysWithValues: registry.enumerated().map { ($0.offset, $0.element.voiceprint) })
    let matches: [(person: Int, voice: Int, distance: Double)] = voiceprints
        .filter { $0.value.seconds >= VoiceMatching.minDecisionSeconds }
        .compactMap { (entry: (key: Int, value: Voiceprint)) -> (person: Int, voice: Int, distance: Double)? in
            confidentMatch(voice: entry.value, candidates: candidates).map { (voice: Int) -> (person: Int, voice: Int, distance: Double) in
                (person: entry.key, voice: voice, distance: voiceDistance(entry.value, registry[voice].voiceprint))
            }
        }
        .sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.person < $1.person }
    return matches.reduce(into: [Int: String]()) { (names: inout [Int: String], match: (person: Int, voice: Int, distance: Double)) -> Void in
        let name: String = registry[match.voice].name
        if !names.values.contains(name) {
            names[match.person] = name
        }
    }
}
