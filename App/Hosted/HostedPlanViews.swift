import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

// Abonelik planları: abone olma teklifi (plan seçimi, davet kodu, deneme sonu özeti) ve Ayarlar › Hesap'taki plan ve
// davet bölümü. Görünüm sakin ve durağandır: tek durağan film gradyanı, sürekli animasyon yok.

/// Dolar tutarı arayüz dilinde, ör. "$5.99", "$49" (tam dolarda kuruş yazılmaz). Saf fonksiyondur.
func hostedUSDText(cents: Int) -> String {
    let amount: Decimal = Decimal(cents) / 100
    return amount.formatted(.currency(code: "USD").precision(.fractionLength(cents % 100 == 0 ? 0 : 2)).locale(interfaceLocale()))
}

/// Yüzde metni arayüz dilinde, ör. "%32" ya da "32%". Saf fonksiyondur.
private func hostedPercentText(percent: Int) -> String {
    (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale()))
}

/// Planın adı, ör. "Yıllık". Saf fonksiyondur.
func hostedPlanName(plan: HostedBillingPlan) -> String {
    switch plan {
    case .monthly: String(localized: "Aylık")
    case .yearly: String(localized: "Yıllık")
    }
}

/// Planın fiyatı dönemiyle, ör. "$49/yıl". Saf fonksiyondur.
func hostedPlanPriceText(plan: HostedBillingPlan) -> String {
    let price: String = hostedUSDText(cents: hostedPlanPriceCents(plan: plan))
    switch plan {
    case .monthly: return String(localized: "\(price)/ay")
    case .yearly: return String(localized: "\(price)/yıl")
    }
}

/// Ayarlar › Hesap'taki plan satırı, ör. "Yıllık plan · $49/yıl". Saf fonksiyondur.
func hostedPlanLineText(plan: HostedBillingPlan) -> String {
    switch plan {
    case .monthly: String(localized: "Aylık plan · \(hostedPlanPriceText(plan: plan))")
    case .yearly: String(localized: "Yıllık plan · \(hostedPlanPriceText(plan: plan))")
    }
}

/// Davet kodunun seçilen plandaki etkisi: aylıkta ilk ay ücretsiz, yıllıkta bir aylık ücret bir kez düşülür. Saf
/// fonksiyondur.
func hostedReferralDiscountText(plan: HostedBillingPlan) -> String {
    switch plan {
    case .monthly:
        return String(localized: "Davet uygulandı: ilk ayın ücretsiz.")
    case .yearly:
        let first: String = hostedUSDText(cents: hostedReferralFirstPaymentCents(plan: .yearly))
        let discount: String = hostedUSDText(cents: hostedMonthlyPriceCents)
        return String(localized: "Davet uygulandı: ilk yılın \(first) (\(discount) indirim).")
    }
}

/// Arkadaşa gönderilecek davet metni (bağlantı dahil): aylıkta ilk ay ücretsiz, yıllıkta bir aylık ücret kadar indirim.
/// Saf fonksiyondur.
func hostedInviteText(inviteURL: URL) -> String {
    let discount: String = hostedUSDText(cents: hostedMonthlyPriceCents)
    return String(localized: "Toplantılarım için Gistsmith kullanıyorum: konuşulanı canlı yazıya döküyor, toplantı bitince notu ve görevleri hazırlıyor. Bu bağlantıyla abone olursan aylık planda ilk ayın ücretsiz, yıllık planda ilk yılın \(discount) indirimli: \(inviteURL.absoluteString)")
}

/// Abone olma teklifi (ana pencerede açılan kart): üstte durağan film gradyanı, uygulama simgesi ve "Gistsmith" rozeti;
/// başlık ve kısa açıklama; deneme bitmek üzereyse ya da bittiyse bu Mac'te o ana dek yapılanların özeti (toplantı,
/// görev, saat), değilse simgeli üç fayda; iki plan (yıllık seçili), isteğe bağlı davet kodu, seçilen planın ödeme
/// sayfasını açan düğme ve "Şimdi değil". Deneme notu hazır olunca (günde en çok bir), deneme bitmek üzereyken ve
/// bitince birer kez (bkz. `HostedAccount.meetingNoteReady`), abonelik gerektiren bir şey denenince (bkz.
/// `HostedAccount.requestSubscription`) ve "Abone ol"a basılınca (`HostedAccount.showPlans`) açılır; kayıt ve işleme
/// sürerken açılmaz. Ödeme sayfası açılamazsa teklif açık kalır, nedeni altında yazar.
struct HostedUpsellSheet: View {
    let account: HostedAccount
    let moment: HostedUpsellMoment
    /// Bu Mac'teki toplantılardan deneme özeti (deneme sonu anlarında gösterilir).
    let trialValue: HostedTrialValue

