import AINotepadCore
import AINotepadUI
import SwiftUI

// Abonelik sürümünün kullanım göstergeleri: Ayarlar › Hesap'taki kullanım kartı, kenar çubuğundaki küçük gösterge,
// ana penceredeki kullanım bildirimleri ve kayıt panelinde kısaltılmış toplantının kalan dakikası. Görünüm sakin ve
// durağandır (hareketli bulanık gradyan yok). Ölçerin olağan dolgusu kullanıcının vurgu rengidir; uyarı renkleri
// yalnızca gerçek durumda, uyarılarla aynı renkle (`NoticeSeverity`) gelir.

/// Ayın sıfırlanma günü, ör. "1 Kasım" (sunucu ayı UTC'ye göre sayar; gün UTC'de yazılır). Saf fonksiyondur.
func hostedResetDayText(now: Date) -> String {
    var style: Date.FormatStyle = Date.FormatStyle.dateTime.day().month(.wide).locale(interfaceLocale())
    style.timeZone = .gmt
    return hostedMonthResetDate(now: now).formatted(style)
}

/// Arayüz dilinde gün, ör. "1 Kas 2026". Saf fonksiyondur.
func hostedDayText(date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale()))
}

/// Denemenin koşulu sunucunun bildirdiği değerlerle, ör. "3 toplantı ya da 7 gün" (gün bilinmiyorsa yalnızca toplantı).
/// Saf fonksiyondur.
func hostedTrialTermsText(entitlements: HostedEntitlements) -> String {
    guard let days = entitlements.trialDays else {
        return String(localized: "\(entitlements.trialMeetingsTotal) toplantı")
    }
    return String(localized: "\(entitlements.trialMeetingsTotal) toplantı ya da \(days) gün")
}

/// Kısa saat metni, ör. "3,4 / 10 sa". Saf fonksiyondur.
func hostedCompactHoursText(used: Double, cap: Double) -> String {
    let style: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(0...1)).locale(interfaceLocale())
    return String(localized: "\(used.formatted(style)) / \(cap.formatted(style)) sa")
}

/// Kalan deneme toplantısı, ör. "2 toplantı kaldı"; bitmişse "Deneme bitti". Saf fonksiyondur.
func hostedTrialLeftText(left: Int) -> String {
    left == 0 ? String(localized: "Deneme bitti") : String(localized: "\(left) toplantı kaldı")
}

/// Yüzde metni, ör. "%25". Saf fonksiyondur.
private func percentText(fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale()))
}

/// Kalan deneme toplantısına göre düzey: 1 kaldıysa dikkat, bittiyse dolu. Saf fonksiyondur.
func hostedTrialLevel(left: Int) -> HostedUsageLevel {
    switch left {
    case ...0: .full
    case 1: .warning
    default: .normal
    }
}

/// Ölçerin yanındaki metnin rengi: olağan durumda soluk; dikkat ve dolu durumunda uyarılarla aynı renk. Saf fonksiyondur.
@MainActor
private func usageLevelColor(level: HostedUsageLevel) -> Color {
    switch level {
    case .normal: Theme.muted
    case .warning: NoticeSeverity.attention.tint
    case .full: NoticeSeverity.error.tint
    }
}

/// Ölçerin dolgusu: olağan durumda kullanıcının Görünüm'de seçtiği vurgu rengi (arayüzle uyumlu); dikkat ve dolu
/// durumunda uyarılarla aynı renk. Saf fonksiyondur.
@MainActor
private func meterFillColor(level: HostedUsageLevel, accent: PanelAccent) -> Color {
    switch level {
    case .normal: accent.color
    case .warning: NoticeSeverity.attention.tint
    case .full: NoticeSeverity.error.tint
    }
}

/// Uzun açıklama için bilgi simgesi: üstüne gelince ipucu (Ayarlar'daki bağlantı başlıklarıyla aynı).
private struct HostedInfoHint: View {
    let text: LocalizedStringKey

    var body: some View {
        Image(systemName: "info.circle")
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(Theme.muted)
            .hoverHint(text, alignment: .leading, edge: .bottom)
            .accessibilityElement()
            .accessibilityLabel(Text(text))
    }
}

