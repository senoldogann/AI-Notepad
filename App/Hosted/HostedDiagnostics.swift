import AINotepadCore
import Foundation

// Abonelik sürümünün tanılaması yalnızca kullanıcıya ve desteğe yarayan bilgiyi gösterir: altyapı (sunucu adresi,
// HTTP durumu, sağlayıcı ve model adları) ve kötüye kullanım önlemleri (cihaz doğrulaması, canlı metin politikası)
// ekranda da kopyalanan metinde de yazılmaz.

/// Tanılamanın hesap bölümü (abonelik sürümü): oturum durumu (okunamıyorsa hesap sayfasındaki kullanıcı mesajı), plan,
/// deneme hakkı ya da abonelik ve kullanım (tarihler `dateText` biçiminde: ekranda yerel, kopyalanan metinde ISO 8601).
/// Jeton, e-posta, kullanıcı kimliği ve cihaz doğrulaması yazılmaz.
@MainActor
func hostedAccountDiagnostics(account: HostedAccount, dateText: (Date) -> String) -> DiagnosticsSection {
    let title: String = String(localized: "Hesap")
    let stateLabel: String = String(localized: "Durum")
    switch account.state {
    case .loading:
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: stateLabel, value: String(localized: "Okunuyor"), status: .plain)])
    case .signedOut:
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: stateLabel, value: String(localized: "Giriş yapılmamış"), status: .plain)])
    case .unavailable(let message):
        return DiagnosticsSection(title: title, items: [
            DiagnosticsItem(label: stateLabel, value: String(localized: "Kullanılamıyor"), status: .error),
            DiagnosticsItem(label: String(localized: "Neden"), value: redactedDiagnosticText(text: message, userNames: diagnosticsUserNames()), status: .plain),
        ])
    case .signedInStatusUnknown(let message):
        return DiagnosticsSection(title: title, items: [
            DiagnosticsItem(label: stateLabel, value: String(localized: "Giriş yapıldı, durum bilinmiyor"), status: .attention),
            DiagnosticsItem(label: String(localized: "Neden"), value: redactedDiagnosticText(text: message, userNames: diagnosticsUserNames()), status: .plain),
        ])
    case .signedIn(let entitlements):
        return DiagnosticsSection(
            title: title, items: [DiagnosticsItem(label: stateLabel, value: String(localized: "Giriş yapıldı"), status: .plain)] + hostedPlanDiagnostics(entitlements: entitlements, dateText: dateText)
        )
    }
}

/// Plan satırları: deneme (kalan toplantı, bitiş) ya da abonelik (durum, tarih) ve aylık kullanım (%80'de dikkat,
/// sınırda hata). Saf fonksiyondur.
private func hostedPlanDiagnostics(entitlements: HostedEntitlements, dateText: (Date) -> String) -> [DiagnosticsItem] {
    let planLabel: String = String(localized: "Plan")
    let usageStatus: DiagnosticsStatus
    switch hostedUsageLevel(fraction: hostedUsageFraction(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)) {
    case .normal: usageStatus = .plain
    case .warning: usageStatus = .attention
    case .full: usageStatus = .error
    }
    let usage: DiagnosticsItem = DiagnosticsItem(
        label: String(localized: "Kullanım"),
        value: hostedMonthlyUsageText(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap),
        status: usageStatus
    )
    switch hostedPlanStatus(entitlements: entitlements) {
    case .trial(let left, _):
        let ends: String = entitlements.trialEndsAt.map(dateText) ?? String(localized: "ilk toplantıyla başlar")
        return [
            DiagnosticsItem(label: planLabel, value: String(localized: "Deneme"), status: .plain),
            DiagnosticsItem(label: String(localized: "Kalan deneme"), value: hostedTrialLeftText(left: left), status: .plain),
            DiagnosticsItem(label: String(localized: "Deneme bitişi"), value: ends, status: .plain),
            usage,
        ]
    case .subscribed(let renewsAt):
        return [DiagnosticsItem(label: planLabel, value: String(localized: "Abonelik, yenilenme \(dateText(renewsAt))"), status: .plain), usage]
    case .complimentary:
        guard let until = entitlements.subscription?.cancelAt else {
            return [DiagnosticsItem(label: planLabel, value: String(localized: "Ücretsiz tam erişim"), status: .plain), usage]
        }
        return [DiagnosticsItem(label: planLabel, value: String(localized: "Ücretsiz tam erişim, bitiş \(dateText(until))"), status: .plain), usage]
    case .ending(let endsAt):
        return [DiagnosticsItem(label: planLabel, value: String(localized: "Abonelik iptal edildi, bitiş \(dateText(endsAt))"), status: .plain), usage]
    case .grace(let endsAt):
        return [DiagnosticsItem(label: planLabel, value: String(localized: "Ödeme bekleniyor, ek süre bitişi \(dateText(endsAt))"), status: .attention), usage]
    case .expired(let endedAt):
        return [DiagnosticsItem(label: planLabel, value: String(localized: "Abonelik sona erdi: \(dateText(endedAt))"), status: .attention), usage]
    case .paymentOverdue:
        return [DiagnosticsItem(label: planLabel, value: String(localized: "Ödeme alınamadı, ek süre bitti"), status: .error), usage]
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
    return DiagnosticsSection(title: String(localized: "Canlı metin"), items: [DiagnosticsItem(label: String(localized: "Çalıştığı yer"), value: place, status: .plain)])
}

/// Bağlantı bölümü (abonelik sürümü): yalnızca hizmete ulaşılıp ulaşılamadığı. Sunucu adresi, HTTP durumu, gecikme ve
/// ham hata yazılmaz; adres okunamıyorsa nedeni hesap bölümünde görünür. Saf fonksiyondur.
func hostedConnectionDiagnostics(base: Result<URL, any Error>, health: APIHealth?) -> DiagnosticsSection {
    let item: DiagnosticsItem
    let label: String = String(localized: "Durum")
    switch (base, health) {
    case (.failure, _), (.success, .unreachable?), (.success, .unhealthy?):
        item = DiagnosticsItem(label: label, value: String(localized: "Ulaşılamıyor; internet bağlantını denetleyip Yenile'ye bas"), status: .error)
    case (.success, .none):
        item = DiagnosticsItem(label: label, value: String(localized: "Denetleniyor…"), status: .plain)
    case (.success, .reachable?):
        item = DiagnosticsItem(label: label, value: String(localized: "Bağlı"), status: .plain)
    }
    return DiagnosticsSection(title: String(localized: "Bağlantı"), items: [item])
}

/// Tanılamada denetlenen sunucu: hesabın sunucusu.
func hostedDiagnosticsAPIBase() throws -> URL {
    try HostedServices.requireClient().baseURL
}
