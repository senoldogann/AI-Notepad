import AINotepadCore
import AINotepadUI
import AppKit
import os
import SwiftUI

private let gateLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedGate")

/// Bu Mac'te kayıtlı oturum var mı (Anahtar Zinciri; ağa gidilmez). Servis adı tanımlı değilse ya da Anahtar Zinciri
/// okunamazsa hata fırlar.
func hostedHasStoredSession(bundle: Bundle) throws -> Bool {
    try HostedKeychainTokenStorage(service: hostedKeychainService(bundle: bundle)).load() != nil
}

/// Sitedeki yasal sayfa (gizlilik, koşullar); site adresi geçersizse nil (bağlantı gösterilmez, hata loglanır).
private func hostedLegalURL(path: String) -> URL? {
    do {
        return try HostedServices.siteBase().appending(path: path)
    } catch {
        gateLogger.error("Site adresi geçersiz, yasal bağlantı gösterilmiyor, hata: \(String(describing: error), privacy: .private)")
        return nil
    }
}

/// Giriş kapısı (abonelik sürümü): oturum yokken ana pencere yalnızca bunu gösterir — logo, tek cümlelik tanıtım,
/// "Giriş yap" (uygulama içi giriş penceresinde Apple ya da Google), deneme satırı ve gizlilik/koşullar bağlantıları.
/// Kenar çubuğu, toplantılar, ayarlar ve kayıt yoktur. Giriş tamamlanınca kurulum (izinler…) ya da ana sayfa açılır.
struct HostedSignInGate: View {
    let account: HostedAccount

    var body: some View {
        HStack(spacing: 0) {
            // Solda durağan film gradyanı (kurulum ekranıyla aynı dil; hareket yok).
            FilmGradient(seed: "gistsmith-giris", palette: .violet)
                .overlay(alignment: .bottomLeading) {
                    Text("Toplantılarını dinler, notunu yazar")
                        .appFont(size: 30, weight: .regular)
                        .tracking(-0.5)
                        .foregroundStyle(Color.black.opacity(0.78))
                        .padding(36)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(16)
                .frame(maxWidth: 520)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pageBackground()
        .task { await account.refresh() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(verbatim: appName)
                .appFont(size: 34, weight: .regular)
                .tracking(-0.6)
                .foregroundStyle(Theme.ink)
            Text("Teams, Zoom ve yüz yüze toplantılarını canlı yazıya döker; bitince notun hazır, görevlerin en üstte.")
                .appFont(size: 15, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            switch account.state {
            case .unavailable(let message):
                Text(verbatim: message)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .loading, .signedOut, .signedIn, .signedInStatusUnknown:
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        Task { await account.signIn() }
                    } label: {
                        Text("Giriş yap").frame(width: 228)
                    }
                    .buttonStyle(.pillPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(account.isWorking || account.pendingBrowserSignIn != nil)
                    Text("Apple ya da Google hesabınla; giriş penceresi uygulamanın içinde açılır.")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                    Text("3 toplantı ya da 7 gün ücretsiz")
                        .appFont(size: 13, weight: .medium)
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 4)
                }
                HostedAccountError(account: account)
            }
            HStack(spacing: 14) {
                if let privacy = hostedLegalURL(path: "privacy") {
                    Link("Gizlilik", destination: privacy)
                }
                if let terms = hostedLegalURL(path: "terms") {
                    Link("Koşullar", destination: terms)
                }
                Spacer(minLength: 0)
                Button("Çık") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.hoverPlain)
            }
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(Theme.muted)
            .padding(.top, 12)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(40)
    }
}
