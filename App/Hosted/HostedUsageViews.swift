import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

// Abonelik sürümünün kullanım göstergeleri: Ayarlar › Hesap'taki kullanım kartı, kenar çubuğundaki küçük gösterge,
// ana penceredeki kullanım bildirimleri ve kayıt panelinde kısaltılmış toplantının kalan dakikası. Görünüm sakin ve
// durağandır (hareketli bulanık gradyan yok); ölçer rengi sitedeki ölçerle aynı.

/// Açık ve koyu görünüme göre renk (onaltılık RGB).
private func adaptiveColor(light: UInt32, dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { (appearance: NSAppearance) -> NSColor in
        let isDark: Bool = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let value: UInt32 = isDark ? dark : light
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1
        )
    })
}

/// Ölçerin sıcak dolgusu (sitedeki `.meter`: #e9896a → #c9a3e0).
private let meterWarmStart: Color = adaptiveColor(light: 0xE9896A, dark: 0xF0AE92)
private let meterWarmEnd: Color = adaptiveColor(light: 0xC9A3E0, dark: 0xD7BCEB)
/// %80 ve üstü (sitedeki `--warn`).
private let meterWarn: Color = adaptiveColor(light: 0x9A5B00, dark: 0xF2B863)
/// Sınır doldu (sitedeki `--danger`).
private let meterFull: Color = adaptiveColor(light: 0xB42318, dark: 0xFF8A7A)

/// Ayın sıfırlanma günü, ör. "1 Kasım" (sunucu ayı UTC'ye göre sayar; gün UTC'de yazılır). Saf fonksiyondur.
func hostedResetDayText(now: Date) -> String {
    var style: Date.FormatStyle = Date.FormatStyle.dateTime.day().month(.wide).locale(interfaceLocale())
    style.timeZone = .gmt
    return hostedMonthResetDate(now: now).formatted(style)
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

/// Yuvarlak uçlu kullanım ölçeri: sakin zemin üstünde sıcak dolgu; %80'de uyarı, %100'de dolu rengi.
struct HostedUsageMeter: View {
    let fraction: Double
    let height: CGFloat

    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.soft)
                Capsule().strokeBorder(Theme.line.opacity(0.6), lineWidth: 0.5)
                if fraction > 0 {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(height, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text("Kullanım"))
        .accessibilityValue(Text(verbatim: percentText(fraction: fraction)))
    }

    private var fill: AnyShapeStyle {
        switch hostedUsageLevel(fraction: fraction) {
        case .normal:
            AnyShapeStyle(LinearGradient(colors: [meterWarmStart, meterWarmEnd], startPoint: .leading, endPoint: .trailing))
        case .warning:
            AnyShapeStyle(meterWarn)
        case .full:
            AnyShapeStyle(meterFull)
        }
    }
}

/// Deneme toplantıları: her toplantı bir parça; kalanlar dolu, kullanılanlar boş.
struct HostedTrialSegments: View {
    let left: Int
    let total: Int
    let height: CGFloat

