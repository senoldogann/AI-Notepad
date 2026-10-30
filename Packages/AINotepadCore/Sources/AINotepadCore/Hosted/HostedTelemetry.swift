import Foundation

// Abonelik sürümünün istemci telemetrisi: Ayarlar'daki "Anonim kullanım istatistiklerini paylaş" açıkken güvenilirlik
// ve süre olayları (`POST /v1/telemetry`) ve günde bir özellik kullanımı (`POST /v1/telemetry/features`). Gövdeler
// yalnızca sabit listelerden değerler, sayılar ve süreler taşır: ses, metin, not, istem, başlık, ad, adres ya da dosya
// yolu taşıyamaz. Listeler sunucunun `server/src/telemetry.ts` dizileriyle birebir aynıdır (bkz. `ServerParityTests`).
// Geliştirici sürümü hiçbir şey göndermez (bkz. `telemetrySendingAllowed`).

/// Uygulamanın sürümü: telemetri yalnızca abonelik sürümünde (Gistsmith) gönderilir.
public enum AppEdition: Sendable, Equatable {
    /// Kendi anahtarlı geliştirici sürümü (AI-Notepad): sunucusu yoktur, telemetri göndermez.
    case developer
    /// Abonelik sürümü (Gistsmith).
    case hosted
}

/// Telemetri kaydedilip gönderilebilir mi: yalnızca abonelik sürümünde ve kullanıcı paylaşımı açık bıraktıysa. Saf
/// fonksiyondur.
public func telemetrySendingAllowed(edition: AppEdition, sharingEnabled: Bool) -> Bool {
    edition == .hosted && sharingEnabled
}

/// Sayılan güvenilirlik olayları.
public enum TelemetryCountKind: String, Sendable, Codable, CaseIterable {
    /// Deepgram canlı metin bağlantısı koptu.
    case deepgramSocketDrop = "deepgram_socket_drop"
    /// Kopan Deepgram bağlantısı yeniden kuruldu.
    case deepgramReconnect = "deepgram_reconnect"
    /// Son geçiş yarıda bırakıldı ya da hiç tamamlanamadı (canlı metin kullanıldı).
    case finalPassGiveUp = "final_pass_give_up"
    /// Not yazılamadı.
    case noteGenerationFailed = "note_generation_failed"
    /// Kayıt toplantının süre sınırına ulaştı ve kendiliğinden bitirildi.
    case recordingOverrun = "recording_overrun"
}

/// Süresi ölçülen işler (saniye).
public enum TelemetryDurationKind: String, Sendable, Codable, CaseIterable {
    /// Bir kaydın sunucuda son geçişi (yükleme dahil).
    case finalPassDuration = "final_pass_duration"
    /// Notun yazılması.
    case noteGenerationDuration = "note_generation_duration"
}

/// Notun gönderildiği entegrasyonun türü (hedefin adı ya da adresi değil).
public enum TelemetryIntegration: String, Sendable, Codable, CaseIterable, CodingKeyRepresentable {
    case slack
    case teams
    case discord
    case webhook
    case notion
    case appleNotes = "apple_notes"
    case markdownFolder = "markdown_folder"
    case trackerLinear = "tracker_linear"
    case trackerJira = "tracker_jira"
    case trackerNotion = "tracker_notion"
}

/// Dışa aktarma biçimi.
public enum TelemetryExportFormat: String, Sendable, Codable, CaseIterable, CodingKeyRepresentable {
    case pdf
    case html
    case markdown
    case docx
    case transcriptText = "transcript_text"
    case srt
    case copyMarkdown = "copy_markdown"
    case email
    case pdfShare = "pdf_share"
    case linkShare = "link_share"
    case audioClip = "audio_clip"
}

/// Bir sayım ya da süre gövdesinde en çok olay (sunucunun sınırı 50).
public let telemetryMaxEventsPerBatch: Int = 50
/// Olay başına en büyük sayı (sunucunun sınırı).
public let telemetryMaxCount: Int = 1000
/// En uzun süre (saniye; sunucunun sınırı).
public let telemetryMaxSeconds: Double = 86_400

/// Bir olay türünün birikmiş sayısı.
public struct TelemetryCount: Sendable, Equatable, Codable {
    public let kind: TelemetryCountKind
    public let count: Int

    public init(kind: TelemetryCountKind, count: Int) {
        self.kind = kind
        self.count = count
    }
}

