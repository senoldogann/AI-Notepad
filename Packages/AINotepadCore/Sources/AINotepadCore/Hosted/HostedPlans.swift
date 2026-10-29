import Foundation

// Abonelik planlarının fiyatları ve deneme sonu özetinin hesapları. Fiyatlar Stripe'taki fiyatlarla elle aynı tutulur
// (vergiler dahil, USD); ödeme sayfası Stripe'ın kendi tutarını gösterir.

/// Aylık planın fiyatı (sent, vergiler dahil).
public let hostedMonthlyPriceCents: Int = 599

/// Yıllık planın fiyatı (sent, vergiler dahil).
public let hostedYearlyPriceCents: Int = 4900

/// Planın fiyatı (sent). Saf fonksiyondur.
public func hostedPlanPriceCents(plan: HostedBillingPlan) -> Int {
    switch plan {
    case .monthly: hostedMonthlyPriceCents
    case .yearly: hostedYearlyPriceCents
    }
}

/// Yıllık planın aylık karşılığı (sent, aşağı yuvarlanır: 4900 / 12 = 408,3 → 408). Saf fonksiyondur.
public func hostedYearlyMonthlyEquivalentCents() -> Int {
    hostedYearlyPriceCents / 12
}

/// Yıllık planın 12 aylık ödemeye göre tasarrufu (yüzde, en yakın tam sayı: 1 − 49 / 71,88 ≈ %32). Saf fonksiyondur.
public func hostedYearlySavingsPercent() -> Int {
    let twelveMonths: Double = Double(hostedMonthlyPriceCents * 12)
    return Int(((1 - Double(hostedYearlyPriceCents) / twelveMonths) * 100).rounded())
}

/// Davet koduyla ilk ödemenin tutarı (sent): aylıkta ilk ay ücretsiz (0), yıllıkta bir aylık ücret (5,99 $) bir kez
/// düşülür (43,01 $). Saf fonksiyondur.
public func hostedReferralFirstPaymentCents(plan: HostedBillingPlan) -> Int {
    switch plan {
    case .monthly: 0
    case .yearly: hostedYearlyPriceCents - hostedMonthlyPriceCents
    }
}

/// Denemenin bu Mac'teki özeti: kaydedilen toplantılar, notlardan çıkan görevler ve yazıya dökülen saat.
public struct HostedTrialValue: Sendable, Equatable {
    public let meetings: Int
    public let tasks: Int
    public let hours: Double

    public init(meetings: Int, tasks: Int, hours: Double) {
        self.meetings = meetings
        self.tasks = tasks
        self.hours = hours
    }
}

/// Yerel toplantılardan deneme özeti: biten (kaydı tamamlanmış) toplantılar, notlarındaki tüm görevler ve sürelerinin
/// toplamı (saat). Süren kayıt sayılmaz. Saf fonksiyondur.
public func hostedTrialValue(meetings: [MeetingRecord]) -> HostedTrialValue {
    let finished: [MeetingRecord] = meetings.filter { (record: MeetingRecord) -> Bool in record.endedAt != nil }
    let tasks: Int = finished.reduce(0) { (total: Int, record: MeetingRecord) -> Int in total + (record.note?.tasks.count ?? 0) }
    let seconds: Double = finished.reduce(0) { (total: Double, record: MeetingRecord) -> Double in
        total + max(0, (record.endedAt ?? record.startedAt).timeIntervalSince(record.startedAt))
    }
    return HostedTrialValue(meetings: finished.count, tasks: tasks, hours: seconds / 3600)
}
