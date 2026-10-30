import AINotepadCore
import Foundation

// Abonelik sürümünün tanılaması yalnızca kullanıcıya ve desteğe yarayan bilgiyi gösterir: altyapı (sunucu adresi,
// HTTP durumu, sağlayıcı ve model adları) ve kötüye kullanım önlemleri (cihaz doğrulaması, canlı metin politikası)
// ekranda da kopyalanan metinde de yazılmaz.

/// Tanılamanın hesap bölümü (abonelik sürümü): oturum durumu (okunamıyorsa hesap sayfasındaki kullanıcı mesajı), plan,
/// deneme hakkı ya da abonelik ve kullanım. Jeton, e-posta, kullanıcı kimliği ve cihaz doğrulaması yazılmaz.
@MainActor
func hostedAccountDiagnostics(account: HostedAccount) -> DiagnosticsSection {
    let title: String = String(localized: "Hesap")
    let stateLabel: String = String(localized: "Durum")
    switch account.state {
    case .loading:
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: stateLabel, value: String(localized: "Okunuyor"))])
    case .signedOut:
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: stateLabel, value: String(localized: "Giriş yapılmamış"))])
    case .unavailable(let message):
        return DiagnosticsSection(title: title, items: [
            DiagnosticsItem(label: stateLabel, value: String(localized: "Kullanılamıyor")),
            DiagnosticsItem(label: String(localized: "Neden"), value: redactedDiagnosticText(text: message, userNames: diagnosticsUserNames())),
        ])
    case .signedInStatusUnknown(let message):
        return DiagnosticsSection(title: title, items: [
            DiagnosticsItem(label: stateLabel, value: String(localized: "Giriş yapıldı, durum bilinmiyor")),
            DiagnosticsItem(label: String(localized: "Neden"), value: redactedDiagnosticText(text: message, userNames: diagnosticsUserNames())),
        ])
    case .signedIn(let entitlements):
        return DiagnosticsSection(
            title: title, items: [DiagnosticsItem(label: stateLabel, value: String(localized: "Giriş yapıldı"))] + hostedPlanDiagnostics(entitlements: entitlements)
        )
    }
}

/// Plan satırları: deneme (kalan toplantı, bitiş) ya da abonelik (durum, tarih) ve aylık kullanım. Saf fonksiyondur.
private func hostedPlanDiagnostics(entitlements: HostedEntitlements) -> [DiagnosticsItem] {
    let planLabel: String = String(localized: "Plan")
    let usage: DiagnosticsItem = DiagnosticsItem(
        label: String(localized: "Kullanım"), value: hostedMonthlyUsageText(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)
    )
    switch hostedPlanStatus(entitlements: entitlements) {
    case .trial(let left, let total):
        let ends: String = entitlements.trialEndsAt.map { $0.formatted(.iso8601) } ?? String(localized: "ilk toplantıyla başlar")
        return [
            DiagnosticsItem(label: planLabel, value: String(localized: "Deneme")),
            DiagnosticsItem(label: String(localized: "Kalan deneme"), value: hostedTrialText(left: left, total: total)),
            DiagnosticsItem(label: String(localized: "Deneme bitişi"), value: ends),
            usage,
        ]
    case .subscribed(let renewsAt):
        return [DiagnosticsItem(label: planLabel, value: String(localized: "Abonelik, yenilenme \(renewsAt.formatted(.iso8601))")), usage]
    case .complimentary:
        guard let until = entitlements.subscription?.cancelAt else {
            return [DiagnosticsItem(label: planLabel, value: String(localized: "Ücretsiz tam erişim")), usage]
        }
        return [DiagnosticsItem(label: planLabel, value: String(localized: "Ücretsiz tam erişim, bitiş \(until.formatted(.iso8601))")), usage]
    case .ending(let endsAt):
        return [DiagnosticsItem(label: planLabel, value: String(localized: "Abonelik iptal edildi, bitiş \(endsAt.formatted(.iso8601))")), usage]
    case .grace(let endsAt):
        return [DiagnosticsItem(label: planLabel, value: String(localized: "Ödeme bekleniyor, ek süre bitişi \(endsAt.formatted(.iso8601))")), usage]
    case .expired(let endedAt):
        return [DiagnosticsItem(label: planLabel, value: String(localized: "Abonelik sona erdi: \(endedAt.formatted(.iso8601))")), usage]
    case .paymentOverdue:
        return [DiagnosticsItem(label: planLabel, value: String(localized: "Ödeme alınamadı, ek süre bitti")), usage]
    }
}

/// Canlı metin bölümü (abonelik sürümü): yalnızca nerede çalıştığı, bulut ya da bu Mac. Bu açılışta kayıt yapıldıysa son
/// kaydınki (Mac'e geçiş dahil), yoksa sunucunun önerisi. Seçimin nedeni, sağlayıcı ve model adları yazılmaz.
@MainActor
func hostedLiveDiagnostics(model: AppModel, account: HostedAccount) -> DiagnosticsSection {
    let place: String
    switch model.hostedLiveEngineInUse ?? hostedExpectedLiveEngine(account: account) {
    case .deepgram:
        place = String(localized: "Bulut")
    case .whisperKit:
        place = String(localized: "Bu Mac'te")
    }
    return DiagnosticsSection(title: String(localized: "Canlı metin"), items: [DiagnosticsItem(label: String(localized: "Çalıştığı yer"), value: place)])
}

/// Bağlantı bölümü (abonelik sürümü): yalnızca hizmete ulaşılıp ulaşılamadığı. Sunucu adresi, HTTP durumu, gecikme ve
/// ham hata yazılmaz; adres okunamıyorsa nedeni hesap bölümünde görünür. Saf fonksiyondur.
func hostedConnectionDiagnostics(base: Result<URL, any Error>, health: APIHealth?) -> DiagnosticsSection {
    let value: String
    switch (base, health) {
    case (.failure, _), (.success, .unreachable?), (.success, .unhealthy?):
        value = String(localized: "Ulaşılamıyor; internet bağlantını denetleyip Yenile'ye bas")
    case (.success, .none):
        value = String(localized: "Denetleniyor…")
    case (.success, .reachable?):
        value = String(localized: "Bağlı")
    }
    return DiagnosticsSection(title: String(localized: "Bağlantı"), items: [DiagnosticsItem(label: String(localized: "Durum"), value: value)])
}

/// Tanılamada denetlenen sunucu: hesabın sunucusu.
func hostedDiagnosticsAPIBase() throws -> URL {
    try HostedServices.requireClient().baseURL
}
