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