    @State private var plan: HostedBillingPlan = .yearly
    @State private var isInviteOpen: Bool = false
    @State private var inviteInput: String = ""
    @State private var invite: HostedInviteState = .none
    /// Bu teklifte "Abone ol"a basıldı: hesabın son hatası yalnızca o zaman burada gösterilir.
    @State private var hasAttempted: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text(title)
                        .appFont(size: 24, weight: .medium)
                        .tracking(-0.4)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.ink)
                    Text(verbatim: subtitle)
                        .appFont(size: 13, weight: .regular)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
                if showsTrialValue {
                    HostedTrialValueTiles(value: trialValue)
                } else {
                    benefits
                }
                HostedPlanPicker(selection: $plan)
                inviteSection
                VStack(spacing: 8) {
                    Button {
                        hasAttempted = true
                        Task {
                            // Yazılıp uygulanmamış ya da reddedilmiş kod sessizce düşmez (davet yalnızca ilk abonelikte
                            // geçer, sonradan eklenemez): önce doğrulanır; geçersizse ödeme açılmaz, neden kod alanında.
                            let referralCode: String?
                            if isInviteOpen, invite.code == nil, !inviteInput.trimmingCharacters(in: .whitespaces).isEmpty {
                                guard case .valid(let code) = await checkInvite() else {
                                    return
                                }
                                referralCode = code
                            } else {
                                referralCode = invite.code
                            }
                            if await account.subscribe(plan: plan, referralCode: referralCode) {
                                account.dismissUpsell()
                            }
                        }
                    } label: {
                        Label(subscribeTitle, systemImage: "arrow.up.right")
                            .labelStyle(.titleAndIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pillPrimary)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(account.isWorking || invite == .checking)
                    if hasAttempted, let message = account.errorMessage {
                        NoticeText(message as String, severity: .error)
                            .appFont(size: 12, weight: .regular)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Şimdi değil") { account.dismissUpsell() }
                        .buttonStyle(.hoverPlain)
                        .foregroundStyle(Theme.muted)
                        .keyboardShortcut(.cancelAction)
                }
                Text("Vergiler dahil. İstediğin zaman iptal edebilirsin; ödeme Stripe ile güvenle yapılır.")
                    .appFont(size: 11, weight: .regular)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30)
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
        .frame(width: 460)
        // Sayfa zemini uygulamanınki: koyu temada sistemin gri sayfa zemini uygulamanın siyahıyla uyuşmuyordu.
        .presentationBackground(Theme.background)
    }

    /// Üstteki durağan film gradyanı, uygulama simgesi ve rozet.
    private var header: some View {
        FilmGradient(seed: "gistsmith-abone", palette: .sunset)
            .frame(height: 132)
            .overlay {
                VStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .shadow(color: Color.black.opacity(0.2), radius: 14, y: 8)
                        .accessibilityHidden(true)
                    // Büyük harf elle yazılır: Türkçe yerel ayarda büyük harfe çevirme "GİSTSMİTH" yapıyordu.
                    Text(verbatim: "GISTSMITH")
                        .appFont(size: 11, weight: .semibold)
                        .tracking(1.2)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.22), in: Capsule())
                }
            }
    }

    /// Fayda listesi (deneme sonu özeti gösterilmeyen anlarda).
    private var benefits: some View {
        VStack(alignment: .leading, spacing: 10) {
            benefit(symbol: "waveform", text: "Canlı metin, konuşulurken")
            benefit(symbol: "checklist", text: "Toplantı bitince not hazır, görevler en üstte")
            benefit(symbol: "text.magnifyingglass", text: "Tüm toplantılarına soru sor")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// "Davet kodun var mı?" bağlantısı; açılınca kod alanı ve "Uygula" (kod ödemeden önce sunucuya doğrulatılır).
    @ViewBuilder
    private var inviteSection: some View {
        if case .valid = invite {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.ink)
                    .accessibilityHidden(true)
                Text(verbatim: hostedReferralDiscountText(plan: plan))
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Kaldır") {
                    invite = .none
                    inviteInput = ""
                }
                .buttonStyle(.hoverPlain)
                .foregroundStyle(Theme.muted)
            }
            .appFont(size: 12, weight: .regular)
        } else if isInviteOpen {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Davet kodu", text: $inviteInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .onSubmit { applyInvite() }
                    Button("Uygula") { applyInvite() }
                        .disabled(inviteInput.trimmingCharacters(in: .whitespaces).isEmpty || invite == .checking)
                    if invite == .checking {
                        ProgressView().controlSize(.small)
                    }
                }
                if case .invalid(let message) = invite {
                    NoticeText(message as String, severity: .error)
                        .appFont(size: 12, weight: .regular)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Button("Davet kodun var mı?") { isInviteOpen = true }
                .buttonStyle(.hoverPlain)
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
        }
    }

    /// "Uygula": girilen kodu sunucuya doğrulatır.
    private func applyInvite() {
        Task { await checkInvite() }
    }

    /// Girilen kodu sunucuya doğrulatır; sonuç hem gösterilir hem döner (abone olmadan önce de kullanılır).
    @discardableResult
    private func checkInvite() async -> HostedInviteState {
        let input: String = inviteInput
        invite = .checking
        let result: HostedInviteState
        switch await account.validateReferral(input: input) {
        case .valid(let code):
            result = .valid(code: code)
        case .invalid(let message):
            result = .invalid(message: message)
        }
        invite = result
        return result
    }

    /// Deneme sonu anı ve bu Mac'te en az bir toplantı var: özet gösterilir.
    private var showsTrialValue: Bool {
        (moment == .trialEnding || moment == .trialEnded) && trialValue.meetings > 0
    }

    private var subscribeTitle: LocalizedStringKey {
        switch plan {
        case .monthly: "Aylık plana abone ol"
        case .yearly: "Yıllık plana abone ol"
        }
    }

    private var title: LocalizedStringKey {
        switch moment {
        case .trialNoteReady: "Notun hazır"
        case .trialEnding: "Denemen bitmek üzere"
        case .trialEnded: "Ücretsiz denemen bitti"
        case .subscriptionRequired: "Devam etmek için abone ol"
        case .planChoice: "Planını seç"
        }
    }

    private var subtitle: String {
        switch moment {
        case .trialNoteReady:
            guard case .signedIn(let entitlements) = account.state, case .trial(let left, _) = hostedPlanStatus(entitlements: entitlements) else {
                return String(localized: "Abone olunca her toplantının notu böyle kendiliğinden hazırlanır.")
            }
            return String(localized: "Ücretsiz denemende \(left) toplantı kaldı. Abone olunca her toplantının notu böyle kendiliğinden hazırlanır.")
        case .trialEnding:
            return String(localized: "Kesintisiz devam etmek için bir plan seç. Toplantıların ve notların bu Mac'te kalır.")
        case .trialEnded:
            return String(localized: "Toplantıların ve notların bu Mac'te kalır. Yeni toplantıları kaydetmek için abone ol.")
        case .subscriptionRequired:
            return subscriptionRequiredReason
        case .planChoice:
            return String(localized: "Canlı metin, hazır not ve görevler; ayda 10 saate kadar kayıt. İstediğin zaman iptal edebilirsin.")
        }
    }

    /// Neden abone olmak gerektiği: bu Mac'te deneme kullanıldı, abonelik sona erdi ya da deneme bitti.
    private var subscriptionRequiredReason: String {
        if account.isTrialRefusedOnThisMac {
            return String(localized: "Bu Mac'te ücretsiz deneme başka bir hesapla kullanıldı. Kaydetmeye ve not almaya devam etmek için abone ol.")
        }
        if case .signedIn(let entitlements) = account.state, case .expired = hostedPlanStatus(entitlements: entitlements), entitlements.subscription != nil {
            return String(localized: "Aboneliğin sona erdi. Toplantıların ve notların bu Mac'te kalır; yeniden abone olunca kaldığın yerden devam edersin.")
        }
        return String(localized: "Ücretsiz denemen bitti. Toplantıların ve notların bu Mac'te kalır; yeni toplantılar için abone ol.")
    }

    private func benefit(symbol: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 26, height: 26)
                .background(Theme.card, in: Circle())
                .overlay(Circle().strokeBorder(Theme.line))
                .accessibilityHidden(true)
            Text(text)
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Teklifteki davet kodunun durumu.
enum HostedInviteState: Equatable {
    case none
    case checking
    case valid(code: String)
    case invalid(message: String)