    var body: some View {
        HStack(spacing: height) {
            ForEach(0..<max(total, 1), id: \.self) { (index: Int) in
                Capsule()
                    .fill(index < left ? AnyShapeStyle(LinearGradient(colors: [meterWarmStart, meterWarmEnd], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Theme.soft))
                    .overlay(Capsule().strokeBorder(Theme.line.opacity(0.6), lineWidth: 0.5))
                    .frame(height: height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: hostedTrialText(left: left, total: total)))
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
            case .subscribed, .ending, .grace:
                subscriber
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
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: hostedMonthlyUsageText(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap))
                    .appFont(size: 17, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text(verbatim: percentText(fraction: fraction))
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(hostedUsageLevel(fraction: fraction) == .normal ? Theme.muted : (fraction >= 1 ? meterFull : meterWarn))
            }
            HostedUsageMeter(fraction: fraction, height: 10)
            Text("Adil kullanım sınırı; ay başında sıfırlanır (\(hostedResetDayText(now: Date()))). Canlı metin bu Mac'te yazılır ve sınırdan düşmez.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if fraction >= 1 {
                Text("Bu ayki sınır doldu: yeni kayıt başlatılamaz. Notların ve toplantıların erişilebilir kalır.")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(meterFull)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let used = entitlements.accountTokensUsed, let cap = entitlements.accountTokensCap {
            let aiFraction: Double = hostedUsageFraction(used: Double(used), cap: Double(cap))
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Toplantı dışı yapay zekâ")
                        .appFont(size: 13, weight: .medium)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Text(verbatim: percentText(fraction: aiFraction))
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(Theme.muted)
                }
                HostedUsageMeter(fraction: aiFraction, height: 6)
                Text("Sor, notu yeniden yazma, paylaşım çevirisi ve görev araçları bu paydan düşer; toplantı sırasındakiler düşmez.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func trial(left: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ücretsiz deneme")
                    .appFont(size: 17, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text(verbatim: hostedTrialText(left: left, total: total))
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(Theme.muted)
            }
            HostedTrialSegments(left: left, total: total, height: 8)
            Group {
                if left == 0 {
                    Text("Deneme bitti; yeni toplantılar için abone ol. Toplantıların ve notların bu Mac'te kalır.")
                } else if let endsAt = entitlements.trialEndsAt {
                    Text("Deneme \(endsAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))) tarihinde biter (3 toplantı ya da 7 gün, hangisi önce dolarsa).")
                } else {
                    Text("Deneme ilk toplantıyla başlar: 3 toplantı ya da 7 gün, hangisi önce dolarsa.")
                }
            }
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            Button("Abone ol") { Task { await account.subscribe() } }
                .buttonStyle(.pillPrimary)
                .disabled(account.isWorking)
                .padding(.top, 2)
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
                        Text(verbatim: hostedTrialLeftText(left: left))
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(left == 0 ? meterFull : Theme.muted)
                        HostedTrialSegments(left: left, total: total, height: 4)
                    case .subscribed, .ending, .grace:
                        let fraction: Double = hostedUsageFraction(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)
                        Text(verbatim: hostedCompactHoursText(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap))
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.muted)
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
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(isUrgent ? meterFull : Theme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Text(verbatim: subtitle)
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch notice {
            case .trialOneLeft, .trialEnded:
                Button("Abone ol") {
                    account.dismissNotice()
                    Task { await account.subscribe() }
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
            Button("Kapat") { account.dismissNotice() }
                .buttonStyle(.hoverPlain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.soft)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var isUrgent: Bool {
        notice == .monthlyFull || notice == .trialEnded
    }

    private var symbol: String {
        switch notice {
        case .monthlyWarning, .monthlyFull: "gauge.with.dots.needle.67percent"
        case .trialOneLeft, .trialEnded: "gift"
        }
    }

    private var title: LocalizedStringKey {
        switch notice {
        case .monthlyWarning: "Bu ayki kullanımının yüzde 80'i doldu"
        case .monthlyFull: "Bu ayki kullanım sınırına ulaştın"
        case .trialOneLeft: "Ücretsiz denemende 1 toplantı kaldı"
        case .trialEnded: "Ücretsiz denemen bitti"
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
            return String(localized: "Deneme 3 toplantı ya da 7 gün sürer. Kesintisiz devam etmek için şimdi abone olabilirsin.")
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
            HStack(spacing: DesignTokens.Spacing.s) {
                Image(systemName: "hourglass")
                    .foregroundStyle(meterWarn)
                    .accessibilityHidden(true)
                Text("Aylık sınırına göre bu toplantıya \(hostedMinutesLeft(deadline: deadline, now: context.date)) dakika kaldı; kayıt \(deadline.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale()))) itibarıyla biter.")
                    .appFont(size: 12, weight: .medium)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Spacing.m)
            .padding(.vertical, 8)
            .background(Theme.soft)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}
