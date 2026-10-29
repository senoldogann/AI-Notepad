import Foundation

// Abonelik sürümünde çevrimdışı kayıt: sunucuya ulaşılamazsa kayıt yine başlar (canlı metin Mac'te), toplantı
// "işlenmeyi bekliyor" olur; bağlantı gelince sunucuda bir oturum açılır (sunucu hakları yine denetler; aynı kayıt
// için yinelenen başlatma `clientRef` sayesinde aynı oturumu döndürür), son geçiş ve not o oturumla üretilir.
// Çevrimdışı başlatma, son bilinen hak durumu kaydı en çok 7 gün önce izin verdiyse yapılabilir.

/// Son bilinen hak durumunun çevrimdışı kayda izni: kimin, ne zaman, en çok kaç dakikalık kayıt.
public struct HostedOfflinePermit: Codable, Sendable, Equatable {
    public let userId: String
    /// İzni veren hak durumunun okunduğu an.
    public let checkedAt: Date
    /// O andaki planla bir toplantının en çok süresi (deneme ya da abonelik üst sınırı ve kalan aylık süre).
    public let maxMinutes: Int

    public init(userId: String, checkedAt: Date, maxMinutes: Int) {
        self.userId = userId
        self.checkedAt = checkedAt
        self.maxMinutes = maxMinutes
    }
}

/// Çevrimdışı kayıt iznin en çok yaşı (saniye): 7 gün.
public let hostedOfflinePermitMaxAgeSec: Double = 7 * 86_400

/// Hak durumundan çevrimdışı izin: kayıt başlatılabiliyorsa izin (süre: deneme ya da abonelik üst sınırı, abonede kalan
/// aylık dakikayla sınırlı), başlatılamıyorsa (deneme bitti, sınır doldu) nil. Saf fonksiyondur.
public func hostedOfflinePermit(entitlements: HostedEntitlements, now: Date) -> HostedOfflinePermit? {
    guard hostedStartBlock(entitlements: entitlements) == nil else {
        return nil
    }
    let minutes: Int
    switch hostedPlanStatus(entitlements: entitlements) {
    case .trial:
        minutes = hostedUsualTrialMeetingMinutes
    case .expired:
        // `hostedStartBlock` bu durumda kaydı engeller; buraya gelinmez.
        minutes = 0
    case .subscribed, .ending, .grace:
        let remaining: Int = Int(((entitlements.monthlyHoursCap - entitlements.monthlyHoursUsed) * 60).rounded(.down))
        minutes = max(0, min(hostedUsualSubscriberMeetingMinutes, remaining))
    }
    return minutes > 0 ? HostedOfflinePermit(userId: entitlements.userId, checkedAt: now, maxMinutes: minutes) : nil
}

/// Çevrimdışı kayıt yapılabilir mi: izin aynı hesabın ve en çok `maxAgeSec` önceki olmalı; yapılabiliyorsa en çok süre
/// (dakika), yapılamıyorsa nil. Saf fonksiyondur.
public func hostedOfflineRecordingMinutes(permit: HostedOfflinePermit?, userId: String?, now: Date, maxAgeSec: Double) -> Int? {
    guard let permit, let userId, permit.userId == userId else {
        return nil
    }
    let age: Double = now.timeIntervalSince(permit.checkedAt)
    guard age >= 0, age <= maxAgeSec else {
        return nil
    }
    return permit.maxMinutes
}

/// Toplantı başlatma hatası sunucuya ulaşılamamaktan mı (ağ yok, sunucu ya da önündeki vekil yanıt vermiyor): öyleyse
/// kayıt çevrimdışı sürebilir. Sunucunun bilerek verdiği retler (deneme bitti, sınır, yetki) değildir. Saf fonksiyondur.
public func isOfflineStartError(error: any Error) -> Bool {
    switch error {
    case HostedClientError.network:
        return true
    case let error as HostedAPIError:
        switch error.code {
        case .none:
            return error.status >= 500 || error.status == 408
        case .some(.internalError), .some(.upstreamUnavailable):
            return true
        default:
            return false
        }
    default:
        return false
    }
}

/// Bekleyen (çevrimdışı) kaydın sunucu oturumunun hazırlığı.
public enum HostedQueuedMeetingPreparation: Sendable, Equatable {
    /// Oturum açık (ya da önceden açılmıştı): son geçiş ve not bu oturumla üretilebilir.
    case ready(serverMeetingID: String)
    /// Sunucuya hâlâ ulaşılamıyor: sonra yeniden denenir.
    case waitingForNetwork
    /// Sunucu kaydı şimdilik işlemiyor (deneme bitti, aylık sınır…); kayıt bu Mac'te kalır, durum değişince yeniden
    /// denenir. Neden kullanıcıya gösterilir.
    case blocked(reason: String)
}

/// Bekleyen kayıtlar içinden sıradaki: en eski. Saf fonksiyondur.
public func nextQueuedMeeting(records: [MeetingRecord]) -> MeetingRecord? {
    records.filter { $0.status == .queued }.min { $0.startedAt < $1.startedAt }
}