/// Bir süre ölçümü.
public struct TelemetryDurationSample: Sendable, Equatable, Codable {
    public let kind: TelemetryDurationKind
    public let seconds: Double

    public init(kind: TelemetryDurationKind, seconds: Double) {
        self.kind = kind
        self.seconds = seconds
    }
}

/// Gönderilmeyi bekleyen olaylar (uygulama kapanınca da kalsın diye UserDefaults'ta JSON olarak durur).
public struct TelemetryPendingEvents: Sendable, Equatable, Codable {
    public let counts: [TelemetryCount]
    public let durations: [TelemetryDurationSample]

    public init(counts: [TelemetryCount], durations: [TelemetryDurationSample]) {
        self.counts = counts
        self.durations = durations
    }

    /// Bekleyen olay yok.
    public var isEmpty: Bool {
        counts.isEmpty && durations.isEmpty
    }
}

/// Olay türünün sayısını bir artırır (sınırda kalır). Saf fonksiyondur.
public func addingTelemetryCount(pending: TelemetryPendingEvents, kind: TelemetryCountKind) -> TelemetryPendingEvents {
    let current: Int = pending.counts.first { $0.kind == kind }?.count ?? 0
    let others: [TelemetryCount] = pending.counts.filter { $0.kind != kind }
    return TelemetryPendingEvents(counts: others + [TelemetryCount(kind: kind, count: min(current + 1, telemetryMaxCount))], durations: pending.durations)
}

/// Süre ölçümünü ekler (sunucunun aralığına kırpılır). Tek gövdeye sığsın diye en yeni
/// `telemetryMaxEventsPerBatch - TelemetryCountKind.allCases.count` ölçüm tutulur, eskileri düşer. Saf fonksiyondur.
public func addingTelemetryDuration(pending: TelemetryPendingEvents, kind: TelemetryDurationKind, seconds: Double) -> TelemetryPendingEvents {
    let clamped: Double = min(max(seconds.isFinite ? seconds : 0, 0), telemetryMaxSeconds)
    let capacity: Int = telemetryMaxEventsPerBatch - TelemetryCountKind.allCases.count
    let durations: [TelemetryDurationSample] = Array((pending.durations + [TelemetryDurationSample(kind: kind, seconds: clamped)]).suffix(capacity))
    return TelemetryPendingEvents(counts: pending.counts, durations: durations)
}

/// `POST /v1/telemetry` gövdesindeki tek olay: sayım (`count`) ya da süre (`seconds`); boş alan yazılmaz.
private struct TelemetryEventBody: Encodable {
    let kind: String
    let count: Int?
    let seconds: Double?
}

private struct TelemetryEventsBody: Encodable {
    let events: [TelemetryEventBody]
}

/// Bekleyen olayların gövdesi (`{"events": [...]}`); bekleyen olay yoksa nil. Saf fonksiyondur.
public func hostedTelemetryEventsBody(pending: TelemetryPendingEvents) throws -> Data? {
    guard !pending.isEmpty else {
        return nil
    }
    let counts: [TelemetryEventBody] = pending.counts
        .filter { $0.count > 0 }
        .map { TelemetryEventBody(kind: $0.kind.rawValue, count: $0.count, seconds: nil) }
    let durations: [TelemetryEventBody] = pending.durations.map { TelemetryEventBody(kind: $0.kind.rawValue, count: nil, seconds: $0.seconds) }
    return try JSONEncoder().encode(TelemetryEventsBody(events: Array((counts + durations).prefix(telemetryMaxEventsPerBatch))))
}

/// Özellik kullanımı kaydı.
public enum TelemetryFeature: Sendable, Equatable {
    /// Canlı çeviri kullanıldı (hedef dil).
    case liveTranslation(ShareLanguage)
    /// Sor kullanıldı.
    case ask
    /// Not ya da görevler bir entegrasyona gönderildi.
    case integration(TelemetryIntegration)
    /// Toplantı dışa aktarıldı.
    case export(TelemetryExportFormat)
    /// Toplantı arşivi MCP ile açıldı (bir MCP istemcisi yerel sunucuyu başlattı).
    case mcp
    /// Kaydın canlı metni bu Mac'te üretildi (bulut değil).
    case onDeviceLive
}