    /// Ödeme sayfasına gönderilecek kod; doğrulanmadıysa nil.
    var code: String? {
        if case .valid(let code) = self {
            return code
        }
        return nil
    }
}

/// İki plan yan yana: aylık ve yıllık (yıllıkta tasarruf rozeti ve aylık karşılığı). Seçili kart koyu çerçeveli.
struct HostedPlanPicker: View {
    @Binding var selection: HostedBillingPlan

    var body: some View {
        HStack(spacing: 10) {
            card(plan: .monthly)
            card(plan: .yearly)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func card(plan: HostedBillingPlan) -> some View {
        let isSelected: Bool = selection == plan
        return Button {
            selection = plan
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
                        .accessibilityHidden(true)
                    Text(verbatim: hostedPlanName(plan: plan))
                        .appFont(size: 13, weight: .medium)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 4)
                    if plan == .yearly {
                        Text(verbatim: String(localized: "\(hostedPercentText(percent: hostedYearlySavingsPercent())) tasarruf"))
                            .appFont(size: 10, weight: .semibold)
                            .foregroundStyle(Theme.onPrimary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.primary, in: Capsule())
                            .fixedSize()
                    }
                }
                Text(verbatim: hostedPlanPriceText(plan: plan))
                    .appFont(size: 18, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 2)
                Text(verbatim: caption(plan: plan))
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Theme.ink : Theme.line, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func caption(plan: HostedBillingPlan) -> String {
        switch plan {
        case .monthly:
            String(localized: "Her ay yenilenir")
        case .yearly:
            String(localized: "Aylık yaklaşık \(hostedUSDText(cents: hostedYearlyMonthlyEquivalentCents()))")
        }
    }
}

/// Deneme sonu özeti: bu Mac'te kaydedilen toplantılar, notlardan çıkan görevler ve yazıya dökülen saat.
struct HostedTrialValueTiles: View {
    let value: HostedTrialValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bu Mac'te şimdiye dek")
                .appFont(size: 11, weight: .semibold)
                .foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                tile(number: value.meetings.formatted(.number.locale(interfaceLocale())), label: "Kaydedilen toplantı")
                tile(number: value.tasks.formatted(.number.locale(interfaceLocale())), label: "Çıkan görev")
                tile(number: value.hours.formatted(.number.precision(.fractionLength(0...1)).locale(interfaceLocale())), label: "Yazıya dökülen saat")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func tile(number: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: number)
                .appFont(size: 24, weight: .medium)
                .foregroundStyle(Theme.ink)
            Text(label)
                .appFont(size: 11, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// Ayarlar › Hesap'taki davet bölümü (yalnızca abonede ve program açıkken): kod, kopyalanabilir davet metni, kaç
/// arkadaşın katıldığı ve bekleyen ödülün tahmini tarihi. Ücretsiz erişimli hesapta ödülün uygulanmadığı yazar. Davet
/// bilgisi Ayarlar › Hesap açılınca okunur (`HostedAccount.loadReferral`); okunamazsa bölüm görünmez.
struct HostedReferralRow: View {
    let account: HostedAccount
    @State private var copied: Bool = false

    var body: some View {
        Group {
            if let referral = account.referral, referral.enabled, let code = referral.code, let inviteURL = referral.inviteUrl {
                SettingsRow(title: Text("Arkadaşını davet et")) {
                    if referral.complimentary {
                        Text("Arkadaşın davet koduyla abone olunca aylık planda ilk ayı ücretsiz olur. Hesabın zaten ücretsiz olduğu için sana ödül yazılmaz.")
                    } else {
                        Text("Arkadaşın davet koduyla abone olunca aylık planda ilk ayı ücretsiz olur. Onun ilk ödemesinden \(referral.holdDays) gün sonra sana da bir ay bedava: sonraki ödemenden \(hostedUSDText(cents: Int((referral.rewardUsd * 100).rounded()))) düşülür (yılda en çok \(referral.rewardsPerYear)).")
                    }
                    Text(verbatim: code)
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                    Text(verbatim: statsText(referral: referral))
                } control: {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hostedInviteText(inviteURL: inviteURL), forType: .string)
                        copied = true
                    } label: {
                        Text(copied ? LocalizedStringKey("Kopyalandı") : LocalizedStringKey("Davet metnini kopyala"))
                    }
                }
            }
        }
    }

    private func statsText(referral: HostedReferral) -> String {
        if referral.complimentary {
            return String(localized: "Katılan arkadaş: \(referral.joined)")
        }
        let stats: String = String(localized: "Katılan arkadaş: \(referral.joined) · Kazandığın ay: \(referral.rewarded)")
        guard let next = referral.nextRewardAt else {
            return stats
        }
        return stats + " · " + String(localized: "Sıradaki ödül: \(hostedDayText(date: next)) civarı")
    }
}