/// Yuvarlak uçlu kullanım ölçeri: sakin zemin üstünde vurgu renginde dolgu; %80'de dikkat, %100'de hata rengi.
struct HostedUsageMeter: View {
    let fraction: Double
    let height: CGFloat
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.soft)
                Capsule().strokeBorder(Theme.line.opacity(0.6), lineWidth: 0.5)
                if fraction > 0 {
                    Capsule()
                        .fill(meterFillColor(level: hostedUsageLevel(fraction: fraction), accent: appearance.accent))
                        .frame(width: max(height, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text("Kullanım"))
        .accessibilityValue(Text(verbatim: percentText(fraction: fraction)))
    }
}

/// Deneme toplantıları: her toplantı bir parça; kalanlar dolu, kullanılanlar boş. Dolgu vurgu renginde; 1 toplantı
/// kaldıysa dikkat rengi, deneme bittiyse boş parçaların çerçevesi hata renginde.
struct HostedTrialSegments: View {
    let left: Int
    let total: Int
    let height: CGFloat
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(spacing: height) {
            ForEach(0..<max(total, 1), id: \.self) { (index: Int) in
                Capsule()
                    .fill(index < left ? meterFillColor(level: hostedTrialLevel(left: left), accent: appearance.accent) : Theme.soft)
                    .overlay(Capsule().strokeBorder(left == 0 ? NoticeSeverity.error.tint.opacity(0.6) : Theme.line.opacity(0.6), lineWidth: 0.5))
                    .frame(height: height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: hostedTrialLeftText(left: left)))
    }
}

/// Ayarlar › Hesap'taki kullanım kartı. Abonede bu ayın saatleri (adil kullanım sınırı) ve, sunucu bildiriyorsa,
/// toplantı dışı yapay zekâ payı; denemede kalan toplantılar, bitiş tarihi ve "Abone ol".
struct HostedUsageCard: View {
    let account: HostedAccount
    let entitlements: HostedEntitlements

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch hostedPlanStatus(entitlements: entitlements) {
            case .trial(let left, let total):
                trial(left: left, total: total)
            case .subscribed, .complimentary, .ending, .grace:
                subscriber
            case .expired(let endedAt):
                expired(endedAt: endedAt)
            case .paymentOverdue:
                paymentOverdue
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var subscriber: some View {
        let fraction: Double = hostedUsageFraction(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: hostedMonthlyUsageText(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap))
                    .appFont(size: 17, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                HostedInfoHint(text: "Adil kullanım sınırı: bu ay kaydedilen toplantıların toplam süresi. Ay başında sıfırlanır; sınır dolunca yeni kayıt başlatılamaz.")
                Spacer(minLength: 8)
                Text(verbatim: percentText(fraction: fraction))
                    .appFont(size: 13, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(usageLevelColor(level: hostedUsageLevel(fraction: fraction)))
            }
            HostedUsageMeter(fraction: fraction, height: 10)
            Text("Sıfırlanma: \(hostedResetDayText(now: Date()))")
                .appFont(size: 12, weight: .regular)
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
            if fraction >= 1 {
                Text("Bu ayki sınır doldu: yeni kayıt başlatılamaz. Notların ve toplantıların erişilebilir kalır.")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(NoticeSeverity.error.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let used = entitlements.accountTokensUsed, let cap = entitlements.accountTokensCap {
            let aiFraction: Double = hostedUsageFraction(used: Double(used), cap: Double(cap))
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Toplantı dışı yapay zekâ")
                        .appFont(size: 13, weight: .medium)
                        .foregroundStyle(Theme.ink)
                    HostedInfoHint(text: "Sor, notu yeniden yazma, paylaşım çevirisi ve görev araçları bu paydan düşer; toplantı sırasındakiler düşmez.")
                    Spacer(minLength: 8)
                    Text(verbatim: percentText(fraction: aiFraction))
                        .appFont(size: 12, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(usageLevelColor(level: hostedUsageLevel(fraction: aiFraction)))
                }
                HostedUsageMeter(fraction: aiFraction, height: 6)
            }
        }
    }

    @ViewBuilder
    private func trial(left: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Ücretsiz deneme")
                    .appFont(size: 17, weight: .medium)
                    .foregroundStyle(Theme.ink)
                HostedInfoHint(text: "Deneme ilk toplantıyla başlar: \(hostedTrialTermsText(entitlements: entitlements)), hangisi önce dolarsa.")
                Spacer(minLength: 8)
                Text(verbatim: hostedTrialLeftText(left: left))
                    .appFont(size: 13, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(usageLevelColor(level: hostedTrialLevel(left: left)))
            }
            HostedTrialSegments(left: left, total: total, height: 8)
            Group {
                if left == 0 && account.isTrialRefusedOnThisMac {
                    Text("Bu Mac'te ücretsiz deneme başka bir hesapla kullanıldı; devam etmek için abone ol. Toplantıların ve notların bu Mac'te kalır.")
                } else if left == 0 {
                    Text("Deneme bitti; yeni toplantılar için abone ol. Toplantıların ve notların bu Mac'te kalır.")
                } else if let endsAt = entitlements.trialEndsAt {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Bitiş")
                        Text(verbatim: endsAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                    }
                } else {
                    Text("İlk toplantıyla başlar")
                }
            }
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            Button("Abone ol") { account.showPlans() }
                .buttonStyle(.pillPrimary)
                .disabled(account.isWorking)
                .padding(.top, 2)
        }
    }
}

extension HostedUsageCard {
    /// Yenileme ödemesi alınamadı ve ek süre bitti: abonelik Stripe'ta sürer, kart "Hesabı yönet"ten güncellenir (yeni
    /// abonelik açılamaz).
    fileprivate var paymentOverdue: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ödeme alınamadı")
                .appFont(size: 17, weight: .medium)
                .foregroundStyle(Theme.ink)
            Text("Yenileme ödemesi alınamadı ve ek süre bitti. Toplantıların ve notların bu Mac'te; yeni kayıt için kartını güncelle.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Hesabı yönet") { Task { await account.manageSubscription() } }
                .buttonStyle(.pillPrimary)
                .disabled(account.isWorking)
        }
    }