/// Bir günün (UTC) özellik kullanımı.
public struct TelemetryFeatureUsage: Sendable, Equatable, Codable {
    /// `yyyy-MM-dd` (UTC; bkz. `telemetryDayKey`).
    public let day: String
    public let liveTranslation: Bool
    /// Canlı çevirinin son kullanılan hedef dili; çeviri yoksa nil.
    public let translationLanguage: ShareLanguage?
    public let ask: Bool
    public let integrations: [TelemetryIntegration: Int]
    public let exports: [TelemetryExportFormat: Int]
    public let mcp: Bool
    public let onDeviceLive: Bool

    public init(
        day: String, liveTranslation: Bool, translationLanguage: ShareLanguage?, ask: Bool, integrations: [TelemetryIntegration: Int],
        exports: [TelemetryExportFormat: Int], mcp: Bool, onDeviceLive: Bool
    ) {
        self.day = day
        self.liveTranslation = liveTranslation
        self.translationLanguage = translationLanguage
        self.ask = ask
        self.integrations = integrations
        self.exports = exports
        self.mcp = mcp
        self.onDeviceLive = onDeviceLive
    }
}

/// Günün boş kullanımı. Saf fonksiyondur.
public func emptyFeatureUsage(day: String) -> TelemetryFeatureUsage {
    TelemetryFeatureUsage(day: day, liveTranslation: false, translationLanguage: nil, ask: false, integrations: [:], exports: [:], mcp: false, onDeviceLive: false)
}

/// Kullanıma özelliği işler (sayılar sınırda kalır). Saf fonksiyondur.
public func recordingFeature(usage: TelemetryFeatureUsage, feature: TelemetryFeature) -> TelemetryFeatureUsage {
    let incremented: (Int?) -> Int = { (count: Int?) -> Int in min((count ?? 0) + 1, telemetryMaxCount) }
    switch feature {
    case .liveTranslation(let language):
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: true, translationLanguage: language, ask: usage.ask, integrations: usage.integrations, exports: usage.exports,
            mcp: usage.mcp, onDeviceLive: usage.onDeviceLive
        )
    case .ask:
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: usage.liveTranslation, translationLanguage: usage.translationLanguage, ask: true, integrations: usage.integrations,
            exports: usage.exports, mcp: usage.mcp, onDeviceLive: usage.onDeviceLive
        )
    case .integration(let integration):
        var integrations: [TelemetryIntegration: Int] = usage.integrations
        integrations[integration] = incremented(integrations[integration])
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: usage.liveTranslation, translationLanguage: usage.translationLanguage, ask: usage.ask, integrations: integrations,
            exports: usage.exports, mcp: usage.mcp, onDeviceLive: usage.onDeviceLive
        )
    case .export(let format):
        var exports: [TelemetryExportFormat: Int] = usage.exports
        exports[format] = incremented(exports[format])
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: usage.liveTranslation, translationLanguage: usage.translationLanguage, ask: usage.ask, integrations: usage.integrations,
            exports: exports, mcp: usage.mcp, onDeviceLive: usage.onDeviceLive
        )
    case .mcp:
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: usage.liveTranslation, translationLanguage: usage.translationLanguage, ask: usage.ask, integrations: usage.integrations,
            exports: usage.exports, mcp: true, onDeviceLive: usage.onDeviceLive
        )
    case .onDeviceLive:
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: usage.liveTranslation, translationLanguage: usage.translationLanguage, ask: usage.ask, integrations: usage.integrations,
            exports: usage.exports, mcp: usage.mcp, onDeviceLive: true
        )
    }
}

/// `POST /v1/telemetry/features` gövdesi: entegrasyon ve dışa aktarma sayıları her tür için yazılır (sunucu hepsini
/// ister; kullanılmayan 0).
private struct FeatureUsageBody: Encodable {
    let day: String
    let liveTranslation: Bool
    let translationLanguage: String?
    let ask: Bool
    let integrations: [String: Int]
    let exports: [String: Int]
    let mcp: Bool
    let onDeviceLive: Bool

    enum CodingKeys: String, CodingKey {
        case day, liveTranslation, translationLanguage, ask, integrations, exports, mcp, onDeviceLive
    }

    /// `translationLanguage` nil iken de yazılır (`null`): sunucu alanı her zaman ister.
    func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(day, forKey: .day)
        try container.encode(liveTranslation, forKey: .liveTranslation)
        try container.encode(translationLanguage, forKey: .translationLanguage)
        try container.encode(ask, forKey: .ask)
        try container.encode(integrations, forKey: .integrations)
        try container.encode(exports, forKey: .exports)
        try container.encode(mcp, forKey: .mcp)
        try container.encode(onDeviceLive, forKey: .onDeviceLive)
    }
}

