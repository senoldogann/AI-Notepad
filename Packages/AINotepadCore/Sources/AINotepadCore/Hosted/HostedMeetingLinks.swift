import Foundation

/// Bu Mac'teki toplantı kaydının sunucudaki toplantı oturumu: son geçiş ("Tekrar işle" dahil) yalnızca kaydın kendi
/// oturumuna yazılır, başka bir toplantının bütçesinden düşmez.
public struct HostedMeetingLink: Codable, Sendable, Equatable {
    /// Kaydın kimliği (toplantı klasörünün adı).
    public let recordID: String
    /// Sunucudaki toplantı oturumunun kimliği.
    public let serverMeetingID: String
    public let createdAt: Date

    public init(recordID: String, serverMeetingID: String, createdAt: Date) {
        self.recordID = recordID
        self.serverMeetingID = serverMeetingID
        self.createdAt = createdAt
    }
}

/// Saklanan en çok bağ (en yeniler kalır; sunucu oturumu zaten kısa süre sonra kapanır).
public let hostedMeetingLinkCapacity: Int = 200

/// Bağı ekler (aynı kaydın eski bağı yerini yenisine bırakır) ve en yeni `capacity` tanesini tutar. Saf fonksiyondur.
public func appendingHostedMeetingLink(links: [HostedMeetingLink], link: HostedMeetingLink, capacity: Int) -> [HostedMeetingLink] {
    Array((links.filter { $0.recordID != link.recordID } + [link]).sorted { $0.createdAt < $1.createdAt }.suffix(capacity))
}

/// Kaydın sunucu oturumu; bağ yoksa (ör. içe aktarılan dosya ya da eski kayıt) nil. Saf fonksiyondur.
public func hostedServerMeetingID(recordID: String, links: [HostedMeetingLink]) -> String? {
    links.last { $0.recordID == recordID }?.serverMeetingID
}

/// Son geçiş isteğinin istemci zaman aşımı (saniye): sunucunun ElevenLabs'i beklediği süreden (15 dk) uzun olmalı;
/// kısa olursa istemci vazgeçip yeniden dener ve sunucu hâlâ süren yükleme için `transcription_in_progress` döner.
public let hostedTranscribeMinimumTimeoutSec: Double = 16 * 60

/// Parçanın zaman aşımı: genel son geçiş süresi ile sunucunun penceresinden uzun olanı. Saf fonksiyondur.
public func hostedTranscribeTimeoutSec(durationSec: Double) -> Double {
    max(finalPassTimeoutSec(durationSec: durationSec), hostedTranscribeMinimumTimeoutSec)
}

/// `transcription_in_progress` sonrası bekleme (saniye) ve en çok deneme: sunucunun ses ayırması 20 dk sürer.
public let hostedTranscribeBusyDelaySec: Double = 60
public let hostedTranscribeBusyAttempts: Int = 20

/// Açık (kapatılamamış) sunucu oturumlarına ekler; tekrar eklenmez. Saf fonksiyondur.
public func addingOpenMeeting(ids: [String], meetingID: String) -> [String] {
    ids.contains(meetingID) ? ids : ids + [meetingID]
}

/// Kapatılan oturumu listeden çıkarır. Saf fonksiyondur.
public func removingOpenMeeting(ids: [String], meetingID: String) -> [String] {
    ids.filter { $0 != meetingID }
}

/// Kapatılacak yetim oturumlar: kaydı süren oturum dışındaki açık oturumlar. Saf fonksiyondur.
public func orphanedMeetingIDs(openIDs: [String], recordingMeetingID: String?) -> [String] {
    openIDs.filter { $0 != recordingMeetingID }
}

/// Kapatma yanıtı (başarılı ya da başarısız) geldiğinde "şimdiki toplantı" temizlenmeli mi: yalnızca hâlâ kapatılan
/// oturumsa (bu arada yeni kayıt başladıysa onun oturumuna dokunulmaz). Saf fonksiyondur.
public func shouldClearCurrentMeeting(currentMeetingID: String?, endedMeetingID: String) -> Bool {
    currentMeetingID == endedMeetingID
}

/// Kaydedici meşgul mü: kayıt sürüyor ya da bitiyor, biten kayıt henüz işlemeye devredilmedi, toplantı işleniyor ya da
/// dosya içe aktarılıyor. Meşgulken yeni kayıt, kuyruk, çıkış ve güncellemeyle yeniden başlatma beklenir. Saf fonksiyondur.
public func isRecorderBusy(isRecording: Bool, isFinishing: Bool, isHandingOff: Bool, processingCount: Int, importingCount: Int) -> Bool {
    isRecording || isFinishing || isHandingOff || processingCount > 0 || importingCount > 0
}