    /// Abonelik sona erdi: toplantılar ve notlar yerinde; yeni kayıt için yeniden abone ol.
    @ViewBuilder
    fileprivate func expired(endedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Abonelik sona erdi")
                .appFont(size: 17, weight: .medium)
                .foregroundStyle(Theme.ink)
            Text("Aboneliğin \(hostedDayText(date: endedAt)) tarihinde sona erdi. Toplantıların ve notların bu Mac'te; yeni kayıt için yeniden abone ol.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Yeniden abone ol") { account.showPlans() }
                .buttonStyle(.pillPrimary)
                .disabled(account.isWorking)
        }
    }
}

/// Kenar çubuğunun altındaki küçük gösterge: abonede ince ölçer ve "3,4 / 10 sa", denemede kalan toplantılar.
/// Tıklanınca Ayarlar › Hesap açılır. Giriş yoksa ya da hak durumu bilinmiyorsa görünmez.
struct HostedSidebarUsage: View {
    let account: HostedAccount
    let onOpen: @MainActor () -> Void

    var body: some View {
        if case .signedIn(let entitlements) = account.state {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    switch hostedPlanStatus(entitlements: entitlements) {
                    case .trial(let left, let total):
                        Text(verbatim: left == 0 && account.isTrialRefusedOnThisMac ? String(localized: "Bu Mac'te deneme kullanıldı") : hostedTrialLeftText(left: left))
                            .appFont(size: 12, weight: .regular)
                            .monospacedDigit()
                            .foregroundStyle(usageLevelColor(level: hostedTrialLevel(left: left)))
                        HostedTrialSegments(left: left, total: total, height: 4)
                    case .expired:
                        Text("Abonelik sona erdi")
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(NoticeSeverity.error.tint)
                    case .paymentOverdue:
                        Text("Ödeme alınamadı")
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(NoticeSeverity.error.tint)
                    case .subscribed, .complimentary, .ending, .grace:
                        let fraction: Double = hostedUsageFraction(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)
                        Text(verbatim: hostedCompactHoursText(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap))
                            .appFont(size: 12, weight: .regular)
                            .monospacedDigit()
                            .foregroundStyle(usageLevelColor(level: hostedUsageLevel(fraction: fraction)))
                        HostedUsageMeter(fraction: fraction, height: 4)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .hoverHint("Kullanım ve hesap", alignment: .leading, edge: .top)
        }
    }
}

/// Ana penceredeki kullanım bildirimi (güncelleme ve çökme şeritleriyle aynı sakin görünüm; açılır pencere yok).
struct HostedUsageBanner: View {
    let account: HostedAccount
    let notice: HostedUsageNotice
    let onOpenAccount: @MainActor () -> Void