/// Günün özellik kullanımı gövdesi. Hedef dil yalnızca canlı çeviri kullanıldıysa yazılır. Saf fonksiyondur.
public func hostedFeatureUsageBody(usage: TelemetryFeatureUsage) throws -> Data {
    let body: FeatureUsageBody = FeatureUsageBody(
        day: usage.day,
        liveTranslation: usage.liveTranslation,
        translationLanguage: usage.liveTranslation ? usage.translationLanguage?.rawValue : nil,
        ask: usage.ask,
        integrations: Dictionary(uniqueKeysWithValues: TelemetryIntegration.allCases.map { ($0.rawValue, usage.integrations[$0] ?? 0) }),
        exports: Dictionary(uniqueKeysWithValues: TelemetryExportFormat.allCases.map { ($0.rawValue, usage.exports[$0] ?? 0) }),
        mcp: usage.mcp,
        onDeviceLive: usage.onDeviceLive
    )
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(body)
}

/// Sunucunun özellik raporu yanıtı: gün bu hesap için ilk kez mi sayıldı.
struct HostedFeatureUsageResponse: Decodable {
    let counted: Bool
}

/// Telemetri günü: UTC `yyyy-MM-dd` (sunucunun gün anahtarıyla aynı). Saf fonksiyondur.
public func telemetryDayKey(date: Date) -> String {
    var calendar: Calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let parts: DateComponents = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

/// Özellik kullanımının saklanan durumu: bugünün süren kaydı ve gönderilmeyi bekleyen tamamlanmış bir gün.
public struct TelemetryFeatureState: Sendable, Equatable, Codable {
    public let current: TelemetryFeatureUsage?
    public let completed: TelemetryFeatureUsage?

    public init(current: TelemetryFeatureUsage?, completed: TelemetryFeatureUsage?) {
        self.current = current
        self.completed = completed
    }
}

/// Özelliği bugünün kaydına işler. Kayıt başka bir güne aitse o gün tamamlanmış sayılır ve gönderilmeyi bekler (daha
/// önce bekleyen gün varsa yerine geçer: en çok bir gün bekler). Saf fonksiyondur.
public func recordingFeature(state: TelemetryFeatureState, feature: TelemetryFeature, today: String) -> TelemetryFeatureState {
    let rolled: TelemetryFeatureState = rollingFeatureState(state: state, today: today)
    return TelemetryFeatureState(current: recordingFeature(usage: rolled.current ?? emptyFeatureUsage(day: today), feature: feature), completed: rolled.completed)
}

/// Gün döndüyse bugünden önceki kayıt tamamlanmış güne geçer. Saf fonksiyondur.
public func rollingFeatureState(state: TelemetryFeatureState, today: String) -> TelemetryFeatureState {
    guard let current = state.current, current.day != today else {
        return state
    }
    return TelemetryFeatureState(current: nil, completed: current)
}

/// Not yazımının telemetri sonucu.
public enum NoteGenerationOutcome: Sendable, Equatable {
    /// Not yazıldı.
    case written
    /// Not yazılamadı (toplantı başarısız ya da yenileme hatası eski notu korudu).
    case failed
    /// Not yazılacak metin yoktu.
    case notWritten
}

/// İşlenmiş toplantının not sonucu. Saf fonksiyondur.
public func noteGenerationOutcome(record: MeetingRecord) -> NoteGenerationOutcome {
    if record.status == .failed || record.failureMessage != nil {
        return .failed
    }
    return record.note == nil ? .notWritten : .written
}

/// Not hedefinin entegrasyon türü (adı ya da adresi değil). Saf fonksiyondur.
public func telemetryIntegration(target: DestinationTarget) -> TelemetryIntegration {
    switch target {
    case .account(let connection):
        switch connection.service {
        case .slack: .slack
        case .teams: .teams
        case .discord: .discord
        }
    case .webhook: .webhook
    case .discordSignIn: .discord
    case .notion: .notion
    }
}

/// Görev aracının entegrasyon türü. Saf fonksiyondur.
public func telemetryIntegration(tracker: MCPService) -> TelemetryIntegration {
    switch tracker {
    case .linear: .trackerLinear
    case .atlassian: .trackerJira
    case .notion: .trackerNotion
    }
}
