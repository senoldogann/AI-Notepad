import Foundation

// Abonelik sürümünün kullanım göstergeleri ve bildirimleri: aylık saat sınırı (abone), toplantı dışı yapay zekâ payı,
// ücretsiz deneme ve kısaltılmış toplantı süresi. Sunucu ayı UTC'ye göre sayar (`server/src/usage.ts`, `monthKey`).

/// Ölçerin uyarı rengine geçtiği doluluk oranı.
public let hostedUsageWarningFraction: Double = 0.8

/// Sunucunun olağan toplantı üst süresi (dakika; `server/wrangler.jsonc` `SUBSCRIBER_MAX_MEETING_MINUTES`,
/// `TRIAL_MAX_MEETING_MINUTES`). Açılan toplantının süresi bundan kısaysa kayıtta kalan dakika gösterilir.
public let hostedUsualSubscriberMeetingMinutes: Int = 240
public let hostedUsualTrialMeetingMinutes: Int = 90

/// Ölçerin doluluk düzeyi.
public enum HostedUsageLevel: Sendable, Equatable {
    case normal
    /// %80 ve üstü.
    case warning
    /// Sınıra ulaşıldı (%100).
    case full
}

/// Kullanım oranı, 0…1 aralığında. Sınır sıfır ya da negatifse dolu sayılır (kullanılabilir pay yok). Saf fonksiyondur.
public func hostedUsageFraction(used: Double, cap: Double) -> Double {
    guard cap > 0 else {
        return 1
    }
    return min(1, max(0, used / cap))
}

/// Orana göre düzey. Saf fonksiyondur.
public func hostedUsageLevel(fraction: Double) -> HostedUsageLevel {
    if fraction >= 1 {
        return .full
    }
    return fraction >= hostedUsageWarningFraction ? .warning : .normal
}

/// UTC takvimi (sunucunun ay sınırı).
private func utcCalendar() -> Calendar {
    var calendar: Calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
}

/// Aylık sınırın sıfırlandığı an: bir sonraki UTC ayının ilk anı. Saf fonksiyondur.
public func hostedMonthResetDate(now: Date) -> Date {
    let calendar: Calendar = utcCalendar()
    let start: Date = calendar.dateInterval(of: .month, for: now)?.start ?? now
    return calendar.date(byAdding: .month, value: 1, to: start) ?? now
}

/// Dönem anahtarı "YYYY-MM" (UTC; sunucunun `monthKey`'i). Saf fonksiyondur.
public func hostedPeriodKey(now: Date) -> String {
    let components: DateComponents = utcCalendar().dateComponents([.year, .month], from: now)
    return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
}

/// Kullanıcıya bir kez gösterilen kullanım bildirimi.
public enum HostedUsageNotice: String, Sendable, Equatable, CaseIterable {
    /// Aylık saatlerin %80'i doldu.
    case monthlyWarning
    /// Aylık saatler doldu: yeni kayıt başlamaz.
    case monthlyFull
    /// Ücretsiz denemede tek toplantı kaldı.
    case trialOneLeft
    /// Ücretsiz deneme bitti.
    case trialEnded
}

/// Hak durumundan gösterilecek bildirim (varsa): abonede aylık doluluk, denemede kalan toplantı. Saf fonksiyondur.
public func hostedUsageNotice(entitlements: HostedEntitlements) -> HostedUsageNotice? {
    switch hostedPlanStatus(entitlements: entitlements) {
    case .trial(let left, _):
        if left == 0 {
            return .trialEnded
        }
        return left == 1 ? .trialOneLeft : nil
    case .expired:
        // Başlat düğmesinin yanındaki neden yeterli (bkz. `hostedStartBlock`).
        return nil
    case .subscribed, .ending, .grace:
        switch hostedUsageLevel(fraction: hostedUsageFraction(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)) {
        case .full:
            return .monthlyFull
        case .warning:
            return .monthlyWarning
        case .normal:
            return nil
        }
    }
}

/// Bildirimin "gösterildi" kaydının anahtarı: aylık bildirimler hesap ve ay başına, deneme bildirimleri hesap başına
/// (deneme bir kez yaşanır). Saf fonksiyondur.
public func hostedNoticeStorageKey(notice: HostedUsageNotice, userId: String, now: Date) -> String {
    switch notice {
    case .monthlyWarning, .monthlyFull:
        "hosted.notice.\(notice.rawValue).\(userId).\(hostedPeriodKey(now: now))"
    case .trialOneLeft, .trialEnded:
        "hosted.notice.\(notice.rawValue).\(userId)"
    }
}

/// Açılan toplantının süresi olağandan kısa mı (ör. aylık sınıra az kaldı): kayıtta kalan dakika gösterilir. Saf
/// fonksiyondur.
public func isShortenedHostedMeeting(started: HostedStartedMeeting) -> Bool {
    let usual: Int = started.kind == "trial" ? hostedUsualTrialMeetingMinutes : hostedUsualSubscriberMeetingMinutes
    return started.maxDurationMinutes < usual
}