    var body: some View {
        NoticeBar(severity: isUrgent ? .error : .attention, title: Text(verbatim: title), detail: Text(verbatim: subtitle), onDismiss: { account.dismissNotice() }) {
            switch notice {
            case .trialOneLeft, .trialEnded:
                Button("Abone ol") {
                    account.dismissNotice()
                    account.showPlans()
                }
                .buttonStyle(.pill)
                .disabled(account.isWorking)
            case .monthlyWarning, .monthlyFull:
                Button("Kullanımı gör") {
                    account.dismissNotice()
                    onOpenAccount()
                }
                .buttonStyle(.pill)
            }
        }
    }

    private var isUrgent: Bool {
        notice == .monthlyFull || notice == .trialEnded
    }

    private var title: String {
        switch notice {
        case .monthlyWarning:
            guard case .signedIn(let entitlements) = account.state else {
                return String(localized: "Bu ayki kullanım sınırına yaklaştın")
            }
            let fraction: Double = hostedUsageFraction(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)
            return String(localized: "Bu ayki kullanım sınırına yaklaştın: \(percentText(fraction: fraction))")
        case .monthlyFull: return String(localized: "Bu ayki kullanım sınırına ulaştın")
        case .trialOneLeft: return String(localized: "Ücretsiz denemende 1 toplantı kaldı")
        case .trialEnded: return String(localized: "Ücretsiz denemen bitti")
        }
    }

    private var subtitle: String {
        let reset: String = hostedResetDayText(now: Date())
        switch notice {
        case .monthlyWarning:
            guard case .signedIn(let entitlements) = account.state else {
                return String(localized: "Sınır \(reset) tarihinde sıfırlanır.")
            }
            return String(localized: "\(hostedMonthlyUsageText(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)); sınır \(reset) tarihinde sıfırlanır.")
        case .monthlyFull:
            return String(localized: "Yeni kayıt başlatılamaz. Bu, aylık adil kullanım sınırıdır ve \(reset) tarihinde sıfırlanır; notların ve toplantıların erişilebilir kalır.")
        case .trialOneLeft:
            guard case .signedIn(let entitlements) = account.state else {
                return String(localized: "Kesintisiz devam etmek için şimdi abone olabilirsin.")
            }
            return String(localized: "Deneme \(hostedTrialTermsText(entitlements: entitlements)) sürer. Kesintisiz devam etmek için şimdi abone olabilirsin.")
        case .trialEnded:
            return String(localized: "Yeni toplantılar için abone ol; toplantıların ve notların bu Mac'te kalır.")
        }
    }
}

/// Kayıt panelinde kısaltılmış toplantının kalan dakikası (aylık sınıra az kaldığında sunucu toplantıyı kısaltır).
struct HostedMeetingLimitStrip: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { (context: TimelineViewDefaultContext) in
            NoticeBar(
                severity: .attention,
                title: Text("Bu toplantıya \(hostedMinutesLeft(deadline: deadline, now: context.date)) dakika kaldı").monospacedDigit(),
                detail: Text("Aylık sınırına göre kayıt \(deadline.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale()))) itibarıyla biter.").monospacedDigit(),
                onDismiss: nil
            ) {
                EmptyView()
            }
        }
    }
}
