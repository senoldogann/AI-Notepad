import AINotepadCore
import AINotepadUI
import SwiftUI

/// Başlatma engelinin çözümü (nedenin yanındaki tek düğme).
enum StartBlockAction: Equatable {
    /// Ayarlar (eksik anahtar ya da ayar).
    case openSettings
    /// Ayarlar › Hesap (kullanım sınırı).
    case openAccount
    /// Abone ol (deneme bitti).
    case subscribe
}

/// Kayıt neden başlatılamıyor ve ne yapılmalı: Ana sayfadaki başlat düğmesi kapanır, neden düğmenin yanında tek satır
/// görünür (aynı mesaj başka yerde tekrarlanmaz).
struct StartBlockNotice: Equatable {
    let reason: String
    let action: StartBlockAction
}

/// Şu anki engel: abonelikte hak durumu (deneme bitti, aylık sınır doldu), sonra kurulum eksikleri (geliştirici
/// sürümünde eksik anahtar ya da ayar). Konuşma modelinin hazırlanması ayrıca gösterilir (bkz. `LocalModelNoticeView`).
/// Durumdan türetilir; saklanmaz (hesap ya da ayar değişince kendiliğinden güncel).
@MainActor
func startBlockNotice(model: AppModel) -> StartBlockNotice? {
    #if HOSTED_EDITION
    if let hosted = hostedStartBlockNotice() {
        return hosted
    }
    #endif
    return model.setupProblems.first.map { StartBlockNotice(reason: $0, action: .openSettings) }
}

/// Engelin çözümünü uygular.
@MainActor
func resolveStartBlock(action: StartBlockAction, router: MainWindowRouter) {
    switch action {
    case .openSettings:
        router.section = .settings
    case .openAccount:
        openAccountSettings(router: router)
    case .subscribe:
        #if HOSTED_EDITION
        Task { await HostedAccount.shared.subscribe() }
        #else
        router.section = .settings
        #endif
    }
}

/// Çözülmüş durumların hata mesajları: hata şeridinde artık gösterilmez (ör. giriş yapıldıktan sonra "giriş
/// yapılmamış", oturum yeniden açıldıktan sonra "oturumun kapandı").
@MainActor
func resolvedErrorMessages() -> [String] {
    #if HOSTED_EDITION
    guard HostedAccount.shared.hasSession == true else {
        return []
    }
    return [userFacingMessage(error: HostedClientError.notSignedIn), userFacingMessage(error: HostedClientError.sessionEnded)]
    #else
    return []
    #endif
}

/// Başlat düğmesinin yanındaki neden: küçük simge, tek satır metin ve çözüm düğmesi.
struct StartBlockView: View {
    let notice: StartBlockNotice
    let onResolve: @MainActor (StartBlockAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            NoticeText(notice.reason, severity: .attention)
                .appFont(size: 13, weight: .regular)
                .lineLimit(2)
            Button(actionTitle) { onResolve(notice.action) }
                .buttonStyle(.pill)
                .controlSize(.small)
                .fixedSize()
        }
    }

    private var actionTitle: LocalizedStringKey {
        switch notice.action {
        case .openSettings: "Ayarları aç"
        case .openAccount: "Kullanımı gör"
        case .subscribe: "Abone ol"
        }
    }
}
