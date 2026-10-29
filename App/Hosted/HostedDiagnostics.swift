import AINotepadCore
import Foundation

/// Tanılamanın hesap bölümü (abonelik sürümü): oturum durumu, plan, deneme hakkı ya da abonelik ve kullanım. Jeton,
/// e-posta ve kullanıcı kimliği yazılmaz.
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
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: stateLabel, value: String(localized: "Giriş yapıldı"))]
            + hostedPlanDiagnostics(entitlements: entitlements))
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
    case .ending(let endsAt):
        return [DiagnosticsItem(label: planLabel, value: String(localized: "Abonelik iptal edildi, bitiş \(endsAt.formatted(.iso8601))")), usage]
    case .grace(let endsAt):
        return [DiagnosticsItem(label: planLabel, value: String(localized: "Ödeme bekleniyor, ek süre bitişi \(endsAt.formatted(.iso8601))")), usage]
    }
}

/// Canlı metnin motoru ve nedeni: bu açılışta kayıt yapıldıysa son kaydınki (Mac'e geçiş dahil), yoksa sunucunun
/// önerisi. Jeton yazılmaz.
@MainActor
func hostedLiveEngineDiagnostics(model: AppModel, account: HostedAccount) -> [DiagnosticsItem] {
    let status: HostedLiveStatus = model.hostedLiveStatus ?? hostedExpectedLiveStatus(account: account)
    let engine: String
    switch status.engine {
    case .deepgram:
        engine = String(localized: "Deepgram (bulut)")
    case .whisperKit:
        engine = String(localized: "WhisperKit (bu Mac'te)")
    }
    return [
        DiagnosticsItem(label: String(localized: "Motor"), value: engine),
        DiagnosticsItem(label: String(localized: "Neden"), value: redactedDiagnosticText(text: status.reason, userNames: diagnosticsUserNames())),
    ]
}

/// Tanılamada denetlenen sunucu: hesabın sunucusu.
func hostedDiagnosticsAPIBase() throws -> URL {
    try HostedServices.requireClient().baseURL
}