/// Kayda kalan tam dakika (yukarı yuvarlanır, en az 0). Saf fonksiyondur.
public func hostedMinutesLeft(deadline: Date, now: Date) -> Int {
    max(0, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
}

/// Kaydın başlayamama nedeni (hak durumundan; Ana sayfadaki başlat düğmesi kapanır ve yanında yazar).
public enum HostedStartBlock: Sendable, Equatable {
    /// Ücretsiz deneme bitti (toplantılar ya da süre).
    case trialEnded
    /// Bu ayın adil kullanım saatleri doldu.
    case monthlyCapReached
    /// Abonelik sona erdi, deneme hakkı da yok.
    case subscriptionEnded
}

/// Hak durumuna göre kayıt başlayabilir mi; başlayamıyorsa neden. Ek süredeki ve iptal edilip dönemi süren abonelik
/// kayıt yapabilir (sınır dolmadıkça). Saf fonksiyondur.
public func hostedStartBlock(entitlements: HostedEntitlements) -> HostedStartBlock? {
    switch hostedPlanStatus(entitlements: entitlements) {
    case .trial(let left, _):
        return left == 0 ? .trialEnded : nil
    case .expired:
        return .subscriptionEnded
    case .subscribed, .ending, .grace:
        let fraction: Double = hostedUsageFraction(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)
        return hostedUsageLevel(fraction: fraction) == .full ? .monthlyCapReached : nil
    }
}

/// Hak durumunun eskimiş sayıldığı süre (saniye): uygulama her öne geldiğinde, son okuma bundan eskiyse yeniden okunur
/// (ödeme sayfasından dönüşte beklemeden; bkz. `HostedAccount.refreshOnActivation`).
public let hostedStaleRefreshIntervalSec: Double = 60

/// İçe aktarılan dosya, şimdi açılacak toplantının ses hakkından uzun: kuyruğa alınmaz (son geçiş yarıda kesilirdi).
public enum HostedImportError: Error, Sendable, Equatable {
    case longerThanMeetingAllowance(durationMinutes: Int, maxMinutes: Int)
}

/// Sunucunun parça örtüşmesi için toplantının ses hakkına eklediği pay (saniye): her 2900 saniyelik adım için 60 sn
/// (sunucudaki `chunkOverlapAllowance` ile aynı). Saf fonksiyondur.
public func hostedServerOverlapAllowanceSec(seconds: Double) -> Double {
    (seconds / 2900).rounded(.towardZero) * 60
}

/// Kaydın sunucuya gidecek toplam sesi (saniye): parçalar bir dakika örtüştüğü için süreden uzundur (bkz.
/// `wavChunkSpans`). Saf fonksiyondur.
public func hostedUploadedAudioSec(durationSec: Double) -> Double {
    let spans: [WavChunkSpan] = wavChunkSpans(
        totalSamples: Int((durationSec * Double(hostedTranscribeSampleRate)).rounded(.up)),
        maxSamples: maxSamplesPerWavChunk(maxBytes: hostedTranscribeMaxBytes),
        overlapSamples: Int(hostedChunkOverlapSec * Double(hostedTranscribeSampleRate))
    )
    return Double(spans.reduce(0) { $0 + $1.sampleCount }) / Double(hostedTranscribeSampleRate)
}

/// İçe aktarılacak dosyayı son okunan hak durumuyla karşılaştırır: sunucuya gidecek sesi (parça örtüşmesi dahil)
/// toplantının ses hakkını (`meetingMaxMinutes` + sunucunun örtüşme payı) aşıyorsa `HostedImportError`. Alanı bilmeyen
/// eski sunucuda denetlenmez (sunucu son geçişte yine reddeder). Saf fonksiyondur.
public func requireHostedImportFits(durationSec: Double, entitlements: HostedEntitlements) throws {
    guard let maxMinutes = entitlements.meetingMaxMinutes else {
        return
    }
    let allowance: Double = Double(maxMinutes) * 60 + hostedServerOverlapAllowanceSec(seconds: Double(maxMinutes) * 60)
    guard hostedUploadedAudioSec(durationSec: durationSec) > allowance else {
        return
    }
    throw HostedImportError.longerThanMeetingAllowance(durationMinutes: Int((durationSec / 60).rounded(.up)), maxMinutes: maxMinutes)
}

/// Hak durumu yeniden okunmalı mı: hiç okunmadıysa ya da son okuma `intervalSec`'ten eskiyse. Saf fonksiyondur.
public func isHostedRefreshDue(lastRefresh: Date?, now: Date, intervalSec: Double) -> Bool {
    guard let lastRefresh else {
        return true
    }
    return now.timeIntervalSince(lastRefresh) >= intervalSec
}
